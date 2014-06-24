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
    my $inbox   = Coro::Channel->new();
    my $outbox  = Coro::Channel->new();
    my $running = 1;

    my $in_worker = async {
        while (1) {
            Coro::AnyEvent::readable $IN->fh, $TIMEOUT or next;
            my $line = $IN->readline($EOL) or last;
            $inbox->put($line);
        }

        $running = 0;
    };

    my $out_worker = async {
        while (1) {
            my $line = $outbox->get or last;
            $OUT->print($line . $EOL);
        }
    };

    my $proc_worker = async {
        while (1) {
            my $line = $inbox->get or last;
            my $data = decode($line);
            my ($id, $task) = @$data;
            my $reply = $class->process_task($task);
            $outbox->put(encode([$id, $reply]));
        }
    };

    scope_guard {
        $inbox->shutdown;
        $in_worker->join;

        $outbox->shutdown;
        $out_worker->join;
    };

    while ($running) {
        Coro::AnyEvent::sleep $TIMEOUT;
    }
}

sub process_task {
    my ($class, $task) = @_;
    my ($f, $args) = @$task;
    my $result = eval { $f->(@$args) };
    return $@ ? [1, $@] : [0, $result];
}

1;
