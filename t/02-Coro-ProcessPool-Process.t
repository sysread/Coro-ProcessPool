use strict;
use warnings;
use Test::More;
use Coro;
use List::Util qw(shuffle);

BEGIN { use AnyEvent::Impl::Perl }

BAIL_OUT 'MSWin32 is not supported' if $^O eq 'MSWin32';

my $timeout = 3;
my $class = 'Coro::ProcessPool::Process';

sub test_sub {
    my ($x) = @_;
    return $x * 2;
}

use_ok($class) or BAIL_OUT;
my @range = (1 .. 20);

note 'shutdown';
{
    my $proc = new_ok($class);
    ok(my $pid = $proc->pid, 'spawned correctly');

    ok(my $id = $proc->send(\&test_sub, [21]), 'final send');
    ok($proc->shutdown($timeout), 'shutdown with pending task');
    ok(my $reply = $proc->recv($id), 'reply received after termination');
    is($reply, 42, 'received expected result');
};

note 'in order';
{
    my $proc = new_ok($class);
    ok(my $pid = $proc->pid, 'spawned correctly');

    my $count = 0;
    foreach my $i (@range) {
        ok(my $id = $proc->send(\&test_sub, [$i]), "send ($i)");
        ok(my $reply = $proc->recv($id), "recv ($i)");
        is($reply, $i * 2, "receives expected result ($i)");
        is($proc->messages_sent, ++$count, "message count tracking ($i)");
    }

    $proc->shutdown($timeout);
};

note 'out of order';
{
    my $proc = new_ok($class);
    ok(my $pid = $proc->pid, 'spawned correctly');

    my %pending;
    foreach my $i (shuffle @range) {
        ok(my $id = $proc->send(\&test_sub, [$i]), "ooo send ($i)");
        $pending{$i} = $id;
    }

    foreach my $i (shuffle keys %pending) {
        my $id = $pending{$i};
        ok(my $reply = $proc->recv($id), "ooo recv ($i)");
        is($reply, $i * 2, "ooo receives expected result ($i)");
    }

    $proc->shutdown($timeout);
};

done_testing;
