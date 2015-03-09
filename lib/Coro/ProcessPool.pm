package Coro::ProcessPool;

use Moo;
use Types::Standard qw(-types);
use Carp;
use AnyEvent;
use Guard;
use Coro;
use Coro::AnyEvent qw(sleep);
use Coro::Channel;
use Coro::ProcessPool::Process;
use Coro::ProcessPool::Util qw(cpu_count);
use Coro::Semaphore;

our $VERSION = '0.18_3';

if ($^O eq 'MSWin32') {
    die 'MSWin32 is not supported';
}

has max_procs => (
    is      => 'ro',
    isa     => Int,
    default => \&cpu_count,
);

has max_reqs => (
    is      => 'ro',
    isa     => Int,
    default => 0,
);

has procs_lock => (
    is      => 'lazy',
    isa     => InstanceOf['Coro::Semaphore'],
);

sub _build_procs_lock {
    my $self = shift;
    return Coro::Semaphore->new($self->max_procs);
}

has num_procs => (
    is      => 'rw',
    isa     => Int,
    default => 0,
);

has procs => (
    is      => 'ro',
    isa     => ArrayRef[InstanceOf['Coro::Process']],
    default => sub { [] },
);

has inbox => (
    is      => 'lazy',
    isa     => InstanceOf['Coro::Channel'],
);

sub _build_inbox {
  my $self = shift;
  return Coro::Channel->new($self->max_procs);
}

has inbox_worker => (
    is  => 'lazy',
    isa => InstanceOf['Coro'],
);

sub _build_inbox_worker {
    async {
        my $self = shift;

        while (1) {
            my $task = $self->inbox->get or last;
            my ($f, $args, $on_success, $on_error) = @$task;

            async_pool {
                my ($self, $on_success, $on_error) = @_;
                my $result = eval { $self->process($f, $args) };

                if ($@) {
                    my $error = $@;
                    if (ref $on_error && ref $on_error eq 'CODE') {
                        $on_error->($error);
                    }
                }
                else {
                    if (ref $on_success && ref $on_success eq 'CODE') {
                        $on_success->($result);
                    }
                }
            } $self, $on_success, $on_error;
        }
    } @_;
}

has is_running => (
    is      => 'rw',
    isa     => Bool,
    default => 1,
);

sub DEMOLISH {
    my $self = shift;
    $self->shutdown;
}

sub BUILD {
    my $self = shift;
    $self->inbox_worker; # ensure the worker starts
}

sub capacity {
    my $self = shift;
    return scalar(@{$self->procs});
}

sub shutdown {
    my $self = shift;

    $self->is_running(0);

    $self->inbox->shutdown;
    $self->inbox_worker->join;

    my $count = $self->num_procs or return;
    for (1 .. $count) {
        my $proc = shift @{$self->procs};
        $self->kill_proc($proc);
    }
}

sub start_proc {
    my $self = shift;
    my $proc = Coro::ProcessPool::Process->new();
    ++$self->{num_procs};
    return $proc;
}

sub kill_proc {
    my ($self, $proc) = @_;
    $proc->shutdown;
    --$self->{num_procs};
}

sub checkin_proc {
    my ($self, $proc) = @_;

    if (!$self->is_running || ($self->max_reqs && $proc->messages_sent >= $self->max_reqs)) {
        $self->kill_proc($proc);
    } else {
        unshift @{$self->procs}, $proc;
    }
}

sub checkout_proc {
    my $self = shift;
    croak 'not running' unless $self->is_running;

    my $proc;

    # Start a new process if none are available and there are worker slots open
    if ($self->capacity == 0 && $self->num_procs < $self->max_procs) {
        $proc = $self->start_proc;
    } else {
        $proc = shift @{$self->procs};
    }

    return $proc;
}

sub process {
    my ($self, $f, $args) = @_;

    my $guard = $self->procs_lock->guard;

    my $proc = $self->checkout_proc;
    scope_guard { $self->checkin_proc($proc) };

    my $msgid = $proc->send($f, $args);
    return $proc->recv($msgid);
}

sub map {
    my ($self, $f, @args) = @_;
    my @deferred = map { $self->defer($f, [$_]) } @args;
    return map { $_->() } @deferred;
}

sub defer {
    my $self = shift;
    my $cv   = AnyEvent->condvar;

    async_pool {
        my ($self, $cv, @args) = @_;
        my $result = eval { $self->process(@args) };
        $cv->croak($@) if $@;
        $cv->send($result);
    } $self, $cv, @_;

    return sub { $cv->recv };
}

sub queue {
    my ($self, $f, $args, $on_success, $on_error) = @_;
    $self->inbox->put([$f, $args, $on_success, $on_error]);
}

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

=head2 process($f, $args)

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

=head2 queue($f, $args, $callback)

Queues the execution of C<$f->(@$args)> and returns immediately. If
C<$callback> is specified and is a code ref, it will be called with the result
of the executed code once the task is processed. Note that the callback is not
provided with any identifying information about the task being executed. That
is the responsibility of the caller. It is also the caller's responsibility to
coordinate any code that depends on the result, for example using a condition
variable.

    my $cv = AnyEvent->condvar;

    sub make_callback {
        my $n = shift;
        return sub {
            my $result = shift;
            print "2 * $n = $result\n";
            $cv->send;
        }
    }

    $pool->queue($doubler_function, [21], make_callback(21));
    $cv->recv;

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
