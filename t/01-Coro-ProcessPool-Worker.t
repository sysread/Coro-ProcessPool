use strict;
use warnings;
use Test::More;

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool::Worker';

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';
    use_ok($class) or BAIL_OUT;
};

done_testing;
