package Coro::ProcessPool::Process;
# ABSTRACT: Manager for worker subprocess

use strict;
use warnings;
use Carp;
use Coro;
use Coro::Countdown;
use Data::UUID;
use POSIX qw(:sys_wait_h);
use Coro::Handle qw(unblock);
use AnyEvent::Util qw(run_cmd portable_pipe);
use Coro::ProcessPool::Util qw(get_command_path get_args encode decode $EOL);

use parent 'Exporter';
our @EXPORT_OK = qw(worker);

my $UUID = Data::UUID->new;

sub worker {
  my %param = @_;
  my $inc   = $param{include} // [];  # include directories
  my $cmd   = get_command_path;       # perl path
  my $args  = get_args(@$inc);        # duplicate current -I's along with
                                      # explicit includes; also adds command
                                      # to start worker
  my $exec  = "$cmd $args";           # final worker command

  # Create a pipe for each direction
  my ($child_in, $parent_out)  = portable_pipe;
  my ($parent_in, $child_out)  = portable_pipe;

  # Build instance
  my $proc = bless {
    pid     => undef,                 # will be set by run_cmd
    in      => unblock($parent_in),   # from child (results)
    out     => unblock($parent_out),  # to child (tasks)
    inbox   => {},                    # uuid -> condvar to signal completion of task
    reader  => undef,                 # coro watching child output ($parent_in)
    stopped => undef,                 # condvar to signal when process is terminated
    started => AE::cv,                # signaled when process has self-identified as ready
    counter => 0,                     # total tasks accepted
    pending => Coro::Countdown->new,  # pending task counter
  }, 'Coro::ProcessPool::Process';

  # Launch worker process without blocking
  $proc->{stopped} = run_cmd $exec, (
    'close_all' => 1,
    '$$' => \$proc->{pid},
    '>'  => $child_out,
    '<'  => $child_in,
    '2>' => sub {
      # Reemit errors/warnings to the parent's stderr
      my $err = shift or return; # called once with undef when worker exits
      warn "[worker pid:$proc->{pid}] $err\n";
    },
  );

  # Add callback to clean up pipe handles after process exits
  $proc->{stopped}->cb(sub {
    $proc->{in}->close;
    $proc->{out}->close;
  });

  # Add watcher for worker output
  $proc->{reader} = async {
    my $proc = shift;

    # Worker notifies us that it is initialized by sending its pid, followed by
    # an $EOL. In turn, we wake up any watchers waiting for the process to be
    # ready.
    do {
      my $pid = $proc->{in}->readline($EOL);
      chomp $pid;
      $proc->{started}->send($pid);
    };

    # Read loop
    while (my $line = $proc->{in}->readline($EOL)) {
      my ($id, $error, $data) = decode($line);

      # Signal watchers with result
      if (exists $proc->{inbox}{$id}) {
        if ($error) {
          $proc->{inbox}{$id}->croak($data);
        } else {
          $proc->{inbox}{$id}->send($data);
        }

        # Clean up tracking and decrement pending counter
        delete $proc->{inbox}{$id};
        $proc->{pending}->down;

      } else {
        warn "Unexpected message received: $id";
      }
    }
  } $proc;

  return $proc;
}

sub pid {
  my $proc = shift;
  return $proc->{pid};
}

sub await {
  my $proc = shift;
  $proc->{started}->recv;
}

sub join {
  my $proc = shift;
  $proc->{pending}->join; # wait on all pending tasks to complete
  $proc->{stopped}->recv; # watch for process termination signal
}

sub alive {
  my $proc = shift;
  return 0 unless $proc->{started}->ready;          # has process signaled its own readiness?
  return 0 if $proc->{stopped}->ready;              # has process already been stopped?
  return 1 if waitpid($proc->{pid}, WNOHANG) >= 0;  # does the process look alive?
  return 0;
}

sub stop {
  my $proc = shift;
  if ($proc->alive) {
    # Send command to tell worker to self-terminate
    $proc->{out}->print(encode('', 'self-terminate', []) . $EOL);
  }
}

sub kill {
  my $proc = shift;
  if ($proc->alive) {
    # Force the issue
    kill('KILL', $proc->{pid});
  }
}

sub send {
  my ($proc, $f, $args) = @_;
  croak 'subprocess is not running' unless $proc->alive;

  # Add a watcher to the inbox for this task
  my $id = $UUID->create_str;
  $proc->{inbox}{$id} = AE::cv;

  # Send the task to the worker
  $proc->{out}->print(encode($id, $f, $args || []) . $EOL);

  ++$proc->{counter};   # increment count of total tasks accepted
  $proc->{pending}->up; # increment counter of pending tasks

  # Return condvar that will be signaled by the input watcher when the results
  # for this $id are ready.
  return $proc->{inbox}{$id};
}

1;
