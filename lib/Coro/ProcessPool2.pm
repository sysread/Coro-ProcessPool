package Coro::ProcessPool2;

use strict;
use warnings;
use Coro;
use AnyEvent;
use Coro::Countdown;
use Coro::ProcessPool::Process qw(worker);

sub new{
  my ($class, %param) = @_;

  my $self = bless{
    max_procs => $param{max_procs},
    max_reqs  => $param{max_reqs},
    include   => $param{include},
    queue     => Coro::Channel->new,
  }, $class;

  $self->{worker} = async{
    my $self = shift;
    my $pool = Coro::Channel->new;

    for (1 .. $self->{max_procs}) {
      $pool->put($self->_spawn);
    }

    while (my $task = $self->{queue}->get) {
      my ($caller, $f, @args) = @$task;

      WORKER:
      my $ps = $pool->get;

      if ($self->{max_reqs} && $ps->{counter} >= $self->{max_reqs}) {
        async_pool{ my $ps = shift; $ps->stop; $ps->join; } $ps;
        $pool->put($self->_spawn);
        goto WORKER;
      }

      $ps->await;
      my $cv = $ps->send($f, \@args);

      async_pool{
        my ($k, $cv) = @_;
        my $ret = eval{ $cv->recv };
        $@ ? $k->croak($@) : $k->send($ret);
      } $caller, $cv;

      $pool->put($ps);
    }

    $pool->shutdown;

    while (my $ps = $pool->get) {
      $ps->stop;
      $ps->join;
    }
  } $self;

  return $self;
}

sub _spawn{
  my $self = shift;
  worker(include => $self->{include});
}

sub shutdown{
  my $self = shift;
  $self->{queue}->shutdown;
}

sub join{
  my $self = shift;
  $self->{worker}->join;
}

sub defer{
  my $self = shift;
  my $cv = AE::cv;
  $self->{queue}->put([$cv, @_]);
  return $cv;
}

1;
