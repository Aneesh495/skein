use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Engine;
use Skein::Oracle;
use Skein::Expr qw(var const op);

my $model = Skein::Model->from_text(<<'MODEL');
noise u ~ 1/3;
noise v ~ 1/5;
noise w ~ 1/7;
node a = u ^ v;
node b = ite(a, w, v);
query q = P(b) factual(a) do(a=0);
query zero = P(0);
MODEL
my $engine = Skein::Engine->new($model);
my $oracle = Skein::Oracle->new($model);
for my $name (@{$model->query_names}) {
    my $actual = $engine->solve($name);
    my $expected = $oracle->solve($name);
    is($actual->{$_}, $expected->{$_}, "$name independent $_") for qw(probability numerator denominator);
}
my $ledger = $oracle->solve('q', ledger => 1);
is(scalar @{$ledger->{ledger}}, 8, 'all noise worlds visited');
is($ledger->{total_mass}, '1', 'exact oracle normalization');
my $empty = Skein::Model->from_text('node certain = 1; query q = P(certain);');
is(Skein::Oracle->new($empty)->solve('q')->{probability}, '1', 'zero-noise world');
my $deterministic = Skein::Model->from_text('noise u ~ 0; node x = u; query q = P(x);');
is(Skein::Oracle->new($deterministic)->solve('q')->{probability}, '0', 'zero prior');
my $small = Skein::Oracle->new($model, max_worlds => 4);
ok(!eval { $small->solve('q'); 1 }, 'world bound');
my $best = $oracle->maximum_world({event => var('a')});
is_deeply($best->{noise}, {u => 1, v => 0, w => 0}, 'independent maximum world');
my $events = [{event => var('b'), interventions => {}}, {event => op('not', var('b')), interventions => {b => 0}}];
is_deeply($engine->joint_worlds($events, var('a')), $oracle->joint_worlds($events, var('a')), 'cross-world independent oracle');
done_testing;
