requires 'perl', '5.010';

requires 'AnyEvent'             => '7.14';
requires 'Const::Fast'          => '0.014';
requires 'Coro'                 => '6.514';
requires 'Data::Dump::Streamer' => '2.40';
requires 'Data::UUID'           => '1.221';
requires 'Devel::StackTrace'    => '2.02';
requires 'Guard'                => '1.023';
requires 'Module::Load'         => '0.32';
requires 'Moo'                  => '2.003002';
requires 'Sereal'               => '3.015';
requires 'String::Escape'       => '2010.002';
requires 'Types::Standard'      => '1.002001';

on test => sub {
  requires 'EV' => 0;
  requires 'Devel::Cover'            => '1.29';
  requires 'List::Util'              => '1.49';
  requires 'Sub::Override'           => '0.09';
  requires 'Test2'                   => '1.302106';
  requires 'Test2::Bundle::Extended' => '0.000083';
  requires 'Test::More'              => '1.302106';
  requires 'Test::Pod'               => '1.51';
};
