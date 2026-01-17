package Skein::BDD::Count;
use 5.020;
use strict;
use warnings;
use Exporter 'import';
use Skein::Rat qw(probability rat zero one add subr mul divr complement text is_zero);

our @EXPORT_OK = qw(weighted_count masses gradient conditional_gradient posterior);

sub _priors {
    my ($bdd, $input) = @_;
    die "priors must be an object\n" unless ref($input) eq 'HASH';
    my $variables = $bdd->variables;
    my @priors;
    for my $name (@$variables) {
        die "missing prior '$name'\n" unless exists $input->{$name};
        push @priors, probability($input->{$name});
    }
    die "unknown prior variable\n" unless keys(%$input) == @$variables;
    return \@priors;
}

sub masses {
    my ($bdd, $root, $priors) = @_;
    my $weights = _priors($bdd, $priors);
    my %mass = (0 => zero(), 1 => one());
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $p = $weights->[$rank];
        $mass{$id} = add(mul(complement($p), $mass{$low}), mul($p, $mass{$high}));
    }
    return \%mass;
}

sub weighted_count {
    my ($bdd, $root, $priors) = @_;
    return masses($bdd, $root, $priors)->{$root}->copy;
}

sub gradient {
    my ($bdd, $root, $priors) = @_;
    my $weights = _priors($bdd, $priors);
    my $mass = masses($bdd, $root, $priors);
    my $reachable = $bdd->reachable($root);
    my $variables = $bdd->variables;
    my %derivative = map { $_ => zero() } @$variables;
    my %adjoint = ($root => one());
    for my $id (reverse @$reachable) {
        next if $id < 2;
        my $a = $adjoint{$id} // zero();
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $p = $weights->[$rank];
        my $contribution = mul($a, subr($mass->{$high}, $mass->{$low}));
        my $name = $variables->[$rank];
        $derivative{$name} = add($derivative{$name}, $contribution);
        $adjoint{$low} = add($adjoint{$low} // zero(), mul($a, complement($p)));
        $adjoint{$high} = add($adjoint{$high} // zero(), mul($a, $p));
    }
    return { mass => $mass->{$root}->copy, derivatives => \%derivative };
}

sub conditional_gradient {
    my ($bdd, $numerator_root, $denominator_root, $priors) = @_;
    my $numerator = gradient($bdd, $numerator_root, $priors);
    my $denominator = gradient($bdd, $denominator_root, $priors);
    my $n = $numerator->{mass};
    my $d = $denominator->{mass};
    die "impossible evidence: probability is zero\n" if is_zero($d);
    my %derivatives;
    for my $name (@{$bdd->variables}) {
        $derivatives{$name} = divr(
            subr(mul($numerator->{derivatives}{$name}, $d),
                mul($n, $denominator->{derivatives}{$name})), mul($d, $d));
    }
    return { probability => divr($n, $d), numerator => $n, denominator => $d,
        derivatives => \%derivatives };
}

sub posterior {
    my ($bdd, $evidence, $priors) = @_;
    my $denominator = weighted_count($bdd, $evidence, $priors);
    die "impossible evidence: probability is zero\n" if is_zero($denominator);
    my %result;
    for my $name (@{$bdd->variables}) {
        my $joint = $bdd->apply('and', $evidence, $bdd->variable($name));
        $result{$name} = divr(weighted_count($bdd, $joint, $priors), $denominator);
    }
    return \%result;
}

1;
