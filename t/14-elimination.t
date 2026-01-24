use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Engine;
use Skein::Oracle;
use Skein::Eliminate;

my @sources = (
    'noise u ~ 1/3; noise v ~ 1/5; node a = u ^ v; node b = !a; query q = P(b) given(u | v);',
    'noise u ~ 1/2; noise v ~ 1/4; node a = u; node b = a | v; query q = P(b) do(a=0) factual(b);',
    'noise u ~ 0; noise v ~ 1; node a = u <-> v; query q = P(!a);',
    'noise u ~ 1/3; node a = exactly(1,u,u); query q = P(a);',
    'noise u ~ 1/3; noise v ~ 1/5; noise w ~ 1/7; node a = atleast(2,u,v,w); query q = P(a);',
    'node a = 1; query q = P(a);',
);
for my $source (@sources) {
    my $model = Skein::Model->from_text($source);
    my $bdd = Skein::Engine->new($model)->solve('q');
    my $oracle = Skein::Oracle->new($model)->solve('q');
    my $factor = Skein::Eliminate->new($model)->solve('q');
    is($factor->{$_}, $bdd->{$_}, "factor vs BDD $_") for qw(probability numerator denominator);
    is($factor->{probability}, $oracle->{probability}, 'factor vs enumeration');
    ok(@{$factor->{denominator_trace}} > 0, 'elimination made actual progress');
}
my $impossible = Skein::Model->from_text('noise u ~ 1/3; query q = P(u) given(u & !u);');
ok(!eval { Skein::Eliminate->new($impossible)->solve('q'); 1 }, 'zero evidence rejected');
my $bounded = Skein::Model->from_text('noise u ~ 1/3; noise v ~ 1/5; node a = u ^ v; query q = P(a);');
ok(!eval { Skein::Eliminate->new($bounded, max_rows => 1)->solve('q'); 1 }, 'row bound fails');
done_testing;
