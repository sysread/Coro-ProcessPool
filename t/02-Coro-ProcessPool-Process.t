use strict;
use warnings;
use Test2::Bundle::Extended;
use Coro;
use Guard qw(scope_guard);
use List::Util qw(shuffle);
use Coro::ProcessPool::Process;

die 'MSWin32 is not supported' if $^O eq 'MSWin32';

my $timeout = 3;

sub test_sub {
  my ($x) = @_;
  return $x * 2;
}

my @range = (1 .. 20);

subtest 'shutdown' => sub{
  my $proc = Coro::ProcessPool::Process->new;
  ok(my $pid = $proc->pid, 'spawned correctly');

  scope_guard { $proc->join(30); };

  ok(my $id = $proc->send(\&test_sub, [21]), 'final send');
  ok($proc->shutdown($timeout), 'shutdown with pending task');

  my $reply = eval { $proc->recv($id) };
  my $error = $@;

  ok(!$reply, 'no reply received after termination');
  ok($error, 'error thrown in recv after termination');
  like($error, qr/process killed while waiting on this task to complete/, 'expected error');
};

subtest 'in order' => sub{
  my $proc = Coro::ProcessPool::Process->new;
  ok(my $pid = $proc->pid, 'spawned correctly');

  scope_guard { $proc->shutdown($timeout); $proc->join(30); };

  my $count = 0;
  foreach my $i (@range) {
    ok(my $id = $proc->send(\&test_sub, [$i]), "send ($i)");
    ok(my $reply = $proc->recv($id), "recv ($i)");
    is($reply, $i * 2, "receives expected result ($i)");
    is($proc->messages_sent, ++$count, "message count tracking ($i)");
  }
};

=cut
subtest 'out of order' => sub{
  my $proc = Coro::ProcessPool::Process->new;
  ok(my $pid = $proc->pid, 'spawned correctly');

  scope_guard { $proc->shutdown($timeout); $proc->join(30); };

  my %pending;
  foreach my $i (shuffle @range) {
    ok(my $id = $proc->send(\&test_sub, [$i]), "ooo send ($i)");
    $pending{$i} = $id;
  }

  foreach my $i (shuffle keys %pending) {
    my $id = $pending{$i};
    ok(my $reply = $proc->recv($id), "ooo recv ($i)");
    is($reply, $i * 2, "ooo receives expected result ($i)");
  }
};

subtest 'include path' => sub{
  my $proc = Coro::ProcessPool::Process->new(include => ['t/']);
  ok(my $pid = $proc->pid, 'spawned correctly');

  scope_guard { $proc->shutdown($timeout); $proc->join(30); };

  my $rs;
  ok lives{ $rs = $proc->recv($proc->send('TestTaskNoNS', [])) }, 'recv';
  is $rs, 42, 'expected result';
};
=cut

done_testing;
