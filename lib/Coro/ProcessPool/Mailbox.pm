package Coro::ProcessPool::Mailbox;

use strict;
use warnings;
use Carp;

use Coro;
use Coro::Handle qw(unblock);
use Coro::Semaphore;
use Coro::ProcessPool::Util qw(encode decode $EOL);

use fields qw(
    counter
    in
    out
    inbox
    inbox_mon
    inbox_running
    read_sem
);

sub new {
    my ($class, $fh_in, $fh_out) = @_;
    my $self = fields::new($class);

    $self->{counter}  = 0;
    $self->{in}       = unblock $fh_in;
    $self->{out}      = unblock $fh_out;
    $self->{inbox}    = {};
    $self->{read_sem} = Coro::Semaphore->new(0);

    $self->{inbox_running} = 1;
    $self->{inbox_mon} = async {
        while (1) {
            $self->{in}->readable or last;

            # If anyone is waiting on this inbox to have data, wake them up and
            # cede control to them. This is used in Coro::ProcessPool::process
            # to put the worker back into the queue as soon as the result is
            # ready, rather than waiting until the result is completely read.
            my $waiting = $self->{read_sem}->waiters;
            if ($waiting > 0) {
              $self->{read_sem}->adjust($waiting);
              cede;
            }

            my $line = $self->{in}->readline($EOL) or last;
            my $msg = decode($line);
            my ($id, $data) = @$msg;
            $self->{inbox}{$id}->put($data);
        }

        $self->{inbox_running} = 0;
    };

    return $self;
}

sub DESTROY {
    my $self = shift;
    $self->{in}->close if $self->{in};
    $self->{out}->close if $self->{out};
    $self->{inbox_mon}->safe_cancel
        if $self->{inbox_running}
        && $self->{inbox_mon};
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
    $self->{read_sem}->down;
    #$self->{in}->readable;
}

1;
