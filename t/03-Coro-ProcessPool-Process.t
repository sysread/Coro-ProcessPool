use strict;
use warnings;
use Test2::Bundle::Extended;
use Coro;
use Coro::AnyEvent;
use Coro::ProcessPool::Process qw(worker);

bail_out 'OS unsupported' if $^O eq 'MSWin32';

sub double { $_[0] * 2 }

sub timed_test ($&) {
  my ($name, $test) = @_;

  subtest $name => sub {
    my $work = async { $_[0]->() } $test;

    my $timer = async {
      Coro::AnyEvent::sleep(30);
      $work->throw('timed out');
    };

    $work->join;
    $timer->cancel;
    ok 'test did not time out';
  };
}

timed_test 'start/stop' => sub {
  ok my $proc = worker, 'spawn';
  ok !$proc->alive, 'prenatal';

  $proc->await;
  ok $proc->alive, 'alive';

  $proc->stop;
  $proc->join;
  ok !$proc->alive, 'stopped';
};

timed_test 'send/recv' => sub {
  ok my $proc = worker, 'spawn';
  $proc->await;

  is $proc->{counter}, 0, 'counter starts at zero';

  ok my $result = $proc->send(\&double, [21]), 'send';
  is $result->recv, 42, 'recv';
  is $proc->{counter}, 1, 'counter incremented';

  $proc->stop;
  $proc->join;
  ok !$proc->alive, 'stopped';
};

timed_test 'multiple' => sub {
  ok my $proc = worker, 'spawn';
  $proc->await;

  is $proc->{counter}, 0, 'counter starts at zero';

  my %sent;
  foreach my $i (1 .. 10) {
    ok $sent{$i} = $proc->send(\&double, [$i]), "send $i";
    is $proc->{counter}, $i, 'counter incremented';
  }

  foreach my $i (keys %sent) {
    is $sent{$i}->recv, $i * 2, "recv $i";
  }

  $proc->stop;
  $proc->join;
  ok !$proc->alive, 'stopped';
};

timed_test 'include' => sub {
  ok my $proc = worker(include => ['./t']), 'spawn';
  $proc->await;

  ok my $result = $proc->send('TestTaskNoNS', []), 'send task class';
  is $result->recv, 42, 'expected result';

  $proc->stop;
  $proc->join;
  ok !$proc->alive, 'stopped';
};

timed_test 'join' => sub {
  ok my $proc = worker, 'spawn';
  $proc->await;

  my %result;
  async {
    my ($cv1, $cv2, $cv3) = @_;
    $result{1} = $cv1->recv;
    $result{2} = $cv2->recv;
    $result{3} = $cv3->recv;
  } $proc->send(\&double, [1]),
    $proc->send(\&double, [2]),
    $proc->send(\&double, [3]);

  $proc->stop;
  $proc->join;
  ok !$proc->alive, 'stopped';

  is \%result, {1 => 2, 2 => 4, 3 => 6}, 'result';
};

done_testing;
