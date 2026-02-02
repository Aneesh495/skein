package Skein::Robust;
use 5.020;
use strict;
use warnings;
use Skein::Rat qw(probability compare text);
use Skein::Util qw(integer deep_copy);
use Skein::Planner;

sub new {
    my ($class, $engine, %options) = @_;
    return bless {
        engine => $engine,
        max_variables => integer($options{max_variables} // 12, 'robustness variable limit', 0, 20),
        max_vertices => integer($options{max_vertices} // 4096, 'robustness vertex limit', 1, 1_048_576),
    }, $class;
}

sub vertices {
    my ($self, $intervals, $callback) = @_;
    $intervals //= $self->{engine}->model->intervals;
    die "prior intervals must be an object\n" unless ref($intervals) eq 'HASH';
    my $priors = $self->{engine}->model->priors;
    my @varying;
    my %fixed = %$priors;
    my %bounds;
    for my $name (sort keys %$intervals) {
        die "interval names unknown noise '$name'\n" unless exists $priors->{$name};
        my $pair = $intervals->{$name};
        die "interval requires two endpoints\n" unless ref($pair) eq 'ARRAY' && @$pair == 2;
        my ($low, $high) = map { text(probability($_)) } @$pair;
        die "interval endpoints are reversed\n" if compare($low, $high) > 0;
        $bounds{$name} = [$low, $high];
        if (compare($low, $high) == 0) {
            $fixed{$name} = $low;
        } else {
            push @varying, $name;
        }
    }
    die "robustness variable limit exceeded\n" if @varying > $self->{max_variables};
    my $count = 2 ** @varying;
    die "robustness vertex limit exceeded\n" if $count > $self->{max_vertices};
    for my $mask (0 .. $count - 1) {
        my %vertex = %fixed;
        for my $i (0 .. $#varying) {
            $vertex{$varying[$i]} = $bounds{$varying[$i]}[($mask >> $i) & 1];
        }
        $callback->(\%vertex, $mask);
    }
    return $count;
}

sub bounds {
    my ($self, $query, %options) = @_;
    my ($minimum, $maximum);
    my @evaluations;
    my $count = $self->vertices($options{intervals}, sub {
        my ($priors, $index) = @_;
        my $result = $self->{engine}->solve($query, priors => $priors);
        my $point = {probability => $result->{probability}, priors => {%$priors}, index => $index,
            denominator => $result->{denominator}};
        $minimum = $point if !$minimum || compare($point->{probability}, $minimum->{probability}) < 0;
        $maximum = $point if !$maximum || compare($point->{probability}, $maximum->{probability}) > 0;
        push @evaluations, $point if $options{include_vertices};
    });
    return {schema => 'skein.bounds/1', model_digest => $self->{engine}->model->digest,
        minimum => $minimum, maximum => $maximum, vertices => $count,
        intervals => deep_copy($options{intervals} // $self->{engine}->model->intervals),
        method => 'Exact corner enumeration of an independent-prior box with positive evidence at every corner.',
        ($options{include_vertices} ? (evaluations => \@evaluations) : ())};
}

sub plan {
    my ($self, $query, %options) = @_;
    my $planner = Skein::Planner->new($self->{engine});
    my $intervals = delete $options{intervals};
    my $result = $planner->plan($query, %options, evaluate => sub {
        my ($candidate) = @_;
        my $bounds = $self->bounds($candidate, intervals => $intervals // $self->{engine}->model->intervals);
        return {probability => $bounds->{maximum}{probability}};
    });
    $result->{risk_definition} = 'Worst exact risk over the independent-prior interval box.';
    $result->{intervals} = deep_copy($intervals // $self->{engine}->model->intervals);
    return $result;
}

1;
