package Coro::ProcessPool::Inbox;

use Moo;
use Types::Standard qw(-types);
use Coro;
use Coro::AnyEvent;
use Coro::Channel;

has pool => (
    is       => 'ro',
    isa      => InstanceOf['Coro::ProcessPool'],
    required => 1,
);

has auto_shutdown => (
    is       => 'rw',
    isa      => Bool,
    default  => 0,
);

has is_shutdown => (
    is       => 'rw',
    isa      => Bool,
    default  => 0,
    init_arg => undef,
);

has pending => (
    is       => 'rw',
    isa      => Int,
    default  => 0,
    init_arg => undef,
);

has complete => (
    is       => 'ro',
    isa      => InstanceOf['Coro::Channel'],
    init_arg => undef,
    default  => sub { Coro::Channel->new },
    handles  => [qw(next)],
);

sub queue {
    my $self = shift;

    async_pool {
        my $self   = shift;
        my $result = $self->pool->process(@_);

        $self->complete->put($result);

        --$self->{pending};

        if ($self->is_shutdown && $self->auto_shutdown && !$self->{pending}) {
            $self->complete->shutdown;
        }
    } $self, @_;

    ++$self->{pending};

    return;
}

sub shutdown {
    my $self = shift;
    $self->is_shutdown(1);
}

1;
