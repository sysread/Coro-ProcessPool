use strict;
use warnings;
use Test::More;
use Coro;

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool::Process';

use_ok($class) or BAIL_OUT;

my $proc = new_ok($class);

ok($proc->spawn, 'spawn');

foreach my $i (1 .. 10) {
    ok($proc->send(sub { $_[0] * 2 }, [$i]), "send ($i)");
    ok(my $reply = $proc->recv, "recv ($i)");
    is($reply, $i * 2, "receives expected result ($i)");
}

ok($proc->terminate, 'terminate');

done_testing;
