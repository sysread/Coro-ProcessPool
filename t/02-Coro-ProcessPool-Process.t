use strict;
use warnings;
use Test2::Bundle::Extended;
use Coro;
use Coro::ProcessPool::Process qw(worker);

die 'MSWin32 is not supported' if $^O eq 'MSWin32';

sub double { $_[0] * 2 }

subtest 'start/stop' => sub {
  ok my $proc = worker, 'spawn';
  ok !$proc->alive, 'prenatal';

  $proc->await;
  ok $proc->alive, 'alive';

  $proc->stop;
  $proc->join;
  ok !$proc->alive, 'stopped';
};

subtest 'send/recv' => sub {
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

subtest 'multiple' => sub {
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

subtest 'include' => sub {
  ok my $proc = worker(include => ['./t']), 'spawn';
  $proc->await;

  ok my $result = $proc->send('TestTaskNoNS', []), 'send task class';
  is $result->recv, 42, 'expected result';

  $proc->stop;
  $proc->join;
  ok !$proc->alive, 'stopped';
};

done_testing;
