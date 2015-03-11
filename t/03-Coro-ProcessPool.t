use strict;
use warnings;
use List::Util qw(shuffle);
use AnyEvent;
use Coro;
use Coro::AnyEvent;
use Test::More;
use Guard;
use Test::TinyMocker;
use Coro::Channel;
use Coro::ProcessPool::Util qw(cpu_count);

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool';

my $doubler = sub {
    my $x = shift;
    return $x * 2;
};

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';

    use_ok($class) or BAIL_OUT;

    note 'start & stop';
    {
        my $cpus = cpu_count();
        my $pool = new_ok($class) or BAIL_OUT 'Failed to create class';
        is($pool->{max_procs}, $cpus, "max procs set automatically to number of cpus ($cpus)");
        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    note 'checkout_proc';
    {
        my $pool  = new_ok($class, [max_procs => 1])
            or BAIL_OUT 'Failed to create class';

        # Checkout before process started
        my $proc = $pool->checkout_proc;

        ok(defined $proc, 'new process spawned and acquired');
        isa_ok($proc, 'Coro::ProcessPool::Process');
        ok(defined $proc->pid, 'new process has a pid');

        is($pool->num_procs, 1, 'process count correct');
        is($pool->capacity, 0, 'capacity correct');

        $pool->checkin_proc($proc);
        is($pool->capacity, 1, 'capacity correct');
        is($pool->num_procs, 1, 'correct process count');

        # Checkout after process started
        $proc = $pool->checkout_proc;
        is($pool->capacity, 0, 'correct capacity');
        is($pool->num_procs, 1, 'correct process count');

        ok(defined $proc, 'previously spawned process acquired');
        isa_ok($proc, 'Coro::ProcessPool::Process');

        $pool->checkin_proc($proc);
        is($pool->capacity, 1, 'correct pool capacity after all procs checked in');

        # Shutdown
        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');

        eval { $pool->checkout_proc };
        like($@, qr/not running/, 'checkout after shutdown throws error');
    };

    note 'max reqs';
    {
        my $pool = new_ok($class, [max_procs => 1, max_reqs => 1]) or BAIL_OUT 'Failed to create class';

        # Check out proc, grab the pid, fudge messages sent, and check it back in. Then checkout the
        # next proc and ensure it's not the same one.
        {
            my $pid;
            {
                my $proc = $pool->checkout_proc;
                $pid = $proc->pid;
                ++$proc->{messages_sent};
                $pool->checkin_proc($proc);
            }

            # Check out new proc and verify it has a new pid
            my $proc = $pool->checkout_proc;
            ok($pid != $proc->pid, 'max_reqs correctly spawns new processes');
            $pool->checkin_proc($proc);
        }

        # Verify that it doesn't happen when messages_sent isn't fudged.
        {
            my $pid;
            {
                my $proc = $pool->checkout_proc;
                $pid = $proc->pid;
                $pool->checkin_proc($proc);
            }

            # Check out new proc and verify it has a new pid
            my $proc = $pool->checkout_proc;
            is($pid, $proc->pid, 'max_reqs does not respawn when unnecessary');
            $pool->checkin_proc($proc);
        }

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    note 'process';
    {
        my $pool = new_ok($class, [max_procs => 1]) or BAIL_OUT 'Failed to create class';

        my $count = 20;
        my %result;

        foreach my $i (1 .. $count) {
            my $result = $pool->process($doubler, [ $i ]);
            is($result, $i * 2, 'expected result');
        }

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    note 'defer';
    {
        my $pool = new_ok($class, [max_procs => 1]) or BAIL_OUT 'Failed to create class';

        my $count = 20;
        my %result;

        foreach my $i (shuffle 1 .. $count) {
            $result{$i} = $pool->defer($doubler, [$i]);
        }

        foreach my $i (1 .. $count) {
            is($result{$i}->(), $i * 2, 'expected result');
        }

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    note 'map';
    {
        my $pool = new_ok($class, [max_procs => 1]) or BAIL_OUT 'Failed to create class';

        my @numbers  = 1 .. 100;
        my @expected = map { $_ * 2 } @numbers;
        my @actual   = $pool->map($doubler, @numbers);
        is_deeply(\@actual, \@expected, 'expected result');

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    note 'task errors';
    {
        my $pool = new_ok($class, [max_procs => 1]) or BAIL_OUT 'Failed to create class';

        my $croaker = sub {
            my ($x) = @_;
            return $x / 0;
        };

        my $result = eval { $pool->process($croaker, [1]) };
        my $error  = $@;

        ok($error, 'processing failure croaks');

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    note 'queue';
    {
        my $pool = new_ok($class, [max_procs => 1]) or BAIL_OUT 'Failed to create class';

        my $count = 100;
        my $done  = AnyEvent->condvar;
        my %result;

        my $make_k = sub {
            my $n = shift;
            return sub {
                $result{$n} = shift;
                if (scalar(keys %result) == $count) {
                    $done->send;
                }
            };
        };

        foreach my $i (shuffle 1 .. $count) {
            my $k = $make_k->($i);
            $pool->queue($doubler, [$i], $k);
        }

        $done->recv;

        foreach my $i (1 .. $count) {
            is($result{$i}, $i * 2, 'expected result');
        }

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };
};

done_testing;
