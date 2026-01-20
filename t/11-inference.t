use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Engine;
use Skein::Parser;
use Skein::Expr qw(var);
use Skein::Rat qw(sum text);

my $model = Skein::Model->from_text(<<'MODEL');
model confounding;
noise shared ~ 1/2;
noise independent ~ 1/4;
node alarm = shared;
node outage = shared | independent;
query baseline = P(outage);
query observed = P(outage) given(!alarm);
query intervention = P(outage) do(alarm=0);
query counterfactual = P(outage) do(outage=0) factual(outage);
MODEL
my $engine = Skein::Engine->new($model);
is($engine->solve('baseline')->{probability}, '5/8', 'unconditional reliability');
is($engine->solve('observed')->{probability}, '1/4', 'observing alarm updates shared cause');
is($engine->solve('intervention')->{probability}, '5/8', 'forcing alarm does not remove shared cause');
is($engine->solve('counterfactual')->{probability}, '0', 'equation replacement in factual context');
like($engine->solve('baseline')->{model_digest}, qr/^[0-9a-f]{64}$/, 'result binds model');
my $expr = Skein::Parser->parse_expression('outage & !alarm');
is($engine->observational($expr)->{probability}, '1/8', 'compound event');
my $distribution = $engine->distribution([qw(alarm outage)]);
is(text(sum(map { $_->{probability} } @$distribution)), '1', 'joint distribution normalizes');
my $sensitivity = $engine->sensitivity('baseline');
is($sensitivity->{derivatives}{shared}, '3/4', 'sensitivity shared');
is($sensitivity->{derivatives}{independent}, '1/2', 'sensitivity independent');
my $posterior = $engine->noise_posterior({event => var('outage'), evidence => var('outage')});
is($posterior->{shared}, '4/5', 'posterior shared');
ok(!eval { $engine->observational(var('outage'), Skein::Parser->parse_expression('alarm & !alarm')); 1 }, 'contradictory evidence fails');
my $joint = $engine->joint_worlds([
    {event => var('outage'), interventions => {}},
    {event => Skein::Parser->parse_expression('!outage'), interventions => {outage => 0}},
]);
is($joint->{probability}, '5/8', 'cross-world conjunction uses shared noise');
done_testing;
