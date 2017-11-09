use strict;
use warnings;
use Test2::Bundle::Extended;
use Coro::ProcessPool::Util qw(
  encode
  decode
);

bail_out 'OS unsupported' if $^O eq 'MSWin32';

subtest 'encode/decode' => sub{
  my @data = ('ABCD', 42, [qw(thanks for all the fish)]);
  ok my $enc = encode(@data), 'encode';
  ok my @dec = decode $enc, 'decode';
  is @dec, @data, 'encode <-> decode';
};

subtest 'code refs' => sub{
  my @task = ('EFGH', sub{ $_[0] * 2 }, [21]);
  ok my $enc = encode(@task), 'task structure encoded';
  ok my @dec = decode($enc), 'task structure decoded';

  my ($id, $f, $args) = @dec;
  is $id, 'EFGH', 'id is preserved';
  is $f->(@$args), 42, 'CODE and param list preserved';
};

done_testing;
