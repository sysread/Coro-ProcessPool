use strict;
use warnings;
use Test::More;
use Coro::ProcessPool;

my $class = 'Coro::ProcessPool::Util';

use_ok($class) or BAIL_OUT;

my $data = [42, qw(thanks for all the fish)];
my $enc  = $class->can('encode')->($data);
is_deeply($class->can('decode')->($enc), $data, 'encode <-> decode');

done_testing;