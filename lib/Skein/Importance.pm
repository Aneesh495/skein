package Skein::Importance;
use 5.020;
use strict;
use warnings;
use Math::BigInt;
use Skein::Rat qw(rat zero one add subr mul divr compare text is_zero);
use Skein::Util qw(integer);

sub new {
    my ($class, $engine) = @_;
    return bless {engine => $engine}, $class;
}

sub profile {
    my ($self, $query) = @_;
    my $engine = $self->{engine};
    my $priors = $engine->model->priors;
    my $baseline = $engine->solve($query)->{probability};
    my $gradient = $engine->sensitivity($query)->{derivatives};
    my @rows;
    for my $name (@{$engine->model->noise_names}) {
        my $low = $engine->solve($query, priors => {%$priors, $name => '0'})->{probability};
        my $high = $engine->solve($query, priors => {%$priors, $name => '1'})->{probability};
        my $row = {variable => $name, prior => $priors->{$name}, derivative => $gradient->{$name},
            risk_at_zero => $low, risk_at_one => $high,
            endpoint_contrast => text(subr($high, $low)),
            removable_risk => text(subr($baseline, $low))};
        $row->{fussell_vesely} = is_zero($baseline) ? undef : text(divr(subr($baseline, $low), $baseline));
        $row->{risk_achievement} = is_zero($baseline) ? undef : text(divr($high, $baseline));
        $row->{risk_reduction} = is_zero($low) ? undef : text(divr($baseline, $low));
        push @rows, $row;
    }
    @rows = sort { compare($b->{removable_risk}, $a->{removable_risk}) || $a->{variable} cmp $b->{variable} } @rows;
    return {baseline => $baseline, variables => \@rows};
}

sub interaction {
    my ($self, $query, $left, $right) = @_;
    die "interaction requires different variables\n" if $left eq $right;
    my $priors = $self->{engine}->model->priors;
    die "unknown interaction variable\n" unless exists($priors->{$left}) && exists($priors->{$right});
    my %corners;
    for my $a (0, 1) {
        for my $b (0, 1) {
            $corners{"$a$b"} = $self->{engine}->solve($query,
                priors => {%$priors, $left => "$a", $right => "$b"})->{probability};
        }
    }
    my $contrast = add(subr(subr($corners{'11'}, $corners{'10'}), $corners{'01'}), $corners{'00'});
    return {left => $left, right => $right, corners => \%corners, contrast => text($contrast)};
}

sub _binomial {
    my ($n, $k) = @_;
    my $result = Math::BigInt->new(1);
    for my $i (1 .. $k) {
        $result->bmul($n - $i + 1);
        $result->bdiv($i);
    }
    return $result;
}

sub shapley {
    my ($self, $query, %options) = @_;
    my $engine = $self->{engine};
    my $names = $options{variables} // $engine->model->noise_names;
    die "Shapley variables must be an array\n" unless ref($names) eq 'ARRAY';
    my $limit = integer($options{max_variables} // 12, 'Shapley variable limit', 0, 18);
    die "Shapley variable limit exceeded\n" if @$names > $limit;
    my $priors = $engine->model->priors;
    my %seen;
    for my $name (@$names) {
        die "invalid Shapley variable '$name'\n" unless exists($priors->{$name}) && !$seen{$name}++;
    }
    my @values;
    for my $mask (0 .. (2 ** @$names) - 1) {
        my %coalition = %$priors;
        for my $i (0 .. $#$names) {
            $coalition{$names->[$i]} = '0' unless ($mask >> $i) & 1;
        }
        $values[$mask] = $engine->solve($query, priors => \%coalition)->{probability};
    }
    my %contributions;
    my $total = zero();
    for my $i (0 .. $#$names) {
        my $value = zero();
        for my $mask (0 .. $#values) {
            next if ($mask >> $i) & 1;
            my $size = 0;
            $size += ($mask >> $_) & 1 for 0 .. $#$names;
            my $denominator = _binomial(@$names - 1, $size)->bmul(scalar @$names)->bstr;
            my $difference = subr($values[$mask | (1 << $i)], $values[$mask]);
            $value = add($value, divr($difference, $denominator));
        }
        $contributions{$names->[$i]} = text($value);
        $total = add($total, $value);
    }
    my $delta = subr($values[-1], $values[0]);
    die "Shapley efficiency invariant failed\n" if compare($total, $delta) != 0;
    return {baseline => $values[0], full => $values[-1], explained_difference => text($delta),
        contributions => \%contributions, coalitions => scalar @values,
        definition => 'Selected noises vary from zero to their nominal priors; unselected priors stay nominal.'};
}

1;
