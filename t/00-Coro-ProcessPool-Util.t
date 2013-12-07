use strict;
use warnings;
use Test::More;

my $class = 'Coro::ProcessPool::Util';

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';

    use Coro::ProcessPool;
    use_ok($class) or BAIL_OUT;

    my $data = [42, qw(thanks for all the fish)];
    my $enc  = $class->can('encode')->($data);
    is_deeply($class->can('decode')->($enc), $data, 'encode <-> decode');
};

done_testing;
