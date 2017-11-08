package Coro::ProcessPool::Worker;

use strict;
use warnings;
use Coro;
use Coro::Handle qw(unblock);
use Coro::ProcessPool::Util qw($EOL decode encode);
use Module::Load qw(load);
use Devel::StackTrace;

sub run {
  my $in  = unblock *STDIN;
  my $out = unblock *STDOUT;

  $out->print($$ . $EOL);

  while (my $line = $in->readline($EOL)) {
    my @task = decode($line);

    if ($task[1] eq 'self-terminate') {
      last;
    }

    async_pool {
      my ($out, $id, $task, $args) = @_;
      my ($error, $result) = process_task($task, $args);
      $out->print(encode($id, $error, $result) . $EOL);
    } $out, @task;
  }

  $in->close;
  $out->close;
  exit 0;
}

sub process_task {
  my ($task, $args) = @_;

  my $result = eval {
    if (ref $task && ref $task eq 'CODE') {
      $task->(@$args);
    } else {
      load $task;
      die "method new() not found for class $task" unless $task->can('new');
      die "method run() not found for class $task" unless $task->can('run');
      my $obj = $task->new(@$args);
      $obj->run;
    }
  };

  if ($@) {
    my $error = $@;
    my $trace = Devel::StackTrace->new(
      message      => $error,
      indent       => 1,
      ignore_class => ['Coro::ProcessPool::Util', 'Coro', 'AnyEvent'],
    );
    return (1, $trace->as_string);
  }

  return (0, $result);
}

1;
