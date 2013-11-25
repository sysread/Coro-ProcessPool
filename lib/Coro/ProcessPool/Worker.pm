package Coro::ProcessPool::Worker;

use strict;
use warnings;

use Coro;
use Coro::Channel;
use Coro::Handle;
use Coro::ProcessPool::Util qw(encode decode $EOL);

if ($^O eq 'MSWin32') {
    die 'MSWin32 is not supported';
}

my $IN     = unblock *STDIN;
my $OUT    = unblock *STDOUT;
my $outbox = Coro::Channel->new();
my $outbox_mon;

sub start_outbox_mon {
    $outbox_mon = async {
        while (1) {
            my $line = $outbox->get or last;
            $OUT->print($line . $EOL);
        }
    };
}

sub start {
    my $class = shift;

    $class->start_outbox_mon;

    while (1) {
        my $line  = $IN->readline($EOL) or last;
        my $data  = decode($line);
        my $reply = $class->process_task($data);
        $outbox->put(encode($reply));
    }

    $outbox->shutdown;
    $outbox_mon->join;

    exit 0;
}

sub process_task {
    my ($class, $task) = @_;
    my ($f, $args) = @$task;
    my $result = eval { $f->(@$args) };
    return $@ ? [1, $@] : [0, $result];
}

1;
