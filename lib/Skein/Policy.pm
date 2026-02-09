package Skein::Policy;
use 5.020;
use strict;
use warnings;
use Skein::Planner;
use Skein::Oracle;
use Skein::Expr qw(const op evaluate render);
use Skein::Rat qw(rat probability zero add mul divr compare complement text is_zero);
use Skein::Util qw(integer deep_copy canonical_json);

sub new {
    my ($class, $engine, %options) = @_;
    return bless {
        engine => $engine,
        max_sensors => integer($options{max_sensors} // 6, 'policy sensor limit', 0, 10),
        max_states => integer($options{max_states} // 10_000, 'policy state limit', 1, 1_000_000),
    }, $class;
}

sub _input {
    my ($self, $input) = @_;
    my $model = $self->{engine}->model;
    $input = $model->query($input) unless ref($input);
    my $query = deep_copy($input);
    $model->validate_query($query);
    die "policy query requires an unmodified factual starting world\n" if keys %{$query->{interventions}};
    die "policy query evidence must use factual(...), not given(...)\n"
        if exists($query->{evidence}) && canonical_json($query->{evidence}) ne canonical_json(const(1));
    return $query;
}

sub synthesize {
    my ($self, $input, %options) = @_;
    my $query = $self->_input($input);
    my $model = $self->{engine}->model;
    my $sensors = $model->sensors;
    die "policy sensor limit exceeded\n" if @$sensors > $self->{max_sensors};
    my $budget = integer($options{budget} // 10, 'policy budget', 0, 1_000_000);
    my $loss = rat($options{failure_loss} // 100);
    die "failure loss must be positive\n" if compare($loss, 0) <= 0;
    my $planner = Skein::Planner->new($self->{engine});
    my %memo;
    my %stats = (states => 0, memo_hits => 0, sensor_branches => 0, repair_frontiers => 0);
    my $search;
    $search = sub {
        my ($context, $remaining, $available, $readings) = @_;
        my $key = canonical_json([$readings, $remaining, [map { $_->{name} } @$available]]);
        if (exists $memo{$key}) {
            ++$stats{memo_hits};
            return $memo{$key};
        }
        die "policy search state limit exceeded\n" if ++$stats{states} > $self->{max_states};
        my $conditional = {event => $query->{event}, factual => $context, interventions => {}};
        my $frontier = $planner->plan($conditional, budget => $remaining)->{frontier};
        ++$stats{repair_frontiers};
        my $best;
        for my $candidate (@$frontier) {
            my $objective = add(mul($loss, $candidate->{probability}), $candidate->{cost});
            next if $best && compare($objective, $best->{expected_loss}) >= 0;
            $best = {kind => 'repair', actions => [@{$candidate->{actions}}],
                interventions => {%{$candidate->{interventions}}},
                expected_loss => text($objective), expected_risk => $candidate->{probability},
                expected_cost => "$candidate->{cost}", repair_cost => $candidate->{cost},
                context => render($context), readings => {%$readings}};
        }
        die "policy has no stopping decision\n" unless $best;
        for my $sensor (@$available) {
            next if $sensor->{cost} > $remaining;
            my $reading_query = {event => $sensor->{expr}, factual => $context, interventions => {}};
            my $p = $self->{engine}->solve($reading_query)->{probability};
            # A deterministic reading provides no information and costs no useful branch.
            next if is_zero($p) || compare($p, 1) == 0;
            my @next_available = grep { $_->{name} ne $sensor->{name} } @$available;
            my %branches;
            my $expected_loss = rat($sensor->{cost});
            my $expected_cost = rat($sensor->{cost});
            my $expected_risk = zero();
            for my $value (0, 1) {
                my $literal = $value ? $sensor->{expr} : op('not', $sensor->{expr});
                my $next_context = op('and', $context, $literal);
                my $weight = $value ? rat($p) : complement($p);
                my $child = $search->($next_context, $remaining - $sensor->{cost}, \@next_available,
                    {%$readings, $sensor->{name} => $value});
                $branches{$value} = {probability => text($weight), policy => $child};
                $expected_loss = add($expected_loss, mul($weight, $child->{expected_loss}));
                $expected_cost = add($expected_cost, mul($weight, $child->{expected_cost}));
                $expected_risk = add($expected_risk, mul($weight, $child->{expected_risk}));
                ++$stats{sensor_branches};
            }
            if (compare($expected_loss, $best->{expected_loss}) < 0) {
                $best = {kind => 'sensor', sensor => $sensor->{name}, sensor_cost => $sensor->{cost},
                    branches => \%branches, expected_loss => text($expected_loss),
                    expected_cost => text($expected_cost), expected_risk => text($expected_risk),
                    context => render($context), readings => {%$readings}};
            }
        }
        $memo{$key} = $best;
        return $best;
    };
    my $tree = $search->($query->{factual} // const(1), $budget, $sensors, {});
    return {schema => 'skein.policy/1', model_digest => $model->digest, query => $query,
        budget => $budget, failure_loss => text($loss), tree => $tree, stats => \%stats,
        objective => 'Minimum expected observation cost plus repair cost plus failure loss.',
        observation_semantics => 'Sensors observe the factual world before any repair.'};
}

sub verify {
    my ($self, $policy) = @_;
    die "policy model identity mismatch\n" unless $policy->{model_digest} eq $self->{engine}->model->digest;
    my $query = $self->_input($policy->{query});
    my $model = $self->{engine}->model;
    my %sensors = map { $_->{name} => $_ } @{$model->sensors};
    my %repairs = map { $_->{name} => $_ } @{$model->repairs};
    my ($denominator, $risk, $cost) = (zero(), zero(), zero());
    my $oracle = Skein::Oracle->new($model);
    my $worlds = $oracle->each_assignment(sub {
        my ($noise, $mass) = @_;
        my $factual = $model->world($noise, {});
        return unless evaluate($query->{factual} // const(1), $factual);
        $denominator = add($denominator, $mass);
        my $node = $policy->{tree};
        my %seen;
        my $spent = 0;
        while ($node->{kind} eq 'sensor') {
            my $name = $node->{sensor};
            die "policy sensor unknown or repeated\n" unless exists($sensors{$name}) && !$seen{$name}++;
            my $sensor = $sensors{$name};
            die "policy sensor cost mismatch\n" unless $node->{sensor_cost} == $sensor->{cost};
            $spent += $sensor->{cost};
            my $value = evaluate($sensor->{expr}, $factual);
            die "policy branch missing\n" unless ref($node->{branches}{$value}{policy}) eq 'HASH';
            $node = $node->{branches}{$value}{policy};
        }
        die "policy leaf must be a repair decision\n" unless $node->{kind} eq 'repair';
        my %interventions;
        my %used;
        my $repair_cost = 0;
        for my $name (@{$node->{actions}}) {
            die "policy repair unknown or repeated\n" unless exists($repairs{$name}) && !$used{$name}++;
            my $repair = $repairs{$name};
            die "policy conflicting repairs\n" if exists($interventions{$repair->{node}})
                && $interventions{$repair->{node}} != $repair->{value};
            $interventions{$repair->{node}} = $repair->{value};
            $repair_cost += $repair->{cost};
        }
        die "policy repair interventions mismatch\n"
            unless canonical_json(\%interventions) eq canonical_json($node->{interventions});
        die "policy repair cost mismatch\n" unless $node->{repair_cost} == $repair_cost;
        $spent += $repair_cost;
        die "policy exceeds per-realization budget\n" if $spent > $policy->{budget};
        my $target = $model->world($noise, \%interventions);
        $risk = add($risk, $mass) if evaluate($query->{event}, $target);
        $cost = add($cost, mul($mass, $spent));
    });
    die "impossible policy context\n" if is_zero($denominator);
    my $actual_risk = divr($risk, $denominator);
    my $actual_cost = divr($cost, $denominator);
    my $actual_loss = add(mul($policy->{failure_loss}, $actual_risk), $actual_cost);
    die "policy expected risk mismatch\n" if compare($actual_risk, $policy->{tree}{expected_risk}) != 0;
    die "policy expected cost mismatch\n" if compare($actual_cost, $policy->{tree}{expected_cost}) != 0;
    die "policy expected loss mismatch\n" if compare($actual_loss, $policy->{tree}{expected_loss}) != 0;
    return {verified => 1, worlds => $worlds, expected_risk => text($actual_risk),
        expected_cost => text($actual_cost), expected_loss => text($actual_loss)};
}

1;
