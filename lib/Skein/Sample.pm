package Skein::Sample;
use 5.020;
use strict;
use warnings;
use Skein::RNG;
use Skein::BDD::Count qw(masses);
use Skein::Rat qw(probability mul divr is_zero text);
use Skein::Util qw(integer);

sub new {
    my ($class, $engine, %options) = @_;
    return bless {engine => $engine, rng => Skein::RNG->new($options{seed} // 1)}, $class;
}

sub _prepared {
    my ($self, $query) = @_;
    my $model = $self->{engine}->model;
    $query = $model->query($query) unless ref($query);
    my $roots = $self->{engine}->compiler->query($query);
    my $bdd = $self->{engine}->compiler->bdd;
    my $priors = $model->priors;
    my $mass = masses($bdd, $roots->{denominator}, $priors);
    die "impossible evidence: probability is zero\n" if is_zero($mass->{$roots->{denominator}});
    return {query => $query, roots => $roots, bdd => $bdd, priors => $priors, masses => $mass};
}

sub _draw {
    my ($self, $prepared) = @_;
    my $bdd = $prepared->{bdd};
    my $variables = $bdd->variables;
    my $priors = $prepared->{priors};
    my %assignment;
    my $root = $prepared->{roots}{denominator};
    while ($root >= 2) {
        my ($rank, $low, $high) = @{$bdd->node($root)};
        my $name = $variables->[$rank];
        my $high_mass = mul($priors->{$name}, $prepared->{masses}{$high});
        my $conditional = divr($high_mass, $prepared->{masses}{$root});
        my $value = $self->{rng}->bernoulli($conditional);
        $assignment{$name} = $value;
        $root = $value ? $high : $low;
    }
    die "posterior sampler reached false terminal\n" unless $root == 1;
    for my $name (@$variables) {
        $assignment{$name} = $self->{rng}->bernoulli($priors->{$name}) unless exists $assignment{$name};
    }
    die "posterior sample violates evidence\n"
        unless $bdd->evaluate($prepared->{roots}{denominator}, \%assignment);
    return \%assignment;
}

sub draws {
    my ($self, $query, $count, %options) = @_;
    integer($count, 'sample count', 1, 1_000_000);
    my $prepared = $self->_prepared($query);
    my @samples;
    for my $index (0 .. $count - 1) {
        my $noise = $self->_draw($prepared);
        if ($options{callback}) {
            $options{callback}->($noise, $index);
        } else {
            push @samples, $noise;
        }
    }
    return $options{callback} ? $count : \@samples;
}

sub estimate {
    my ($self, $query, $count) = @_;
    integer($count, 'sample count', 1, 1_000_000);
    my $prepared = $self->_prepared($query);
    my $successes = 0;
    my %noise_counts = map { $_ => 0 } @{$prepared->{bdd}->variables};
    for (1 .. $count) {
        my $noise = $self->_draw($prepared);
        ++$successes if $prepared->{bdd}->evaluate($prepared->{roots}{event}, $noise);
        $noise_counts{$_} += $noise->{$_} for keys %noise_counts;
    }
    my $estimate = $successes / $count;
    my $z = 1.95996398454005;
    my $denominator = 1 + $z * $z / $count;
    my $center = ($estimate + $z * $z / (2 * $count)) / $denominator;
    my $radius = $z * sqrt($estimate * (1 - $estimate) / $count + $z * $z / (4 * $count * $count)) / $denominator;
    return {samples => $count, successes => $successes, estimate => $estimate,
        interval_95 => [$center - $radius, $center + $radius],
        interval_method => 'Approximate Wilson interval from independent exact posterior draws.',
        exact_probability => $self->{engine}->solve($query)->{probability},
        noise_counts => \%noise_counts, random_draws => $self->{rng}->draws};
}

1;
