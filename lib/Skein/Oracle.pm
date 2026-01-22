package Skein::Oracle;
use 5.020;
use strict;
use warnings;
use Skein::Expr qw(evaluate const);
use Skein::Rat qw(probability zero one add divr mul text is_zero compare);
use Skein::Util qw(integer deep_copy canonical_json);

sub new {
    my ($class, $model, %options) = @_;
    return bless {
        model => $model,
        max_variables => integer($options{max_variables} // 16, 'oracle variable limit', 0, 24),
        max_worlds => integer($options{max_worlds} // 65_536, 'oracle world limit', 1, 16_777_216),
    }, $class;
}

sub _check {
    my ($self, $priors) = @_;
    my $names = $self->{model}->noise_names;
    die "oracle variable limit exceeded\n" if @$names > $self->{max_variables};
    my $count = 2 ** @$names;
    die "oracle world limit exceeded\n" if $count > $self->{max_worlds};
    die "oracle priors must be an object\n" unless ref($priors) eq 'HASH';
    die "oracle priors do not match noise variables\n" if keys(%$priors) != @$names;
    for my $name (@$names) {
        die "oracle prior missing '$name'\n" unless exists $priors->{$name};
        probability($priors->{$name});
    }
    return ($names, $count);
}

sub each_assignment {
    my ($self, $callback, %options) = @_;
    my $priors = $options{priors} // $self->{model}->priors;
    my ($names, $count) = $self->_check($priors);
    for my $mask (0 .. $count - 1) {
        my %noise;
        for my $index (0 .. $#$names) {
            $noise{$names->[$index]} = ($mask >> $index) & 1;
        }
        my $mass = $self->{model}->assignment_mass(\%noise, $priors);
        $callback->(\%noise, $mass, $mask);
    }
    return $count;
}

sub solve {
    my ($self, $input, %options) = @_;
    $input = $self->{model}->query($input) unless ref($input);
    my $query = deep_copy($input);
    $self->{model}->validate_query($query);
    my $numerator = zero();
    my $denominator = zero();
    my $total = zero();
    my @ledger;
    my $count = $self->each_assignment(sub {
        my ($noise, $mass, $mask) = @_;
        my $factual = $self->{model}->world($noise, {});
        my $target = $self->{model}->world($noise, $query->{interventions});
        my $evidence = evaluate($query->{factual} // const(1), $factual)
            && evaluate($query->{evidence} // const(1), $target) ? 1 : 0;
        my $event = evaluate($query->{event}, $target);
        $total = add($total, $mass);
        $denominator = add($denominator, $mass) if $evidence;
        $numerator = add($numerator, $mass) if $evidence && $event;
        if ($options{ledger}) {
            push @ledger, { index => $mask, noise => {%$noise}, mass => text($mass),
                evidence => $evidence, event => $event };
        }
    }, priors => $options{priors} // $self->{model}->priors);
    die "oracle world mass does not normalize\n" if compare($total, one()) != 0;
    die "impossible evidence: probability is zero\n" if is_zero($denominator);
    my $result = {
        probability => text(divr($numerator, $denominator)),
        numerator => text($numerator), denominator => text($denominator),
        worlds => $count, total_mass => text($total),
    };
    $result->{ledger} = \@ledger if $options{ledger};
    return $result;
}

sub joint_worlds {
    my ($self, $events, $factual_expr, %options) = @_;
    my $numerator = zero();
    my $denominator = zero();
    for my $item (@$events) {
        $self->{model}->validate_expression($item->{event});
        $self->{model}->validate_interventions($item->{interventions} // {});
    }
    $self->{model}->validate_expression($factual_expr // const(1));
    $self->each_assignment(sub {
        my ($noise, $mass) = @_;
        my $factual = $self->{model}->world($noise, {});
        return unless evaluate($factual_expr // const(1), $factual);
        $denominator = add($denominator, $mass);
        my $holds = 1;
        for my $item (@$events) {
            my $world = $self->{model}->world($noise, $item->{interventions} // {});
            $holds = 0 unless evaluate($item->{event}, $world);
        }
        $numerator = add($numerator, $mass) if $holds;
    }, priors => $options{priors} // $self->{model}->priors);
    die "impossible evidence: probability is zero\n" if is_zero($denominator);
    return {probability => text(divr($numerator, $denominator)),
        numerator => text($numerator), denominator => text($denominator)};
}

sub maximum_world {
    my ($self, $query, %options) = @_;
    my $result = $self->solve($query, %options, ledger => 1);
    my $best;
    for my $row (@{$result->{ledger}}) {
        next unless $row->{evidence} && $row->{event};
        if (!$best || compare($row->{mass}, $best->{mass}) > 0
            || (compare($row->{mass}, $best->{mass}) == 0
                && canonical_json($row->{noise}) lt canonical_json($best->{noise}))) {
            $best = $row;
        }
    }
    return undef unless $best && !is_zero($best->{mass});
    return {noise => {%{$best->{noise}}}, mass => $best->{mass},
        posterior_mass => text(divr($best->{mass}, $result->{denominator}))};
}

1;
