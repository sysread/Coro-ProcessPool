package Coro::ProcessPool::Process;

use strict;
use warnings;
use Carp;

use Coro qw(async);
use Coro::Handle qw(unblock);
use Coro::AnyEvent qw();
use Config;
use IPC::Open3 qw(open3);
use POSIX qw(:sys_wait_h);
use String::Escape qw(backslash);
use Symbol qw(gensym);
use Coro::ProcessPool::Util qw(encode decode $EOL);

if ($^O eq 'MSWin32') {
    die 'MSWin32 is not supported';
}

use fields qw(
    pid
    to_child
    from_child
    child_err
    child_err_mon
    processed
);

sub DESTROY { $_[0]->terminate(1) if $_[0] }

sub new {
    my ($class, %param) = @_;
    my $self = fields::new($class);
    $self->{processed} = 0;
    return $self;
}

#-------------------------------------------------------------------------------
# Return the full path to the perl binary used to launch the parent in order to
# ensure that children are run on the same perl version.
#-------------------------------------------------------------------------------
sub get_command_path {
    my $self = shift;
    my $perl = $Config{perlpath};
    my $ext  = $Config{_exe};
    $perl .= $ext if $^O ne 'VMS' && $perl !~ /$ext$/i;
    return $perl;
}

sub get_args {
    my $self = shift;
    my @inc  = map { sprintf('-I%s', backslash($_)) } @INC;
    my $cmd  = q|-MCoro::ProcessPool::Worker -e 'Coro::ProcessPool::Worker->start()'|;
    return join ' ', @inc, $cmd;
}

#-------------------------------------------------------------------------------
# Executes the child process and configures streams and handles for IPC. Croaks
# on failure.
#-------------------------------------------------------------------------------
sub spawn {
    my ($self) = @_;
    my ($r, $w, $e) = (gensym, gensym, gensym);

    my $cmd  = $self->get_command_path;
    my $args = $self->get_args;
    my $exec = "$cmd $args";
    my $pid  = open3($w, $r, $e, $exec) or croak "Error spawning process: $!";

    $self->{pid}        = $pid;
    $self->{to_child}   = unblock $w;
    $self->{from_child} = unblock $r;
    $self->{child_err}  = unblock $e;
    $self->{processed}  = 0;

    $self->{child_err_mon} = async {
        while (my $line = $self->{child_err}->readline) {
            warn "(WORKER) $line";
        }
    };

    return $pid;
}

sub is_running {
    my $self = shift;
    return $self->{pid}
        && kill(0, $self->{pid})
        && !$!{ESRCH};
}

sub terminate {
    my ($self, $block) = @_;
    my $pid = $self->{pid};

    if ($self->is_running && $pid) {
        if (kill(0, $pid)) {
            warn("Error killing pid %d: %s", $pid, $!)
                unless kill(9, $pid) || $!{ESRCH};
        }

        if ($block) {
            waitpid($pid, 0);

        } else {
            while ($pid > 0) {
                $pid = waitpid($pid, WNOHANG);
                Coro::AnyEvent::sleep(0.1)
                    if $pid > 0;
            }
        }
    }

    undef $self->{pid};
    undef $self->{to_child};
    undef $self->{from_child};
    undef $self->{child_err};
    undef $self->{child_err_mon};

    return 1;
}

sub send {
    my ($self, $f, $args) = @_;
    croak 'not running' unless $self->is_running;
    $args ||= [];
    my $line = encode([$f, $args]);
    $self->{to_child}->print($line . $EOL);
}

sub recv {
    my $self = shift;
    croak 'not running' unless $self->is_running;
    my $line = $self->{from_child}->readline($EOL);
    my $data = decode($line);

    ++$self->{processed};

    if ($data->[0]) {
        croak $data->[1];
    } else {
        return $data->[1];
    }
}

1;
