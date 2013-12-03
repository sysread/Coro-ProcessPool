package Coro::ProcessPool;

use strict;
use warnings;
use Carp;

use AnyEvent;
use Coro;
use Coro::Channel;
use Coro::Storable qw(freeze thaw);
use Guard qw(scope_guard);
use MIME::Base64 qw(encode_base64 decode_base64);
use Sys::Info;
use Coro::ProcessPool::Process;

our $VERSION = 0.04;

if ($^O eq 'MSWin32') {
    die 'MSWin32 is not supported';
}

use fields qw(
    max_procs
    num_procs
    max_reqs
    procs
);

sub new {
    my ($class, %param) = @_;
    my $self = fields::new($class);
    $self->{max_procs} = $param{max_procs} || _cpu_count();
    $self->{max_reqs}  = $param{max_reqs}  || 0;
    $self->{num_procs} = 0;
    $self->{procs}     = Coro::Channel->new();
    return $self;
}

sub _cpu_count {
    my $info = Sys::Info->new();
    my $cpu  = $info->device('CPU');
    return $cpu->count;
}

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

    scope_guard { $self->{procs}->put($proc) };
    $proc->send($f, $args);
    return $proc->recv;
}

sub map {
    my ($self, $f, @args) = @_;

    my @results;
    my @threads;

    foreach my $i (0 .. $#args) {
        push @threads, async {
            $results[$i] = [ process(@_) ];
        } $self, $f, [$args[$i]];
    }

    $_->join foreach @threads;

    return map { @$_ } @results;
}

sub defer {
    my ($self, $f, $args) = @_;
    my $arr = wantarray;
    my $cv  = AnyEvent->condvar;

    async_pool {
        if ($arr) {
            my @results = eval { process(@_) };
            $cv->croak($@) if $@;
            $cv->send(@results);
        } else {
            my $result = eval { process(@_) };
            $cv->croak($@) if $@;
            $cv->send($result);
        }
    } $self, $f, $args;

    return sub { $cv->recv };
}

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

    my $double = sub { $_[0] * 2 };

    # Process in sequence
    my %result;
    foreach my $i (1 .. 1000) {
        $result{$i} = $pool->process($double, [$i]);
    }

    # Process as a batch
    my @results = $pool->map($double, 1 .. 1000);

    # Defer waiting for result
    my %deferred = map { $_ => $pool->defer($double, [$_]) } 1 .. 1000);
    foreach my $i (keys %deferred) {
        print "$i = " . $deferred{$i}->() . "\n";
    }

    $pool->shutdown;

=head1 DESCRIPTION

Processes tasks using a pool of external Perl processes.

=head1 METHODS

=head2 new

Creates a new process pool. Processes will be spawned as needed.

=over

=item max_procs

This is the maximum number of child processes to maintain. If all processes are
busy handling tasks, further calls to L<./process> will yield until a process
becomes available. If not specified, defaults to the number of CPUs on the
system.

=item max_reqs

If this is a positive number (defaults to 0), child processes will be
terminated and replaced after handling C<max_reqs> tasks. Choosing the correct
value for C<max_reqs> is a tradeoff between the need to clear memory leaks in
the child process and the time it takes to spawn a new process and import any
packages used by client code.

=back

=head2 process($f, $args)

Processes code ref C<$f> in a child process from the pool. If C<$args> is
provided, it is an array ref of arguments that will be passed to C<$f>. Returns
the result of calling C<$f->(@$args)>.

This call will yield until the results become available. If all processes are
busy, this method will block until one becomes available. Processes are spawned
as needed, up to C<max_procs>, from this method. Also note that the use of
C<max_reqs> can cause this method to yield while a new process is spawned.

=head2 map($f, @args)

Applies C<$f> to each value in C<@args> in turn and returns a list of the
results. Although the order in which each argument is processed is not
guaranteed, the results are guaranteed to be in the same order as C<@args>,
even if the result of calling C<$f> returns a list itself (in which case, the
results of that calcuation is flattened into the list returned by C<map>.

=head2 defer($f, $args)

Similar to L<./process>, but returns immediately. The return value is a code
reference that, when called, returns the results of calling C<$f->(@$args)>.

    my $deferred = $pool->defer($coderef, [ $x, $y, $z ]);
    my $result   = $deferred->();

=head2 shutdown

Shuts down all processes and resets state on the process pool. After calling
this method, the pool is effectively in a new state and may be used normally.

=head1 COMPATIBILITY

C<Coro::ProcessPool> will likely break on Win32 due to missing support for
non-blocking file descriptors (Win32 can only call C<select> and C<poll> on
actual network sockets). Without rewriting this as a network server, which
would impact performance and be really annoying, it is likely this module will
not support Win32 in the near future.

The following modules will get you started if you wish to explore a synchronous
process pool on Windows:

=over

=item L<Win32::Process>

=item L<Win32::IPC>

=item L<Win32::Pipe>

=back

=head1 AUTHOR

Jeff Ober <jeffober@gmail.com>

=head1 LICENSE

BSD License
