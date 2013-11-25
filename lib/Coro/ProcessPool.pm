package Coro::ProcessPool;

use strict;
use warnings;
use Carp;

use Coro;
use Coro::Channel;
use Coro::Storable qw(freeze thaw);
use MIME::Base64 qw(encode_base64 decode_base64);
use Sys::CPU;
use Coro::ProcessPool::Process;

use fields qw(
    max_procs
    num_procs
    max_reqs
    procs
);

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub new {
    my ($class, %param) = @_;
    my $self = fields::new($class);
    $self->{max_procs} = $param{max_procs} || Sys::CPU::cpu_count();
    $self->{max_reqs}  = $param{max_reqs}  || 0;
    $self->{num_procs} = 0;
    $self->{procs}     = Coro::Channel->new();
    return $self;
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub shutdown {
    my $self = shift;
    for (1 .. $self->{num_procs}) {
        my $proc = $self->{procs}->get;
        $proc->terminate;
        --$self->{num_procs};
    }
}

sub start_proc {
    my $self = shift;
    my $proc = Coro::ProcessPool::Process->new();
    $proc->spawn;
    ++$self->{num_procs};
    return $proc;
}

sub kill_proc {
    my ($self, $proc) = @_;
    $proc->terminate;
    --$self->{num_procs};
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub process {
    my ($self, $f, $args) = @_;
    ref $f eq 'CODE' || croak 'expected CODE ref to execute';
    $args ||= [];
    ref $args eq 'ARRAY' || croak 'expected ARRAY ref of arguments';

    my $proc;
    if ($self->{procs}->size == 0 && $self->{num_procs} < $self->{max_procs}) {
        $proc = $self->start_proc;
    }

    $proc = $self->{procs}->get unless defined $proc;

    if ($self->{max_reqs} > 0 && $proc->{processed} >= $self->{max_reqs}) {
        $self->kill_proc($proc);
        $proc = $self->start_proc;
    }

    my $result = eval {
        $proc->send($f, $args);
        $proc->recv;
    };

    $self->{procs}->put($proc);

    if ($@) {
        croak $@;
    } else {
        return $result;
    }
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub DESTROY { $_[0]->shutdown }

1;
__END__

=head1 NAME

Coro::ProcessPool - an asynchronous process pool

=head1 SYNOPSIS

    use Coro::ProcessPool;

    my $pool = Coro::ProcessPool->new(
        max_procs => 4,
        max_reqs  => 100,
    );

    my %result;
    foreach my $i (1 .. 1000) {
        $result{$i} = $pool->process(sub { shift * 2 }, $i);
    }

    $pool->shutdown;

=head1 DESCRIPTION

Processes tasks using a pool of external Perl processes.

=head1 METHODS

=head2 new

Creates a new process pool. Processes will be spawned as needed.

=head2 max_procs

This is the maximum number of child processes to maintain. If all processes are
busy handling tasks, further calls to L<./process> will yield until a process
becomes available.

=head2 max_reqs

If this is a positive number (defaults to 0), child processes will be
terminated and replaced after handling C<max_reqs> tasks. Choosing the correct
value for C<max_reqs> is a tradeoff between the need to clear memory leaks in
the child process and the time it takes to spawn a new process and import any
packages used by client code.

=head2 process($f, $args)

Processes code ref C<$f> in a child process from the pool. If C<$args> is
provided, it is an array ref of arguments that will be passed to C<$f>. Returns
the result of calling C<$f->(@$args)>.

This call will yield until the results become available. If all processes are
busy, this method will block until one becomes available. Processes are spawned
as needed, up to C<max_procs>, from this method. Also note that the use of
C<max_reqs> can cause this method to yield while a new process is spawned.

=head2 shutdown

Shuts down all processes and resets state on the process pool. After calling
this method, the pool is effectively in a new state and may be used normally.

=head1 AUTHOR

Jeff Ober mailto:jeffober@gmail.com

=head1 LICENSE

BSD License
