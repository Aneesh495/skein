use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Engine;
use Skein::Oracle;
use Skein::Witness;
use Skein::Expr qw(var);

my $model = Skein::Model->from_text('noise u ~ 1/3; noise v ~ 1/5; noise skip ~ 3/4; node x = u | v; query q = P(x);');
my $engine = Skein::Engine->new($model);
my $witness = Skein::Witness->new($engine)->explain('q');
my $reference = Skein::Oracle->new($model)->maximum_world($model->query('q'));
is_deeply($witness->{noise}, $reference->{noise}, 'MAP witness agrees with complete enumeration');
is($witness->{mass}, $reference->{mass}, 'MAP exact joint mass');
is($witness->{posterior_mass}, $reference->{posterior_mass}, 'MAP posterior mass');
is($witness->{target}{values}{x}, 1, 'witness executes structural model');
my $root = $engine->compiler->expression(var('x'));
my $nearest = Skein::Witness->nearest_assignment($engine->compiler->bdd, $root,
    {u => 0, v => 0, skip => 0}, $model->priors, costs => {u => 3, v => 1});
is($nearest->{distance}, 1, 'weighted nearest realization');
is_deeply($nearest->{changed}, ['v'], 'nearest flip identified');
my $repaired = Skein::Witness->new($engine)->explain({event => var('x'), factual => var('x'), interventions => {x => 0}});
is($repaired->{status}, 'impossible_event', 'no fabricated counterfactual witness');
my $trace = Skein::Witness->new($engine)->trace({u => 1, v => 0, skip => 0}, {x => 0});
is($trace->{equations}[0]{original_value}, 1, 'replaced equation value visible');
is($trace->{equations}[0]{value}, 0, 'intervention value visible');
done_testing;
