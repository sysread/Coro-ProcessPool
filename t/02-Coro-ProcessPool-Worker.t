use strict;
use warnings;
use Test::More;
use Coro;
use Coro::AnyEvent;

BAIL_OUT 'OS unsupported' if $^O eq 'MSWin32';

use Coro::ProcessPool::Worker;

my $doubler = sub {
  my $x = shift;
  return $x * 2;
};

subtest 'process task' => sub {
  my $success = [Coro::ProcessPool::Worker::process_task($doubler, [21])];
  is_deeply($success, [0, 42], 'code ref-based task produces expected result');

  my $croaker = sub { die "TEST MESSAGE" };
  my $failure = [Coro::ProcessPool::Worker::process_task($croaker, [])];
  is($failure->[0], 1, 'error generates correct code');
  like($failure->[1], qr/TEST MESSAGE/, 'stack trace includes error message');

  my $result = [Coro::ProcessPool::Worker::process_task('t::TestTask', [])];
  is_deeply($result, [0, 42], 'class-based task produces expected result');
};

done_testing;
