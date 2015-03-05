use strict;
use warnings;
use Test::More;
use Coro;
use List::Util qw(shuffle);

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool::Process';

sub test_sub {
    my ($x) = @_;
    return $x * 2;
}

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';

    use_ok($class) or BAIL_OUT;
    my @range = (1 .. 20);

    subtest 'shutdown' => sub {
        my $proc = new_ok($class);
        ok(my $pid = $proc->pid, 'spawned correctly');

        ok(my $id = $proc->send(\&test_sub, [21]), 'final send');
        ok($proc->shutdown, 'shutdown with pending task');
        ok(my $reply = $proc->recv($id), 'reply received after termination');
        is($reply, 42, 'received expected result');
    };

    subtest 'in order' => sub {
        my $proc = new_ok($class);
        ok(my $pid = $proc->pid, 'spawned correctly');

        foreach my $i (@range) {
            ok(my $id = $proc->send(\&test_sub, [$i]), "send ($i)");
            ok(my $reply = $proc->recv($id), "recv ($i)");
            is($reply, $i * 2, "receives expected result ($i)");
            is($proc->messages_sent, $i, "message count tracking ($i)");
        }

        $proc->shutdown;
    };

    subtest 'out of order' => sub {
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

        $proc->shutdown;
    };
};

done_testing;
