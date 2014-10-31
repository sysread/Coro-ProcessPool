package Coro::ProcessPool::Util;

use strict;
use warnings;
use Carp;
use Const::Fast;
use Coro::Storable qw(freeze thaw);
use MIME::Base64   qw(encode_base64 decode_base64);

use base qw(Exporter);
our @EXPORT_OK = qw(encode decode $EOL);

const our $EOL => "\n";

sub encode {
    local $Storable::Deparse = 1;
    my $ref  = shift or croak 'encode: expected reference';
    my $data = freeze($ref);
    return encode_base64($data, '');
}

sub decode {
    local $Storable::Eval = 1;
    my $line = shift or croak 'decode: expected line';
    my $data = decode_base64($line) or croak 'invalid data';
    return thaw($data);
}

1;
