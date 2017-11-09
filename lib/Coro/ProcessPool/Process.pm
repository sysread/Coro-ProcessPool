package Coro::ProcessPool::Process;
# ABSTRACT: Manager for worker subprocess

use strict;
use warnings;
use Carp;
use Coro;
use Coro::Countdown;
use Data::UUID;
use Coro::AnyEvent;
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(time);
use Coro::Handle qw(unblock);
use AnyEvent::Util qw(run_cmd portable_pipe);
use Coro::ProcessPool::Util qw(get_command_path get_args encode decode $EOL);

use parent 'Exporter';
our @EXPORT_OK = qw(worker);

sub worker {
  my %param = @_;
  my $inc   = $param{include} // [];
  my $cmd   = get_command_path;
  my $args  = get_args(@$inc);
  my $exec  = "$cmd $args";

  my ($child_in, $parent_out)  = portable_pipe;
  my ($parent_in, $child_out)  = portable_pipe;

  my $proc = bless {
    pid     => undef,
    in      => unblock($parent_in),
    out     => unblock($parent_out),
    inbox   => {},
    reader  => undef,
    stopped => undef,
    started => AE::cv,
    counter => 0,
    pending => Coro::Countdown->new,
  }, 'Coro::ProcessPool::Process';

  $proc->{stopped} = run_cmd $exec, (
    'close_all' => 1,
    '$$' => \$proc->{pid},
    '>'  => $child_out,
    '<'  => $child_in,
    '2>' => sub {
      my $err = shift or return;
      warn "[worker pid:$proc->{pid}] $err\n";
    },
  );

  $proc->{stopped}->cb(sub {
    $proc->{in}->close;
    $proc->{out}->close;
  });

  $proc->{reader} = async {
    my $proc = shift;

    do {
      my $pid = $proc->{in}->readline($EOL);
      chomp $pid;
      $proc->{started}->send($pid);
    };

    while (my $line = $proc->{in}->readline($EOL)) {
      my ($id, $error, $data) = decode($line);

      if (exists $proc->{inbox}{$id}) {
        if ($error) {
          $proc->{inbox}{$id}->croak($data);
        } else {
          $proc->{inbox}{$id}->send($data);
        }

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
  $proc->{pending}->join;
  $proc->{stopped}->recv;
}

sub alive {
  my $proc = shift;
  return 0 unless $proc->{started}->ready;
  return 0 if $proc->{stopped}->ready;
  return 1 if waitpid($proc->{pid}, WNOHANG) >= 0;
  return 0;
}

sub stop {
  my $proc = shift;
  if ($proc->alive) {
    $proc->{out}->print(encode('', 'self-terminate', []) . $EOL);
  }
}

sub kill {
  my $proc = shift;
  if ($proc->alive) {
    kill('KILL', $proc->{pid});
  }
}

sub send {
  my ($proc, $f, $args) = @_;
  croak 'subprocess is not running' unless $proc->alive;

  # Add a watcher to the inbox for this task
  my $id = Data::UUID->new->create_str;
  $proc->{inbox}{$id} = AE::cv;

  # Send the task to the worker
  $proc->{out}->print(encode($id, $f, $args || []) . $EOL);

  ++$proc->{counter};
  $proc->{pending}->up;

  return $proc->{inbox}{$id};
}

1;
