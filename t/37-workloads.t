use strict;
use warnings;
use Test::More;
use Skein::Workload;
use Skein::Engine;
use Skein::Oracle;

for my $kind (qw(series parallel parity threshold)) {
    for my $size (1,2,5) {
        my $case = Skein::Workload->independent($kind,$size,p => '2/7');
        is(Skein::Engine->new($case->{model})->solve('baseline')->{probability},$case->{expected},"$kind $size closed form");
        is(Skein::Oracle->new($case->{model})->solve('baseline')->{probability},$case->{expected},"$kind $size source reference");
    }
}
for my $case (Skein::Workload->shared_domains(2,2),Skein::Workload->multiplexer(2),
    Skein::Workload->multiplexer(2,data_first => 1)) {
    is(Skein::Engine->new($case->{model})->solve('baseline')->{probability},$case->{expected},"$case->{name} closed form");
    is(Skein::Oracle->new($case->{model})->solve('baseline')->{probability},$case->{expected},"$case->{name} independently executed");
}
done_testing;
