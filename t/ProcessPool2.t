use strict;
use warnings;
use Test2::Bundle::Extended;
use Coro;
use Coro::ProcessPool2;

bail_out 'OS unsupported' if $^O eq 'MSWin32';

sub double { $_[0] * 2 }

my $pool = Coro::ProcessPool2->new(
  max_procs => 2,
  max_reqs  => 3,
);

my %result;

ok $result{$_} = $pool->defer(\&double, $_), "defer $_"
  for 1 .. 20;

$pool->shutdown;

is $result{$_}->recv, $_ * 2, "resolve $_"
  for keys %result;

done_testing;
