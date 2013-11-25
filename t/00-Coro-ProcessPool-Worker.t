use strict;
use warnings;
use Test::More;
use Coro::ProcessPool;

my $class = 'Coro::ProcessPool::Worker';

use_ok($class) or BAIL_OUT;


done_testing;
