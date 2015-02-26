use strict;
use warnings;
use Test::More;
use Coro;

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool::Process';

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';

    sub test_sub {
      my ($x) = @_;
      return $x * 2;
    }

    use_ok($class) or BAIL_OUT;

    my $proc = new_ok($class);

    ok(my $pid = $proc->spawn, 'spawn');

    foreach my $i (1 .. 10) {
        ok(my $id = $proc->send(\&test_sub, [$i]), "send ($i)");
        ok(my $reply = $proc->recv($id), "recv ($i)");
        is($reply, $i * 2, "receives expected result ($i)");
    }

    ok($proc->terminate, 'terminate');
};

done_testing;
