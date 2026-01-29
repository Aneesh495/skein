package Skein::Witness;
use 5.020;
use strict;
use warnings;
use Skein::Rat qw(probability zero one mul divr complement compare text is_zero);
use Skein::BDD::Count qw(weighted_count);
use Skein::Util qw(boolean integer);
use Skein::Expr qw(evaluate const render);

sub new {
    my ($class, $engine) = @_;
    return bless {engine => $engine, model => $engine->model}, $class;
}

sub maximum_assignment {
    my ($class, $bdd, $root, $priors) = @_;
    my $variables = $bdd->variables;
    my @p;
    my @default;
    my @prefix = (one());
    die "witness priors must match variables\n" unless ref($priors) eq 'HASH' && keys(%$priors) == @$variables;
    for my $name (@$variables) {
        die "witness prior missing '$name'\n" unless exists $priors->{$name};
        my $p = probability($priors->{$name});
        push @p, $p;
        my $value = compare($p, '1/2') > 0 ? 1 : 0;
        push @default, $value;
        push @prefix, mul($prefix[-1], $value ? $p : complement($p));
    }
    my $gap_mass = sub {
        my ($start, $end) = @_;
        return divr($prefix[$end], $prefix[$start]);
    };
    my %best = (0 => zero(), 1 => one());
    my %choice;
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $low_mass = mul(complement($p[$rank]), mul($gap_mass->($rank + 1, $bdd->node($low)->[0]), $best{$low}));
        my $high_mass = mul($p[$rank], mul($gap_mass->($rank + 1, $bdd->node($high)->[0]), $best{$high}));
        $choice{$id} = compare($high_mass, $low_mass) > 0 ? 1 : 0;
        $best{$id} = $choice{$id} ? $high_mass : $low_mass;
    }
    my $mass = mul($gap_mass->(0, $bdd->node($root)->[0]), $best{$root});
    return undef if is_zero($mass);
    my %assignment = map { $variables->[$_] => $default[$_] } 0 .. $#$variables;
    my $id = $root;
    while ($id >= 2) {
        my ($rank, $low, $high) = @{$bdd->node($id)};
        $assignment{$variables->[$rank]} = $choice{$id};
        $id = $choice{$id} ? $high : $low;
    }
    die "maximum assignment does not satisfy diagram\n" unless $bdd->evaluate($root, \%assignment);
    return {noise => \%assignment, mass => text($mass)};
}

sub nearest_assignment {
    my ($class, $bdd, $root, $reference, $priors, %options) = @_;
    my $variables = $bdd->variables;
    my $costs = $options{costs} // {};
    my @default;
    my @cost;
    my @weights;
    my @prefix = (0);
    for my $name (@$variables) {
        die "nearest witness reference missing '$name'\n" unless exists $reference->{$name};
        my $value = boolean($reference->{$name});
        my $p = probability($priors->{$name});
        my $cost = integer($costs->{$name} // 1, 'noise edit cost', 0, 1_000_000);
        my @allowed = (!is_zero(complement($p)), !is_zero($p));
        push @weights, \@allowed;
        my $default = $allowed[$value] ? $value : 1 - $value;
        push @default, $default;
        push @cost, $cost;
        push @prefix, $prefix[-1] + ($default == $value ? 0 : $cost);
    }
    my %best = (0 => undef, 1 => 0);
    my %choice;
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my @children = ($low, $high);
        my $chosen;
        my $minimum;
        for my $value (0, 1) {
            my $child = $children[$value];
            next unless $weights[$rank][$value] && defined $best{$child};
            my $gap = $prefix[$bdd->node($child)->[0]] - $prefix[$rank + 1];
            my $score = $best{$child} + $gap
                + ($value == $reference->{$variables->[$rank]} ? 0 : $cost[$rank]);
            if (!defined($minimum) || $score < $minimum) {
                $minimum = $score;
                $chosen = $value;
            }
        }
        $best{$id} = $minimum;
        $choice{$id} = $chosen;
    }
    return undef unless defined $best{$root};
    my $distance = $best{$root} + $prefix[$bdd->node($root)->[0]];
    my %assignment = map { $variables->[$_] => $default[$_] } 0 .. $#$variables;
    my $id = $root;
    while ($id >= 2) {
        my ($rank, $low, $high) = @{$bdd->node($id)};
        $assignment{$variables->[$rank]} = $choice{$id};
        $id = $choice{$id} ? $high : $low;
    }
    return {noise => \%assignment, distance => $distance,
        changed => [grep { $assignment{$_} != $reference->{$_} } @$variables]};
}

sub trace {
    my ($self, $noise, $interventions) = @_;
    $interventions //= {};
    my $values = $self->{model}->world($noise, $interventions);
    my @rows;
    for my $name (@{$self->{model}->node_order}) {
        my $expr = $self->{model}->equation($name);
        push @rows, {node => $name, value => $values->{$name},
            equation => render($expr), intervened => exists($interventions->{$name}) ? 1 : 0,
            original_value => evaluate($expr, $values)};
    }
    return {values => $values, equations => \@rows};
}

sub explain {
    my ($self, $query, %options) = @_;
    $query = $self->{model}->query($query) unless ref($query);
    my $roots = $self->{engine}->compiler->query($query);
    my $bdd = $self->{engine}->compiler->bdd;
    my $priors = $options{priors} // $self->{model}->priors;
    my $d = weighted_count($bdd, $roots->{denominator}, $priors);
    die "impossible evidence: probability is zero\n" if is_zero($d);
    my $witness = __PACKAGE__->maximum_assignment($bdd, $roots->{numerator}, $priors);
    return {status => 'impossible_event'} unless $witness;
    return {status => 'witness', %$witness, posterior_mass => text(divr($witness->{mass}, $d)),
        factual => $self->trace($witness->{noise}, {}),
        target => $self->trace($witness->{noise}, $query->{interventions} // {})};
}

1;
