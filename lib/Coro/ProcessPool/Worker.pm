package Coro::ProcessPool::Worker;

use strict;
use warnings;

use Coro;
use Coro::AnyEvent;
use Coro::Channel;
use Coro::Handle;
use Coro::ProcessPool::Util qw(encode decode $EOL);
use Devel::StackTrace;
use Guard qw(scope_guard);
use Module::Load qw(load);

if ($^O eq 'MSWin32') {
    die 'MSWin32 is not supported';
}

my $RUNNING = 1;
my $TIMEOUT = 0.2;
my $IN      = unblock *STDIN;
my $OUT     = unblock *STDOUT;
my $OUTBOX  = Coro::Channel->new();
my $INBOX   = Coro::Channel->new();
my ($IN_WORKER, $OUT_WORKER, $PROC_WORKER);

$SIG{KILL} = sub { stop() };

sub stop {
    $RUNNING = 0;

    if ($IN_WORKER) {
        $IN_WORKER->safe_cancel;
        $INBOX->shutdown;
    }

    if ($PROC_WORKER) {
        $PROC_WORKER->join;
        $OUTBOX->shutdown;
    }

    if ($OUT_WORKER) {
        $OUT_WORKER->join;
    }

    exit 0;
}

sub start {
    my $class = shift;

    $IN_WORKER = async {
        while ($RUNNING) {
            my $line = $IN->readline($EOL);

            if ($line) {
                $INBOX->put($line);
            }
            # Connection to parent broken; shut down inbox and wait for the
            # remaining workers to complete.
            else {
                $RUNNING = 0;
                $INBOX->shutdown;

                if ($PROC_WORKER) {
                    $PROC_WORKER->join;
                    $OUTBOX->shutdown;
                }

                if ($OUT_WORKER) {
                    $OUT_WORKER->join;
                }

                last;
            }
        }
    };

    $OUT_WORKER = async {
        while (1) {
            my $line = $OUTBOX->get or last;
            $OUT->print($line . $EOL);
        }
    };

    $PROC_WORKER = async {
        while (1) {
            my $line = $INBOX->get or last;
            my $data = decode($line);
            my ($id, $task) = @$data;
            my $reply = $class->process_task($task);
            $OUTBOX->put(encode([$id, $reply]));
        }
    };

    scope_guard { stop };

    while ($RUNNING) {
        Coro::AnyEvent::sleep $TIMEOUT;
    }
}

sub process_task {
    my ($class, $task) = @_;
    my ($f, $args) = @$task;

    if (!ref($f) && $f eq 'SHUTDOWN') {
      stop();
      return;
    }

    my $result = eval {
        if (ref $f && ref $f eq 'CODE') {
            $f->(@$args);
        } else {
            load $f;
            die "method new() not found for class $f" unless $f->can('new');
            die "method run() not found for class $f" unless $f->can('run');
            my $obj = $f->new(@$args);
            $obj->run;
        }
    };

    if ($@) {
        my $error = $@;
        my $trace = Devel::StackTrace->new(
            message      => $error,
            indent       => 1,
            ignore_class => [$class, 'Coro', 'AnyEvent'],
        );
        return [1, $trace->as_string];
    }

    return [0, $result];
}

1;
