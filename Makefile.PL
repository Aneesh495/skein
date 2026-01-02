use 5.020;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME => 'Skein',
    VERSION_FROM => 'lib/Skein.pm',
    ABSTRACT => 'Exact causal reliability with shared-noise counterfactuals',
    AUTHOR => 'Aneesh495',
    LICENSE => 'mit',
    MIN_PERL_VERSION => '5.020',
    EXE_FILES => ['bin/skein'],
    PREREQ_PM => {
        'JSON::PP' => 0,
        'Math::BigRat' => 0,
        'Digest::SHA' => 0,
        'Test::More' => 0,
    },
);
