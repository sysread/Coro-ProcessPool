package Coro::ProcessPool::Util;

use strict;
use warnings;
use Carp;
use Const::Fast;
use Storable;
use Coro::Storable qw(nfreeze thaw);
use MIME::Base64   qw(encode_base64 decode_base64);

use base qw(Exporter);
our @EXPORT_OK = qw(cpu_count encode decode $EOL);

const our $EOL => "\n";

sub encode {
    no warnings 'once';
    local $Storable::Deparse = 1;
    my $ref  = shift or croak 'encode: expected reference';
    my $data = nfreeze($ref);
    return encode_base64($data, '');
}

sub decode {
    no warnings 'once';
    local $Storable::Eval = 1;
    my $line = shift or croak 'decode: expected line';
    my $data = decode_base64($line) or croak 'invalid data';
    return thaw($data);
}

#-------------------------------------------------------------------------------
# "Borrowed" from Test::Smoke::Util::get_ncpus.
#
# Modifications:
#   * Use $^O in place of an input argument
#   * Return number instead of string
#-------------------------------------------------------------------------------
sub cpu_count {
    # Only *nixy osses need this, so use ':'
    local $ENV{PATH} = "$ENV{PATH}:/usr/sbin:/sbin";

    my $cpus = "?";
    OS_CHECK: {
        local $_ = $^O;

        /aix/i && do {
            my @output = `lsdev -C -c processor -S Available`;
            $cpus = scalar @output;
            last OS_CHECK;
        };

        /(?:darwin|.*bsd)/i && do {
            chomp( my @output = `sysctl -n hw.ncpu` );
            $cpus = $output[0];
            last OS_CHECK;
        };

        /hp-?ux/i && do {
            my @output = grep /^processor/ => `ioscan -fnkC processor`;
            $cpus = scalar @output;
            last OS_CHECK;
        };

        /irix/i && do {
            my @output = grep /\s+processors?$/i => `hinv -c processor`;
            $cpus = (split " ", $output[0])[0];
            last OS_CHECK;
        };

        /linux/i && do {
            my @output; local *PROC;
            if ( open PROC, "< /proc/cpuinfo" ) {
                @output = grep /^processor/ => <PROC>;
                close PROC;
            }
            $cpus = @output ? scalar @output : '';
            last OS_CHECK;
        };

        /solaris|sunos|osf/i && do {
            my @output = grep /on-line/ => `psrinfo`;
            $cpus =  scalar @output;
            last OS_CHECK;
        };

        /mswin32|cygwin/i && do {
            $cpus = exists $ENV{NUMBER_OF_PROCESSORS}
                ? $ENV{NUMBER_OF_PROCESSORS} : '';
            last OS_CHECK;
        };

        /vms/i && do {
            my @output = grep /CPU \d+ is in RUN state/ => `show cpu/active`;
            $cpus = @output ? scalar @output : '';
            last OS_CHECK;
        };

        $cpus = "";
        require Carp;
        Carp::carp( "get_ncpu: unknown operationg system" );
    }

    return sprintf '%d', ($cpus || 1);
}

1;
