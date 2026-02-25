package Skein::Causal;
use 5.020;
use strict;
use warnings;
use Skein::Expr qw(var const op);
use Skein::BDD::Count qw(weighted_count);
use Skein::Rat qw(zero one add subr divr text is_zero compare);
use Skein::Util qw(identifier deep_copy);

sub new {
    my ($class, $engine) = @_;
    return bless {engine => $engine}, $class;
}

sub _conditional {
    my ($self, $outcome, $interventions, $factual) = @_;
    my $result = eval { $self->{engine}->counterfactual($outcome, $interventions, $factual) };
    return {status => 'defined', %$result} unless $@;
    die $@ unless $@ =~ /impossible evidence/;
    return {status => 'undefined', reason => 'The conditioning population has zero probability.'};
}

sub response {
    my ($self, $cause, $outcome, %options) = @_;
    my $engine = $self->{engine};
    my $model = $engine->model;
    identifier($cause, 'causal treatment');
    $model->validate_interventions({$cause => 0});
    $model->validate_expression($outcome);
    my $factual = $options{factual} // const(1);
    $model->validate_expression($factual);
    my $compiler = $engine->compiler;
    my $bdd = $compiler->bdd;
    my $zero = $compiler->expression($outcome, {$cause => 0});
    my $one = $compiler->expression($outcome, {$cause => 1});
    my $evidence = $compiler->expression($factual, {});
    my $denominator = weighted_count($bdd, $evidence, $model->priors);
    die "impossible evidence: probability is zero\n" if is_zero($denominator);
    my @strata;
    my $sum = zero();
    my @names = qw(always_absent helped harmed always_present);
    for my $y0 (0,1) {
        for my $y1 (0,1) {
            my $a = $y0 ? $zero : $bdd->negate($zero);
            my $b = $y1 ? $one : $bdd->negate($one);
            my $root = $bdd->apply('and', $a, $b);
            my $joint = $bdd->apply('and', $root, $evidence);
            my $mass = weighted_count($bdd, $joint, $model->priors);
            my $p = divr($mass, $denominator);
            $sum = add($sum, $p);
            push @strata, {name => $names[2*$y0+$y1], outcome_if_zero => $y0,
                outcome_if_one => $y1, probability => text($p), joint_mass => text($mass),
                structurally_possible => $joint != 0 ? 1 : 0};
        }
    }
    die "response strata do not normalize\n" unless compare($sum, one()) == 0;
    my $p0 = add($strata[2]{probability}, $strata[3]{probability});
    my $p1 = add($strata[1]{probability}, $strata[3]{probability});
    my $effect = subr($p1,$p0);
    my $necessity_population = op('and',$factual,op('and',var($cause),$outcome));
    my $sufficiency_population = op('and',$factual,
        op('and',op('not',var($cause)),op('not',$outcome)));
    return {schema => 'skein.response/1', model_digest => $model->digest,
        treatment => $cause, outcome => deep_copy($outcome), factual => deep_copy($factual),
        evidence_probability => text($denominator), strata => \@strata,
        risk_if_zero => text($p0), risk_if_one => text($p1), average_effect => text($effect),
        probability_of_necessity_and_sufficiency => $strata[1]{probability},
        monotone_increasing => $strata[2]{structurally_possible} ? 0 : 1,
        monotone_decreasing => $strata[1]{structurally_possible} ? 0 : 1,
        probability_of_necessity => $self->_conditional(op('not',$outcome),
            {$cause => 0}, $necessity_population),
        probability_of_sufficiency => $self->_conditional($outcome,
            {$cause => 1}, $sufficiency_population)};
}

sub verify_response {
    my ($self, $response, %options) = @_;
    require Skein::Oracle;
    my $engine = $self->{engine};
    die "response model mismatch\n" unless $response->{model_digest} eq $engine->model->digest;
    my $oracle = Skein::Oracle->new($engine->model, %options);
    my $sum = zero();
    for my $row (@{$response->{strata}}) {
        my @events;
        for my $value (0,1) {
            my $event = $response->{outcome};
            $event = op('not',$event) unless $row->{$value ? 'outcome_if_one' : 'outcome_if_zero'};
            push @events, {event => $event, interventions => {$response->{treatment} => $value}};
        }
        my $result = $oracle->joint_worlds(\@events,$response->{factual});
        die "response stratum mismatch\n" unless compare($result->{probability},$row->{probability}) == 0;
        $sum = add($sum,$result->{probability});
    }
    die "response verification does not normalize\n" unless compare($sum,one()) == 0;
    return {verified => 1, worlds => 2 ** @{$engine->model->noise_names},
        method => 'independent paired source worlds'};
}

1;
