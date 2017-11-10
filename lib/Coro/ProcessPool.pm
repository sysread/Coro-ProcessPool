package Coro::ProcessPool;
# ABSTRACT: An asynchronous pool of perl processes

use strict;
use warnings;
use Coro;
use AnyEvent;
use Coro::Countdown;
use Coro::ProcessPool::Process qw(worker);
use Coro::ProcessPool::Util qw($CPUS);

sub new{
  my ($class, %param) = @_;

  my $self = bless{
    max_procs => $param{max_procs} || $CPUS,
    max_reqs  => $param{max_reqs},
    include   => $param{include},
    queue     => Coro::Channel->new,
    pool      => Coro::Channel->new,
  }, $class;

  # Initialize worker processes
  for (1 .. $self->{max_procs}) {
    $self->{pool}->put($self->_proc);
  }

  # Start pool worker
  $self->{worker} = async(\&_worker, $self);

  return $self;
}

sub _proc{
  my $self = shift;
  worker(include => $self->{include});
}

sub _worker{
  my $self = shift;

  # Read tasks from the queue
  while (my $task = $self->{queue}->get) {
    my ($caller, $f, @args) = @$task;

    # Wait for a worker process to become available
    WORKER:
    my $ps = $self->{pool}->get;

    # If the worker has serviced at least as many requests as our
    # limit, stop the worker process, put a new one into the pool,
    # and REDO FROM START.
    if ($self->{max_reqs} && $ps->{counter} >= $self->{max_reqs}) {
      # No need to hold up the next task to deal with this
      async_pool{
        my $ps = shift;
        $ps->stop;
        $ps->join;
      } $ps;

      $self->{pool}->put($self->_proc);
      goto WORKER;
    }

    # Ensure our worker is completely initialized
    $ps->await;

    # Send task to our worker process
    my $cv = $ps->send($f, \@args);

    # Schedule a thread to watch for the result and deliver it to the caller
    async_pool{
      my ($k, $cv) = @_;
      my $ret = eval{ $cv->recv };
      $@ ? $k->croak($@) : $k->send($ret);
    } $caller, $cv;

    # Return the worker to the pool
    $self->{pool}->put($ps);
  }

  # The queue is shut down and no tasks remain. Notify workers to shut down.
  my @procs;
  $self->{pool}->shutdown;
  while (my $ps = $self->{pool}->get) {
    push @procs, $ps;
  }

  # Wait for all workers to self-terminate
  $_->await foreach @procs; # some workers might have just been started
  $_->stop  foreach @procs; # stop the workers
  $_->join  foreach @procs; # wait on the process to completely terminate
}

sub shutdown{
  my $self = shift;
  $self->{queue}->shutdown;
}

sub join{
  my $self = shift;
  $self->{worker}->join;
}

sub defer{
  my $self = shift;
  my $cv = AE::cv;
  $self->{queue}->put([$cv, @_]);
  return $cv;
}

sub process{
  my $self = shift;
  $self->defer(@_)->recv;
}

sub map {
  my ($self, $f, @args) = @_;

  # Inverse semaphore to track pending requests
  my $rem = new Coro::Countdown;

  # Queue each argument and store as an ordered list to preserve original
  # ordering of the argments
  my @cvs = map {
    $rem->up;
    $self->defer($f, $_);
  } @args;

  # Collect results, retaining original ordering by respecting the orignial
  # list index
  my @res;
  foreach my $i (0 .. $#args) {
    async_pool {
      $res[$i] = $_[0]->recv;
      $rem->down;
    } $cvs[$i];
  }

  # Wait for all requests to complete and return the result
  $rem->join;
  return @res;
}

sub pipeline {
  my $self = shift;
  return Coro::ProcessPool::Pipeline->new(pool => $self, @_);
}

=head1 SYNOPSIS

  use Coro::ProcessPool;
  use Coro;

  my $pool = Coro::ProcessPool->new(
    max_procs => 4,
    max_reqs  => 100,
    include   => ['/path/to/my/task/classes', '/path/to/other/packages'],
  );

  my $double = sub { $_[0] * 2 };

  #-----------------------------------------------------------------------
  # Process in sequence, waiting for each result in turn
  #-----------------------------------------------------------------------
  my %result;
  foreach my $i (1 .. 1000) {
    $result{$i} = $pool->process($double, $i);
  }

  #-----------------------------------------------------------------------
  # Process as a batch
  #-----------------------------------------------------------------------
  my @results = $pool->map($double, 1 .. 1000);

  #-----------------------------------------------------------------------
  # Defer waiting for result
  #-----------------------------------------------------------------------
  my %deferred;

  $deferred{$_} = $pool->defer($double, $_)
    foreach 1 .. 1000;

  # Later
  foreach my $i (keys %deferred) {
    print "$i = " . $deferred{$i}->() . "\n";
  }

  #-----------------------------------------------------------------------
  # Use a "task class" implementing 'new' and 'run'
  #-----------------------------------------------------------------------
  my $result = $pool->process('Task::Doubler', 21);

  #-----------------------------------------------------------------------
  # Pipelines (work queues)
  #-----------------------------------------------------------------------
  my $pipe = $pool->pipeline;

  # Start producer thread to queue tasks
  my $producer = async {
    while (my $task = get_next_task()) {
      $pipe->queue('Some::TaskClass', $task);
    }

    # Let the pipeline know no more tasks are coming
    $pipe->shutdown;
  };

  # Collect the results of each task as they are received
  while (my $result = $pipe->next) {
    do_stuff_with($result);
  }

  $pool->shutdown;

=head1 DESCRIPTION

Processes tasks using a pool of external Perl processes.

=head1 CONSTRUCTOR

  my $pool = Coro::ProcessPool->new(
    max_procs => 4,
    max_reqs  => 100,
    include   => ['path/to/my/packages', 'some/more/packages'],
  );

=head2 max_procs

The maximum number of processes to run within the process pool. Defaults
to the number of CPUs on the ssytem.

=head2 max_reqs

The maximum number of tasks a worker process may run before being terminated
and replaced with a fresh process. This is useful for tasks that might leak
memory over time.

=head2 include

An optional array ref of directory paths to prepend to the set of directories
the worker process will use to find Perl packages.

=head1 METHODS

=head2 shutdown

Tells the pool to terminate after all pending tasks have been completed. Note
that this does not prevent new tasks from being queued or even processed. Once
called, use L</join> to safely wait until the final task has completed and the
pool is no longer running.

=head2 join

Cedes control to the event loop until the pool is shutdown and has completed
all tasks. If called I<before> L</shutdown>, take care to ensure that another
thread is responsible for shutting down the pool.

=head2 defer

Queues a task to be processed by the pool. Tasks may specified in either of two
forms, as a code ref or the fully qualified name of a perl class which
implements two methods, C<new> and C<run>. Any remaining arguments to C<defer>
are passed unchanged to the code ref or the C<new> method of the task class.

C<defer> will immediately return an L<AnyEvent/condvar> that will wait for and
return the result of the task (or croak if the task generated an error).

  # Using a code ref
  my $cv = $pool->defer(\&func, $arg1, $arg2, $arg3);
  my $result = $cv->recv;

  # With a task class
  my $cv = $pool->defer('Some::Task::Class', $arg1, $arg2, $arg3);
  my $result = $cv->recv;

=head2 process

Calls defer and immediately calls C<recv> on the returned condvar, returning
the result. This is useful if your workflow includes multiple threads which
share the same pool. All arguments are passed unchanged to C<defer>.

=head2 map

Like perl's C<map>, applies a code ref to a list of arguments. This method will
cede until all results have been returned by the pool, returning the result as
a list. The order of arguments and results is preserved as expected.

  my @results = $pool->map(\&func, $arg1, $arg2, $arg3);

=head2 pipeline

Returns a L<Coro::ProcessPool::Pipeline> object which can be used to pipe
requests through to the process pool. Results then come out the other end of
the pipe, not necessarily in the order in which they were queued. It is up to
the calling code to perform task accounting (for example, by passing an id in
as one of the arguments to the task class).

  my $pipe = $pool->pipeline;

  my $producer = async {
    foreach my $args (@tasks) {
      $pipe->queue('Some::Class', $args);
    }

    $pipe->shutdown;
  };

  while (my $result = $pipe->next) {
    ...
  }

All arguments to C<pipeline()> are passed transparently to the constructor of
L<Coro::ProcessPool::Pipeline>. There is no limit to the number of pipelines
which may be created for a pool.

=head1 A NOTE ABOUT IMPORTS AND CLOSURES

Code refs are serialized using L<Data::Dump::Streamer>, allowing closed over
variables to be available to the code being called in the sub-process. Mutated
variables are I<not> updated when the result is returned.

See L<Data::Dump::Streamer/Caveats-Dumping-Closures-(CODE-Refs)> for important
notes regarding closures.

=head2 Use versus require

The C<use> pragma is run at compile time, whereas C<require> is evaluated at
runtime. Because of this, the use of C<use> in code passed directly to the
C<process> method can fail in the worker process because the C<use> statement
has already been evaluated in the parent process when the calling code was
compiled.

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
module (or to expliticly call require and import in the subroutine), which can
then be called in the anonymous routine:

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

Alternately, a task class may be used if dependency management is causing a
headaches:

  my $result = $pool->process('Task::Class', @args);

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

=head1 SEE ALSO

=over

=item L<Coro>

=item L<AnyEvent/condvar>

=back

=cut

1;
