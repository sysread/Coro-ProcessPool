package Coro::ProcessPool::Worker;

use Moo;
use Types::Standard qw(-types);
use AnyEvent;
use Coro;
use Coro::Handle;
use Coro::ProcessPool::Util qw($EOL decode encode);
use Module::Load qw(load);

has queue => (
    is      => 'ro',
    isa     => InstanceOf['Coro::Channel'],
    default => sub { Coro::Channel->new() },
);

has input => (
    is      => 'ro',
    isa     => InstanceOf['Coro::Handle'],
    default => sub { unblock(*STDIN) },
);

has input_monitor => (
    is  => 'lazy',
    isa => InstanceOf['Coro'],
);

sub _build_input_monitor {
    return async {
        my $self = shift;
        while (my $line = $self->input->readline($EOL)) {
            my $data = decode($line);
            my ($id, $task) = @$data;
            $self->queue->put([$id, $task]);
        }
    } @_;
}

has completed => (
    is      => 'ro',
    isa     => InstanceOf['Coro::Channel'],
    default => sub { Coro::Channel->new() },
);

has output => (
    is      => 'ro',
    isa     => InstanceOf['Coro::Handle'],
    default => sub { unblock(*STDOUT) },
);

has output_monitor => (
    is  => 'lazy',
    isa => InstanceOf['Coro'],
);

sub _build_output_monitor {
    return async {
        my $self = shift;
        while (my $result = $self->completed->get) {
            $self->output->print(encode($result) . $EOL);
        }
    } @_;
}

sub run {
    my $self = shift;

    while (1) {
        my $job = $self->queue->get or last;
        my ($id, $task) = @$job;

        if (!ref($task) && $task eq 'SHUTDOWN') {
            $self->input_monitor->safe_cancel;
            $self->queue->shutdown;

            $self->completed->put([$id, [0, 'OK']]);
            next;
        }

        my $reply = $self->process_task($task);
        $self->completed->put([$id, $reply]);
    }

    $self->completed->shutdown;
    $self->output_monitor->join;
}

before run => sub {
    my $self = shift;
    $self->input_monitor;
    $self->output_monitor;
};

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
