use strict;
use warnings;
use Test::More;
use Coro::ProcessPool;

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool::Worker';

use_ok($class) or BAIL_OUT;

done_testing;
