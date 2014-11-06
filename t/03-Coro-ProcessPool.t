use strict;
use warnings;
use List::Util qw(shuffle);
use Coro;
use Coro::AnyEvent;
use Test::More;
use Guard;
use Test::TinyMocker;
use Coro::Channel;
use Coro::ProcessPool::Util qw(cpu_count);

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool';

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';

    use_ok($class) or BAIL_OUT;

    my $cpus = cpu_count();
    my $pool = new_ok($class, [max_reqs => 5]) or BAIL_OUT 'Failed to create class';
    is($pool->{max_procs}, $cpus, "max procs set automatically to number of cpus ($cpus)");

    my $doubler = sub { $_[0] * 2 };

    subtest 'checkout_proc' => sub {
        my @procs;

        # Checkout with no processes created
        foreach (1 .. $pool->{max_procs}) {
            my $proc = $pool->checkout_proc;
            ok(defined $proc, 'new process spawned and acquired');
            isa_ok($proc, 'Coro::ProcessPool::Process');
            push @procs, $proc;
        }

        $pool->checkin_proc($_) foreach @procs;

        # Checkout with all processes created
        {
            my $proc = $pool->checkout_proc;
            ok(defined $proc, 'previously spawned process acquired');
            isa_ok($proc, 'Coro::ProcessPool::Process');
            $pool->checkin_proc($proc);
        }

        # Checkout with timeouts
        {
            my $proc = $pool->checkout_proc(1);
            ok(defined $proc, 'process acquired with timeout');
            isa_ok($proc, 'Coro::ProcessPool::Process');
            $pool->checkin_proc($proc);
        }

        {
            mock 'Coro::Channel', 'get', sub { Coro::AnyEvent::sleep 3 };
            scope_guard { unmock 'Coro::Channel', 'get' };
            eval { $pool->checkout_proc(1) };
            ok($@, 'error thrown after timeout');
            ok($@ =~ 'timed out', 'expected error');
        }
    };

    subtest 'process' => sub {
        my $count = 20;
        my @threads;
        my %result;

        foreach my $i (shuffle 1 .. $count) {
            my $thread = async {
                my $n = shift;
                $result{$n} = $pool->process($doubler, [ $n ]);
            } $i;

            push @threads, $thread;
        }

        $_->join foreach @threads;

        foreach my $i (1 .. $count) {
            is($result{$i}, $i * 2, 'expected result');
        }
    };

    ok(1, 'test');

    subtest 'defer' => sub {
        my $count = 20;
        my %result;

        foreach my $i (shuffle 1 .. $count) {
            $result{$i} = $pool->defer($doubler, [$i]);
        }

        foreach my $i (1 .. $count) {
            is($result{$i}->(), $i * 2, 'expected result');
        }
    };

    subtest 'map' => sub {
        my @numbers  = 1 .. 100;
        my @expected = map { $_ * 2 } @numbers;
        my @actual   = $pool->map($doubler, @numbers);
        is_deeply(\@actual, \@expected, 'expected result');
    };

    $pool->shutdown;
};

done_testing;
