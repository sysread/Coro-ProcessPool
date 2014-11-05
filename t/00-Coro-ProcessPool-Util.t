use strict;
use warnings;
use Test::More;

my $class = 'Coro::ProcessPool::Util';

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';

    use_ok($class) or BAIL_OUT;

    # Encode/decode compatibility
    {
        my $data = [42, qw(thanks for all the fish)];
        my $enc  = $class->can('encode')->($data);
        is_deeply($class->can('decode')->($enc), $data, 'encode <-> decode');
    }

    # Compatibility with CODE refs and task structure
    {
        my $task = [sub { $_[0] * 2 }, [21]];
        my $enc = $class->can('encode')->($task);
        ok($enc, 'task structure encoded');

        my $dec = $class->can('decode')->($enc);
        ok($dec, 'task structure decoded');

        is(ref $dec, 'ARRAY', 'data structure preserved');
        my ($f, $args) = @$dec;
        my ($n) = @$args;
        is($f->($n), 42, 'CODE and param list preserved');
    }
};

done_testing;
