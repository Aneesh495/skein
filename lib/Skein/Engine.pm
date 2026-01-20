package Skein::Engine;
use 5.020;
use strict;
use warnings;
use Skein::Compiler;
use Skein::Expr qw(var const op);
use Skein::BDD::Count qw(weighted_count conditional_gradient posterior);
use Skein::Rat qw(text decimal divr is_zero);
use Skein::Util qw(deep_copy integer);

sub new {
    my ($class, $model, %options) = @_;
    return bless { model => $model, compiler => Skein::Compiler->new($model, %options) }, $class;
}

sub model { return $_[0]{model} }
sub compiler { return $_[0]{compiler} }

sub solve {
    my ($self, $query, %options) = @_;
    $query = $self->{model}->query($query) unless ref($query);
    my $compiled = $self->{compiler}->query($query);
    my $bdd = $self->{compiler}->bdd;
    my $priors = $options{priors} // $self->{model}->priors;
    my $denominator = weighted_count($bdd, $compiled->{denominator}, $priors);
    die "impossible evidence: probability is zero\n" if is_zero($denominator);
    my $numerator = weighted_count($bdd, $compiled->{numerator}, $priors);
    my $p = divr($numerator, $denominator);
    return {
        schema => 'skein.result/1', model_digest => $self->{model}->digest,
        query => deep_copy($compiled->{query}), priors => {map { $_ => text($priors->{$_}) } sort keys %$priors},
        probability => text($p), decimal => decimal($p),
        numerator => text($numerator), denominator => text($denominator),
        variables => scalar @{$self->{model}->noise_names},
        reachable_nodes => scalar @{$bdd->reachable([$compiled->{numerator}, $compiled->{denominator}])},
        order => $bdd->variables,
    };
}

sub solve_all {
    my ($self, %options) = @_;
    return [map { $self->solve($_, %options) } @{$self->{model}->query_names}];
}

sub observational {
    my ($self, $event, $evidence) = @_;
    return $self->solve({event => $event, evidence => $evidence // const(1), interventions => {}});
}

sub interventional {
    my ($self, $event, $interventions, $evidence) = @_;
    return $self->solve({event => $event, evidence => $evidence // const(1), interventions => $interventions});
}

sub counterfactual {
    my ($self, $event, $interventions, $factual) = @_;
    return $self->solve({event => $event, factual => $factual // const(1), interventions => $interventions});
}

sub joint_worlds {
    my ($self, $events, $factual, %options) = @_;
    my $roots = $self->{compiler}->joint_worlds($events, $factual);
    my $priors = $options{priors} // $self->{model}->priors;
    my $bdd = $self->{compiler}->bdd;
    my $d = weighted_count($bdd, $roots->{denominator}, $priors);
    die "impossible evidence: probability is zero\n" if is_zero($d);
    my $n = weighted_count($bdd, $roots->{numerator}, $priors);
    return {probability => text(divr($n, $d)), numerator => text($n), denominator => text($d)};
}

sub sensitivity {
    my ($self, $query, %options) = @_;
    $query = $self->{model}->query($query) unless ref($query);
    my $roots = $self->{compiler}->query($query);
    my $result = conditional_gradient($self->{compiler}->bdd,
        $roots->{numerator}, $roots->{denominator}, $options{priors} // $self->{model}->priors);
    return { probability => text($result->{probability}),
        derivatives => {map { $_ => text($result->{derivatives}{$_}) } sort keys %{$result->{derivatives}}} };
}

sub noise_posterior {
    my ($self, $query, %options) = @_;
    $query = $self->{model}->query($query) unless ref($query);
    my $roots = $self->{compiler}->query($query);
    my $result = posterior($self->{compiler}->bdd, $roots->{denominator},
        $options{priors} // $self->{model}->priors);
    return { map { $_ => text($result->{$_}) } sort keys %$result };
}

sub distribution {
    my ($self, $names, %options) = @_;
    die "distribution variables must be an array\n" unless ref($names) eq 'ARRAY';
    my $limit = integer($options{max_variables} // 12, 'distribution limit', 0, 20);
    die "distribution variable limit exceeded\n" if @$names > $limit;
    my %seen;
    for my $name (@$names) {
        die "duplicate distribution variable '$name'\n" if $seen{$name}++;
        $self->{model}->validate_expression(var($name));
    }
    my @rows;
    for my $mask (0 .. (2 ** @$names) - 1) {
        my $event = const(1);
        my %assignment;
        for my $i (0 .. $#$names) {
            my $value = ($mask >> $i) & 1;
            $assignment{$names->[$i]} = $value;
            my $literal = $value ? var($names->[$i]) : op('not', var($names->[$i]));
            $event = op('and', $event, $literal);
        }
        my $query = {event => $event, interventions => $options{interventions} // {}};
        $query->{evidence} = $options{evidence} if exists $options{evidence};
        $query->{factual} = $options{factual} if exists $options{factual};
        push @rows, {assignment => \%assignment, probability => $self->solve($query)->{probability}};
    }
    return \@rows;
}

1;
