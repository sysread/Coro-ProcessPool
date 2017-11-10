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

  for (1 .. $self->{max_procs}) {
    $self->{pool}->put($self->_proc);
  }

  $self->{worker} = async(\&_worker, $self);

  return $self;
}

sub _proc{
  my $self = shift;
  worker(include => $self->{include});
}

sub _worker{
  my $self = shift;

  while (my $task = $self->{queue}->get) {
    my ($caller, $f, @args) = @$task;

    WORKER:
    my $ps = $self->{pool}->get;
    $ps->await;

    if ($self->{max_reqs} && $ps->{counter} >= $self->{max_reqs}) {
      async_pool{ my $ps = shift; $ps->stop; $ps->join; } $ps;
      $self->{pool}->put($self->_proc);
      goto WORKER;
    }

    $ps->await;
    my $cv = $ps->send($f, \@args);

    async_pool{
      my ($k, $cv) = @_;
      my $ret = eval{ $cv->recv };
      $@ ? $k->croak($@) : $k->send($ret);
    } $caller, $cv;

    $self->{pool}->put($ps);
  }

  my @procs;
  $self->{pool}->shutdown;
  while (my $ps = $self->{pool}->get) {
    push @procs, $ps;
  }

  $_->await foreach @procs;
  $_->stop  foreach @procs;
  $_->join  foreach @procs;
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
  my $rem = new Coro::Countdown;
  my @def = map { $rem->up; $self->defer($f, $_) } @args;
  my @res;

  foreach my $i (0 .. $#args) {
    async_pool {
      $res[$i] = $_[0]->recv;
      $rem->down;
    } $def[$i];
  }

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

Queues a task to be processed by the pool. Tasks may come in two forms, as a
code ref or the fully qualified name of a perl class which implements two
methods, C<new> and C<run>.

=head2 process

=head2 map

=head2 pipeline

Returns a L<Coro::ProcessPool::Pipeline> object which can be used to pipe
requests through to the process pool. Results then come out the other end of
the pipe. It is up to the calling code to perform task account (for example, by
passing an id in as one of the arguments to the task class).

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

If the pool is shutdown while the pipeline is active, any tasks pending in
L<Coro::ProcessPool::Pipeline/next> will fail and cause the next call to
C<next()> to croak.

=head1 A NOTE ABOUT IMPORTS AND CLOSURES

Code refs are serialized using L<Data::Dump::Streamer>, allowing closed over
variables to be available to the code being called in the sub-process. Note
that mutated variables are I<not> updated when the result is returned.

See L<Data::Dump::Streamer/Caveats-Dumping-Closures-(CODE-Refs)> for important
notes regarding closures.

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

=cut

1;
