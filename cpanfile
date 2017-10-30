requires 'perl', '5.010';

requires 'AnyEvent'             => 0;
requires 'Const::Fast'          => 0;
requires 'Coro'                 => '6.514';
requires 'Data::Dump::Streamer' => 0;
requires 'Data::UUID'           => 0;
requires 'Devel::StackTrace'    => 0;
requires 'Guard'                => 0;
requires 'Module::Load'         => 0;
requires 'Moo'                  => 0;
requires 'Sereal'               => 0;
requires 'String::Escape'       => 0;
requires 'Types::Standard'      => '1.0';


on test => sub {
  requires 'Devel::Cover'            => 0;
  requires 'List::Util'              => 0;
  requires 'Sub::Override'           => 0;
  requires 'Test2::Bundle::Extended' => 0;
  requires 'Test::More'              => 0;
  requires 'Test::Pod'               => 1.41;

};
