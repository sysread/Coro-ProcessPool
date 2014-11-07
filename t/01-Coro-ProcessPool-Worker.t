use strict;
use warnings;
use Test::More;

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool::Worker';

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';
    use_ok($class) or BAIL_OUT;

    my $doubler = sub { my ($x) = @_; return $x * 2; };
    my $success = $class->process_task([$doubler, [21]]);
    is_deeply($success, [0, 42], 'expected result');

    my $croaker = sub { die "TEST MESSAGE" };
    my $failure = $class->process_task([$croaker, []]);
    is($failure->[0], 1, 'error generates correct code');
    like($failure->[1], qr/TEST MESSAGE/, 'stack trace includes error message');
};

done_testing;
