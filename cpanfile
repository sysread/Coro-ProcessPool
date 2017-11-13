requires 'perl', '5.010';

requires 'AnyEvent'              => '7.14';
requires 'AnyEvent::ProcessPool' => '0.04';
requires 'Coro'                  => '6.514';
requires 'Coro::Countdown'       => '0.02';

on test => sub {
  requires 'Devel::Cover'            => '0';
  requires 'List::Util'              => '0';
  requires 'Test2'                   => '0';
  requires 'Test2::Bundle::Extended' => '0';
  requires 'Test::More'              => '0';
  requires 'Test::Pod'               => '0';
};
