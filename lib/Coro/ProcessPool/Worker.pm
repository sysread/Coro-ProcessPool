package Coro::ProcessPool::Worker;

use Moo;
use Types::Standard qw(-types);
use Coro::ProcessPool::Util qw($EOL decode encode);
use Module::Load qw(load);

sub run {
    my $self = shift;

    $| = 1;

    while (my $line = <STDIN>) {
        my $data = decode($line);
        my ($id, $task) = @$data;

        if ($task eq 'SHUTDOWN') {
            print(encode([$id, [0, 'OK']]) . $EOL);
            last;
        }

        my $reply = $self->process_task($task);
        print(encode([$id, $reply]) . $EOL);
    }

    exit 0;
}

sub process_task {
    my ($class, $task) = @_;
    my ($f, $args) = @$task;

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
            ignore_class => ['Coro::ProcessPool::Util', 'Coro', 'AnyEvent'],
        );
        return [1, $trace->as_string];
    }

    return [0, $result];
}

1;
