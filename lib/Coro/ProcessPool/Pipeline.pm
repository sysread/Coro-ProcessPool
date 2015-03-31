package Coro::ProcessPool::Pipeline;

=head1 NAME

Coro::ProcessPool::Pipeline

=head1 SYNOPSIS

    my $pool = Coro::ProcesPool->new();
    my $pipe = $pool->pipeline;

    my $producer = async {
        while (my $task = get_next_task()) {
            $pipe->queue('Some::TaskClass', $task);
        }

        $pipe->shutdown;
    };

    while (my $result = $pipe->next) {
        ...
    }

=head1 DESCRIPTION

Provides an iterative mechanism for feeding tasks into the process pool and
collecting results. A pool may have multiple pipelines.

=cut

use Moo;
use Types::Standard qw(-types);
use Coro;
use Coro::AnyEvent;
use Coro::Channel;

=head1 ATTRIBUTES

=head2 pool (required)

The L<Coro::ProcessPool> in which to queue tasks.

=cut

has pool => (
    is       => 'ro',
    isa      => InstanceOf['Coro::ProcessPool'],
    required => 1,
);

=head2 auto_shutdown (default: false)

When set to true, the pipeline will shut itself down as soon as the number of
pending tasks hits zero. At least one task must be sent for this to be
triggered.

=cut

has auto_shutdown => (
    is       => 'rw',
    isa      => Bool,
    default  => 0,
);

has is_shutdown => (
    is       => 'rw',
    isa      => Bool,
    init_arg => undef,
    default  => 0,
);

has num_pending => (
    is       => 'rw',
    isa      => Int,
    init_arg => undef,
    default  => 0,
);

has complete => (
    is       => 'ro',
    isa      => InstanceOf['Coro::Channel'],
    init_arg => undef,
    default  => sub { Coro::Channel->new() },
    handles  => { next => 'get' }
);

=head1 METHODS

=head2 queue($task, $args)

Queues a new task. Arguments are identical to L<Coro::ProcessPool::process> and
L<Coro::ProcessPool::defer>.

=cut

sub queue {
    my ($self, @args) = @_;
    my $deferred = $self->pool->defer(@args);

    async_pool {
        my ($self, $deferred) = @_;
        my $result = $deferred->();

        $self->{complete}->put($result);
        --$self->{num_pending};

        if ($self->{num_pending} == 0) {
            if ($self->{is_shutdown} || $self->{auto_shutdown}) {
                $self->{complete}->shutdown;
            }
        }
    } $self, $deferred;

    ++$self->{num_pending};
}

=head2 shutdown

Signals shutdown of the pipeline. A shutdown pipeline may not be reused.

=cut

sub shutdown {
    my $self = shift;
    $self->{is_shutdown} = 1;
}

1;
