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

    subtest 'start & stop' => sub {
        my $cpus = cpu_count();
        my $pool = new_ok($class) or BAIL_OUT 'Failed to create class';
        is($pool->{max_procs}, $cpus, "max procs set automatically to number of cpus ($cpus)");
        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    subtest 'checkout_proc' => sub {
        my $count = 2;
        my $pool  = new_ok($class, [max_procs => $count])
            or BAIL_OUT 'Failed to create class';

        my @procs;

        foreach my $i (1 .. $pool->max_procs) {
            my $proc = $pool->checkout_proc;

            ok(defined $proc, 'new process spawned and acquired');
            isa_ok($proc, 'Coro::ProcessPool::Process');

            is($pool->num_procs, $i, 'process count correct');
            is($pool->capacity, 0, 'capacity correct');

            push @procs, $proc;
        }

        my $proc = eval { $pool->checkout_proc(1) };
        ok(!defined $proc, 'no process returned after checkout timeout');
        ok($@, 'error thrown after checkout timeout');

        my $i = 0;
        foreach my $proc (@procs) {
            $pool->checkin_proc($proc);
            is($pool->capacity, ++$i, 'capacity correct');
        }

        is($pool->capacity, $count, 'correct pool capacity after all procs checked in');

        {
            is($pool->capacity, $count, 'correct capacity');
            is($pool->num_procs, $count, 'correct process count');

            my $proc = $pool->checkout_proc;

            is($pool->capacity, $count - 1, 'correct capacity');
            is($pool->num_procs, $count, 'correct process count');

            ok(defined $proc, 'previously spawned process acquired');
            isa_ok($proc, 'Coro::ProcessPool::Process');

            $pool->checkin_proc($proc);
        }

        is($pool->capacity, $count, 'correct pool capacity after all procs checked in');

        {
            my $proc = $pool->checkout_proc(1);
            ok(defined $proc, 'process acquired with timeout');
            isa_ok($proc, 'Coro::ProcessPool::Process');
            $pool->checkin_proc($proc);
        }

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');

        eval { $pool->checkout_proc };
        like($@, qr/not running/, 'checkout after shutdown throws error');
    };

    subtest 'max reqs' => sub {
        my $pool = new_ok($class, [max_procs => 1, max_reqs => 1]) or BAIL_OUT 'Failed to create class';

        # Check out proc, grab the pid, fudge messages sent, and check it back in
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

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    subtest 'send task' => sub {
        my $pool = new_ok($class, [max_procs => 1]) or BAIL_OUT 'Failed to create class';

        ok(my $msgid = $pool->start_task($doubler, [21]), 'start_task');
        ok(my $result = $pool->collect_task($msgid), 'collect_task');
        is($result, 42, 'correct result');

        my @range = 1 .. $pool->{num_procs};
        my %pending;
        foreach my $i (@range) {
            ok(my $msgid = $pool->start_task($doubler, [$i]), 'start_task');
            $pending{$i} = $msgid;
        }

        foreach my $i (shuffle(keys %pending)) {
            my $msgid = $pending{$i};
            ok(my $result = $pool->collect_task($msgid), 'collect_task');
            is($result, $i * 2, 'correct result');
        }

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    subtest 'process' => sub {
        my $pool = new_ok($class, [max_procs => 2]) or BAIL_OUT 'Failed to create class';

        my $count = 20;
        my %result;

        foreach my $i (1 .. $count) {
            my $result = $pool->process($doubler, [ $i ]);
            is($result, $i * 2, 'expected result');
        }

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    subtest 'defer' => sub {
        my $pool = new_ok($class, [max_procs => 2]) or BAIL_OUT 'Failed to create class';

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

    subtest 'map' => sub {
        my $pool = new_ok($class, [max_procs => 2]) or BAIL_OUT 'Failed to create class';

        my @numbers  = 1 .. 100;
        my @expected = map { $_ * 2 } @numbers;
        my @actual   = $pool->map($doubler, @numbers);
        is_deeply(\@actual, \@expected, 'expected result');

        $pool->shutdown;
        is($pool->{num_procs}, 0, 'no processes after shutdown') or BAIL_OUT('say not to zombies');
    };

    subtest 'fail' => sub {
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

    subtest 'queue' => sub {
        my $pool = new_ok($class, [max_procs => 2]) or BAIL_OUT 'Failed to create class';

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
