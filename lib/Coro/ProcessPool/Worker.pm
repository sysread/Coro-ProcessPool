package Coro::ProcessPool::Worker;

use Moo;
use Types::Standard qw(-types);
use AnyEvent;
use Carp;
use Coro;
use Coro::Handle;
use Coro::ProcessPool::Util qw($EOL decode encode);
use Module::Load qw(load);
use Devel::StackTrace;

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

        eval {
            while (my $line = $self->input->readline($EOL)) {
                my ($id, $task, $args) = decode($line);
                $self->queue->put([$id, $task, $args]);
            }
        };

        return if $@ && $@ =~ /shutting down/;
        $self->shutdown;
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

        eval {
            while (my $data = $self->completed->get) {
                $self->output->print(encode(@$data) . $EOL);
            }
        };
    } @_;
}

sub run {
    my $self = shift;

    $SIG{KILL} = sub { exit };
    $SIG{TERM} = sub { exit };
    $SIG{HUP}  = sub { exit };

    while (1) {
        my $job = $self->queue->get or last;
        my ($id, $task, $args) = @$job;

        if (!ref($task) && $task eq 'SHUTDOWN') {
            $self->completed->put([$id, 0, ['OK']]);
            $self->shutdown;
            next;
        }

        my ($error, $result) = $self->process_task($task, $args);
        $self->completed->put([$id, $error, $result]);
    }

    $self->completed->shutdown;
    $self->output_monitor->join;
}

before run => sub {
    my $self = shift;
    $self->input_monitor;
    $self->output_monitor;
};

sub shutdown {
    my $self = shift;
    $self->queue->shutdown;
    $self->input_monitor->throw('shutting down');;
}

sub process_task {
    my ($class, $task, $args) = @_;

    my $result = eval {
        if (ref $task && ref $task eq 'CODE') {
            $task->(@$args);
        } else {
            load $task;
            die "method new() not found for class $task" unless $task->can('new');
            die "method run() not found for class $task" unless $task->can('run');
            my $obj = $task->new(@$args);
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
        return (1, $trace->as_string);
    }

    return (0, $result);
}

1;
