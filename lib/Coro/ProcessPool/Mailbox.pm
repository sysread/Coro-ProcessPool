package Coro::ProcessPool::Mailbox;

use strict;
use warnings;
use Carp;

use Coro;
use Coro::Handle qw(unblock);
use Coro::ProcessPool::Util qw(encode decode $EOL);

use fields qw(
    counter
    in
    out
    inbox
    inbox_mon
    outbox_mon
);

sub new {
    my ($class, $fh_in, $fh_out) = @_;
    my $self = fields::new($class);

    $self->{counter} = 0;
    $self->{in}      = unblock $fh_in;
    $self->{out}     = unblock $fh_out;
    $self->{inbox}   = {};

    $self->{inbox_mon} = async {
        while (my $line = $self->{in}->readline($EOL)) {
            last unless $line;
            my $msg = decode($line);
            my ($id, $data) = @$msg;
            $self->{inbox}{$id}->put($data);
        }
    };

    return $self;
}

sub DESTROY {
    my $self = shift;
    $self->{inbox_mon}->safe_cancel if $self->{inbox_mon};
    $self->{in}->close if $self->{in};
    $self->{out}->close if $self->{out};
}

sub send {
    my ($self, $data) = @_;
    my $id = ++$self->{counter};
    $self->{inbox}{$id} = Coro::Channel->new;
    $self->{out}->print(encode([$id, $data]). $EOL);
    return $id;
}

sub recv {
    my ($self, $id) = @_;
    my $data = $self->{inbox}{$id}->get;
    delete $self->{inbox}{$id};
    return $data;
}

sub readable {
    my $self = shift;
    $self->{in}->readable;
}

1;
