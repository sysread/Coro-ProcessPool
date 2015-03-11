package Coro::ProcessPool::Process;

use Moo;
use Carp;
use Coro;
use Coro::AnyEvent;
use Const::Fast;
use Data::UUID;
use Types::Standard         qw(-types);
use Coro::Handle            qw(unblock);
use IPC::Open3              qw(open3);
use POSIX                   qw(:sys_wait_h);
use Symbol                  qw(gensym);
use Time::HiRes             qw(time);
use Coro::ProcessPool::Util qw(get_command_path get_args encode decode $EOL);

const our $DEFAULT_WAITPID_INTERVAL => 0.1;
const our $DEFAULT_KILL_TIMEOUT     => 15;

BEGIN {
    if ($^O eq 'MSWin32') {
        die 'MSWin32 is not supported';
    }
};

sub BUILDARGS {
    my ($class, %args) = @_;

    my ($r, $w, $e) = (gensym, gensym, gensym);
    my $cmd  = get_command_path;
    my $args = get_args;
    my $exec = "$cmd $args";
    my $pid  = open3($w, $r, $e, $exec) or croak "Error spawning process: $!";

    $SIG{CHLD} = 'IGNORE';

    $args{pid}       = $pid;
    $args{child_in}  = unblock $r;
    $args{child_out} = unblock $w;
    $args{child_err} = unblock $e;

    return \%args;
}

sub BUILD {
    my $self = shift;
    $self->child_in_watcher;
    $self->child_err_watcher;
    return $self;
}

sub DEMOLISH {
    my ($self, $global_destruct) = @_;
    $self->shutdown;
}

has messages_sent => (
    is       => 'rw',
    isa      => Int,
    init_arg => undef,
    default  => sub { 0 },
);

has pid => (
    is        => 'ro',
    isa       => Int,
    required  => 1,
    clearer   => 'clear_pid',
    predicate => 'is_running',
);

has child_in => (
    is       => 'ro',
    isa      => InstanceOf['Coro::Handle'],
    required => 1,
    clearer  => 'clear_child_in',
);

has child_out => (
    is       => 'ro',
    isa      => InstanceOf['Coro::Handle'],
    required => 1,
    clearer  => 'clear_child_out',
);

has child_err => (
    is       => 'ro',
    isa      => InstanceOf['Coro::Handle'],
    required => 1,
    clearer  => 'clear_child_err',
);

has inbox => (
    is       => 'ro',
    isa      => HashRef[Str, InstanceOf['Coro::Channel']],
    default  => sub { {} },
);

has on_read => (
    is      => 'rw',
    isa     => Maybe[CodeRef],
    clearer => 'clear_on_read',
);

has child_in_watcher => (
    is       => 'lazy',
    isa      => InstanceOf['Coro'],
    init_arg => undef,
    clearer  => 'clear_child_in_watcher',
);

sub _build_child_in_watcher {
    return async {
        my $self = shift;

        while (my $line = $self->child_in->readline($EOL)) {
            if ($self->on_read) {
                $self->on_read->();
                $self->clear_on_read;
            }

            my $msg  = decode($line);
            my ($id, $data) = @$msg;

            if (exists $self->inbox->{$id}) {
                $self->inbox->{$id}->send($data);
            } else {
                warn "Unexpected message received: $id";
            }
        }
    } @_;
}

has child_err_watcher => (
    is       => 'lazy',
    isa      => InstanceOf['Coro'],
    init_arg => undef,
    clearer  => 'clear_child_err_watcher',
);

sub _build_child_err_watcher {
    return async {
        my $self = shift;
        while (my $line = $self->child_err->readline($EOL)) {
            warn sprintf("(WORKER PID %s) %s", ($self->pid || '(DEAD)'), $line);
        }
    } @_;
}

sub cleanup {
    my $self = shift;

    if ($self->child_out) {
        $self->child_out->close;
        $self->clear_child_out;
    }

    if ($self->child_in) {
        $self->child_in_watcher->join;
        $self->child_in->close;
        $self->clear_child_in_watcher;
        $self->clear_child_in;
    }

    if ($self->child_err) {
        $self->child_err->close;
        $self->child_err_watcher->join;
        $self->clear_child_err_watcher;
        $self->clear_child_err;
    }
}

sub join {
    my ($self, $timeout) = @_;
    my $pid   = $self->pid;
    my $start = time;

    while ($pid > 0) {
        $pid = waitpid($pid, WNOHANG);
        Coro::AnyEvent::sleep($DEFAULT_WAITPID_INTERVAL)
          if $pid > 0;

        if ($timeout) {
            my $spent = time - $start;
            if ($spent >= $timeout) {
                return 0;
            }
        }
    }

    $self->clear_pid;
    return 1;
}

sub kill_process {
    my ($self, $timeout) = @_;

    return unless $self->is_running;

    my $id = $self->write('SHUTDOWN');
    my $reply = $self->recv($id);
    $self->child_out->close;

    until ($self->join($timeout)) {
        kill('KILL', $self->pid);
        waitpid($self->pid, 0);
    }
}

sub shutdown {
    my ($self, $timeout) = @_;
    $self->kill_process($timeout);
    $self->cleanup;
    return 1;
}

sub write {
    my ($self, $data) = @_;
    my $id = Data::UUID->new->create_str();
    $self->inbox->{$id} = AnyEvent->condvar;
    $self->child_out->print(encode([$id, $data]) . $EOL);
    ++$self->{messages_sent};
    return $id;
}

sub send {
    my ($self, $f, $args) = @_;
    croak 'not running' unless $self->is_running;
    $args ||= [];
    return $self->write([$f, $args]);
}

sub recv {
    my ($self, $id) = @_;
    croak 'message id not specified' unless $id;
    croak 'message id not found' unless exists $self->inbox->{$id};

    my $data = $self->inbox->{$id}->recv;
    delete $self->inbox->{$id};

    if ($data->[0]) {
        croak $data->[1];
    } else {
        return $data->[1];
    }
}

1;
