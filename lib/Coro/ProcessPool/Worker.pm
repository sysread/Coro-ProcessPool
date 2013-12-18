package Coro::ProcessPool::Worker;

use strict;
use warnings;

use Coro;
use Coro::AnyEvent;
use Coro::Channel;
use Coro::Handle;
use Coro::ProcessPool::Util qw(encode decode $EOL);
use Guard qw(scope_guard);

if ($^O eq 'MSWin32') {
    die 'MSWin32 is not supported';
}

my $TIMEOUT = 0.2;
my $IN  = unblock *STDIN;
my $OUT = unblock *STDOUT;

sub start {
    my $class   = shift;
    my $outbox  = Coro::Channel->new();
    my $inbox   = Coro::Channel->new();
    my $running = 1;

    my $out_worker = async {
        while (1) {
            my $line = $outbox->get or last;
            $OUT->print($line . $EOL);
        }
    };

    my $in_worker = async {
        while (1) {
            Coro::AnyEvent::readable $IN->fh, $TIMEOUT or next;
            my $line = $IN->readline($EOL) or last;
            $inbox->put($line);
        }

        $running = 0;
    };

    my $proc_worker = async {
        while (1) {
            my $line  = $inbox->get or last;
            my $data  = decode($line);
            my $reply = $class->process_task($data);
            $outbox->put(encode($reply));
        }
    };

    while ($running) {
        Coro::AnyEvent::sleep $TIMEOUT;
    }

    $inbox->shutdown;
    $in_worker->join;

    $outbox->shutdown;
    $out_worker->join;

    exit 0;
}

sub process_task {
    my ($class, $task) = @_;
    my ($f, $args) = @$task;
    my $result = eval { $f->(@$args) };
    return $@ ? [1, $@] : [0, $result];
}

1;
