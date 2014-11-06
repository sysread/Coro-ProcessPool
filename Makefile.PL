use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Coro::ProcessPool',
    AUTHOR              => q{"Jeff Ober" <"jeffober@gmail.com">},
    VERSION_FROM        => 'lib/Coro/ProcessPool.pm',
    ABSTRACT            => '',
        ($ExtUtils::MakeMaker::VERSION >= 6.3002
        ? ('LICENSE'=> 'BSD License')
        : ()),
    PL_FILES            => {},
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Coro-ProcessPool-*' },
    PREREQ_PM => {
        'Const::Fast'      => 0,
        'Coro'             => 0,
        'String::Escape'   => 0,
        'Guard'            => 0,
        'Test::TinyMocker' => 0,
        'Storable'         => '2.05',
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
);
