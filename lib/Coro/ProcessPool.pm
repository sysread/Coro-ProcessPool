package Coro::ProcessPool;

use strict;
use warnings;
use Carp;

use AnyEvent;
use Coro;
use Coro::AnyEvent qw(sleep);
use Coro::Channel;
use Coro::ProcessPool::Process;
use Coro::ProcessPool::Util qw(cpu_count);

our $VERSION = '0.15_02';

if ($^O eq 'MSWin32') {
    die 'MSWin32 is not supported';
}

sub new {
    my ($class, %param) = @_;
    return bless {
        max_procs => $param{max_procs} || cpu_count,
        max_reqs  => $param{max_reqs}  || 0,
        num_procs => 0,
        procs     => Coro::Channel->new(),
    }, $class;
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

sub checkin_proc {
    my ($self, $proc) = @_;
    $self->{procs}->put($proc);
}

sub checkout_proc {
    my ($self, $timeout) = @_;

    # Start a new process if none are available and there are worker slots open
    if ($self->{procs}->size == 0 && $self->{num_procs} < $self->{max_procs}) {
        return $self->start_proc;
    }

    if (!defined $timeout) {
        return $self->{procs}->get;
    } else {
        my $cv = AnyEvent->condvar;
        my $proc;

        my $thread_timer = async {
            Coro::AnyEvent::sleep $timeout;
            $cv->send(0);
        };

        my $thread_proc = async {
            $proc = $self->{procs}->get;
            $cv->send(1);
        };

        my $result = $cv->recv;

        if ($result) {
            $thread_timer->cancel;
            return $proc;
        } else {
            croak 'timed out waiting for available process';
        }
    }
}

sub process {
    my ($self, $f, $args, $timeout) = @_;
    defined $f || croak 'expected CODE ref or task class (string) to execute';
    $args ||= [];
    ref $args eq 'ARRAY' || croak 'expected ARRAY ref of arguments';

    my $proc = $self->checkout_proc($timeout);

    # Restart the process if the worker is exhausted
    if ($self->{max_reqs} > 0 && $proc->{processed} >= $self->{max_reqs}) {
        $self->kill_proc($proc);
        $proc = $self->start_proc;
    }

    # Send the task
    my $msgid = $proc->send($f, $args);

    # Replace process in the pool as soon as result is ready on the connection
    $proc->readable;
    $self->{procs}->put($proc);

    # Collect and return the result
    return $proc->recv($msgid);
}

sub map {
    my ($self, $f, @args) = @_;
    my @deferred = map { $self->defer($f, [$_]) } @args;
    return map { $_->() } @deferred;
}

sub defer {
    my ($self, $f, $args) = @_;
    my $arr = wantarray;
    my $cv  = AnyEvent->condvar;

    async_pool {
        my $arr = shift;

        if ($arr) {
            my @results = eval { process(@_) };
            $cv->croak($@) if $@;
            $cv->send(@results);
        } else {
            my $result = eval { process(@_) };
            $cv->croak($@) if $@;
            $cv->send($result);
        }
    } $arr, $self, $f, $args;

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

    # Use a "task class", implementing 'new' and 'run'
    my $result = $pool->process('Task::Doubler', 21);

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

=head2 process($f, $args, $timeout)

Processes code ref C<$f> in a child process from the pool. If C<$args> is
provided, it is an array ref of arguments that will be passed to C<$f>. Returns
the result of calling $f->(@$args).

Alternately, C<$f> may be the name of a class implementing the methods C<new>
and C<run>, in which case the result is equivalent to calling
$f->new(@$args)->run(). Note that the include path for worker processes is
identical to that of the calling process.

This call will yield until the results become available. If all processes are
busy, this method will block until one becomes available. Processes are spawned
as needed, up to C<max_procs>, from this method. Also note that the use of
C<max_reqs> can cause this method to yield while a new process is spawned.

A timeout may be optionally specified in fractional seconds. If specified,
C<$timeout> will cause C<process> to croak if C<$timeout> seconds pass an no
process becomes available to handle the task.

Note that the timeout only applies to the time it takes to acquire an available
process. It does not watch the time it takes to perform the task.

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

=head1 A NOTE ABOUT IMPORTS AND CLOSURES

Code refs are serialized using L<Storable> to pass them to the worker
processes. Once deserialized in the pool process, these functions can no
longer see the stack as it is in the parent process. Therefore, imports and
variables external to the function are unavailable.

Something like this will not work:

    use Foo;
    my $foo = Foo->new();

    my $result = $pool->process(sub {
        return $foo->bar; # $foo not found
    });

Nor will this:

    use Foo;
    my $result = $pool->process(sub {
        my $foo = Foo->new; # Foo not found
        return $foo->bar;
    });

The correct way to do this is to import from within the function:

    my $result = $pool->process(sub {
        require Foo;
        my $foo = Foo->new();
        return $foo->bar;
    });

...or to pass in external variables that are needed by the function:

    use Foo;
    my $foo = Foo->new();

    my $result = $pool->process(sub { $_[0]->bar }, [ $foo ]);

=head2 Use versus require

The C<use> pragma is run a compile time, whereas C<require> is evaluated at
runtime. Because of this, the use of C<use> in code passed directly to the
C<process> method can fail because the C<use> statement has already been
evaluated when the calling code was compiled.

This will not work:

    $pool->process(sub {
        use Foo;
        my $foo = Foo->new();
    });

This will work:

    $pool->process(sub {
        require Foo;
        my $foo = Foo->new();
    });

If C<use> is necessary (for example, to import a method or transform the
calling code via import), it is recommended to move the code into its own
module, which can then be called in the anonymous routine:

    package Bar;

    use Foo;

    sub dostuff {
        ...
    }

Then, in your caller:

    $pool->process(sub {
        require Bar;
        Bar::dostuff();
    });

=head2 If it's a problem...

Use the task class method if the loading requirements are causing headaches:

    my $result = $pool->process('Task::Class', [@args]);

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
