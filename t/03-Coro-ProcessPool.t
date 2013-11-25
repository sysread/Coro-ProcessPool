use strict;
use warnings;
use List::Util qw(shuffle);
use Coro;
use Test::More;

BEGIN { use AnyEvent::Impl::Perl }

my $class = 'Coro::ProcessPool';

use_ok($class) or BAIL_OUT;

my $proc = new_ok($class, [ max_reqs => 5 ]);
ok($proc->{max_procs} > 0, "max procs set automatically ($proc->{max_procs})");

my $count = 100;
my @threads;
my %result;

foreach my $i (shuffle 1 .. $count) {
    my $thread = async {
        my $n = shift;
        $result{$n} = $proc->process(sub { $_[0] * 2 }, [ $n ]);
    } $i;

    push @threads, $thread;
}

$_->join foreach @threads;

foreach my $i (1 .. $count) {
    is($result{$i}, $i * 2, "gets correct result ($i * 2 = $result{$i})");
}

$proc->shutdown;

done_testing;
