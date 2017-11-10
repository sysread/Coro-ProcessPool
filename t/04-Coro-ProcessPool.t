use strict;
use warnings;
use List::Util qw(shuffle);
use AnyEvent;
use Coro;
use Coro::AnyEvent;
use Test::More;
use Guard;
use Coro::Channel;
use Sub::Override;

BAIL_OUT 'OS unsupported' if $^O eq 'MSWin32';

my $class = 'Coro::ProcessPool';

my $doubler = sub {
  my $x = shift;
  return $x * 2;
};

use_ok($class) or BAIL_OUT;

subtest 'start & stop' => sub {
  my $cpus   = 1;
  my $override = Sub::Override->new('Coro::ProcessPool::Util::cpu_count' => sub { $cpus });
  my $pool = new_ok($class) or BAIL_OUT 'Failed to create class';
  is($pool->max_procs, $cpus, "max procs set automatically to number of cpus ($cpus)");
  $pool->shutdown;
};

subtest 'checkout_proc' => sub {
  my $pool = new_ok($class, [max_procs => 1])
    or BAIL_OUT 'Failed to create class';

  # Checkout before process started
  my $proc = $pool->checkout_proc;

  ok(defined $proc, 'new process spawned and acquired');
  isa_ok($proc, 'Coro::ProcessPool::Process');
  ok(defined $proc->pid, 'new process has a pid');

  is($pool->capacity, 0, 'capacity correct');

  $pool->checkin_proc($proc);
  is($pool->capacity, 1, 'capacity correct');

  # Checkout after process started
  $proc = $pool->checkout_proc;
  is($pool->capacity, 0, 'correct capacity');

  ok(defined $proc, 'previously spawned process acquired');
  isa_ok($proc, 'Coro::ProcessPool::Process');

  $pool->checkin_proc($proc);
  is($pool->capacity, 1, 'correct pool capacity after all procs checked in');

  # Shutdown
  $pool->shutdown;

  eval { $pool->checkout_proc };
  like($@, qr/not running/, 'checkout after shutdown throws error');
};

subtest 'max reqs' => sub {
  my $pool = new_ok($class, [max_procs => 1, max_reqs => 1]) or BAIL_OUT 'Failed to create class';
  my ($pid, $proc);

  # Check out proc, grab the pid, fudge messages sent, and check it back in. Then checkout the
  # next proc and ensure it's not the same one.
  $proc = $pool->checkout_proc;
  $pid = $proc->pid;
  ++$proc->{counter};
  $pool->checkin_proc($proc);

  # Check out new proc and verify it has a new pid
  $proc = $pool->checkout_proc;
  ok($pid != $proc->pid, 'max_reqs correctly spawns new processes');

  # Verify that it doesn't happen when messages_sent isn't fudged.
  $pid = $proc->pid;
  $pool->checkin_proc($proc);
  $proc = $pool->checkout_proc;
  is($pid, $proc->pid, 'max_reqs does not respawn when unnecessary');
  $pool->checkin_proc($proc);

  $pool->shutdown;
};

subtest 'process' => sub {
  my $pool = new_ok($class, [max_procs => 2, max_reqs => 3]) or BAIL_OUT 'Failed to create class';
  my $count = 10;
  my %result;

  foreach my $i (1 .. $count) {
    my $result = $pool->process($doubler, [ $i ]);
    is($result, $i * 2, 'expected result');
  }

  $pool->shutdown;
};

subtest 'defer' => sub {
  my $pool = new_ok($class, [max_procs => 2, max_reqs => 3]) or BAIL_OUT 'Failed to create class';
  my $count = 10;
  my %result;

  foreach my $i (shuffle 1 .. $count) {
    $result{$i} = $pool->defer($doubler, [$i]);
  }

  foreach my $i (1 .. $count) {
    is($result{$i}->(), $i * 2, "expected result $i");
  }

  $pool->shutdown;
};

subtest 'map' => sub {
  my $pool = new_ok($class, [max_procs => 2, max_reqs => 3]) or BAIL_OUT 'Failed to create class';
  my @numbers  = 1 .. 10;
  my @expected = map { $_ * 2 } @numbers;
  my @actual   = $pool->map($doubler, @numbers);
  is_deeply(\@actual, \@expected, 'expected result');

  $pool->shutdown;
};

subtest 'task errors' => sub {
  my $pool = new_ok($class, [max_procs => 2, max_reqs => 3]) or BAIL_OUT 'Failed to create class';
  my $croaker = sub {
    my ($x) = @_;
    return $x / 0;
  };

  my $result = eval { $pool->process($croaker, [1]) };
  my $error  = $@;

  ok($error, 'processing failure croaks');

  $pool->shutdown;
};

subtest 'two pools' => sub {
  my $pool = new_ok($class, [max_procs => 2, max_reqs => 3]) or BAIL_OUT 'Failed to create class';
  my $pool2 = new_ok($class, [max_procs => 2]);
  my $count = 10;
  my %result;

  foreach my $i (1 .. $count) {
    if ($i % 2 == 0) {
      my $result = $pool->process($doubler, [ $i ]);
      is($result, $i * 2, 'expected result (pool 1)');
    } else {
      my $result = $pool2->process($doubler, [ $i ]);
      is($result, $i * 2, 'expected result (pool 2)');
    }
  }

  $pool2->shutdown;

  $pool->shutdown;
};

SKIP: {
  skip('enable with CORO_PROCESSPOOL_ENABLE_EXPENSIVE_TESTS=1', 1)
    unless $ENV{CORO_PROCESSPOOL_ENABLE_EXPENSIVE_TESTS};

  subtest 'large tasks' => sub {
    my $pool = new_ok($class, [max_procs => 4, max_reqs => 2]) or BAIL_OUT 'Failed to create class';
    my $size  = 1_000_000;
    my $count = 20;

    my $f = sub {
      my $data = $_[0];
      my $res  = [ map { $_ * 2 } @$data ];
      return $res;
    };

    my %pending;
    my %expected;

    foreach my $i (1 .. $count) {
      my $data = [($i) x $size];
      $expected{$i} = [($i * 2) x $size];
      $pending{$i}  = $pool->defer($f, [$data]);
    }

    foreach my $i (keys %pending) {
      is_deeply($pending{$i}->(), $expected{$i}, 'expected result');
    }

    $pool->shutdown;
  };
};

done_testing;
