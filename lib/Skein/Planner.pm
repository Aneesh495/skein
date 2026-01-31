package Skein::Planner;
use 5.020;
use strict;
use warnings;
use Skein::Rat qw(probability compare text);
use Skein::Util qw(integer deep_copy canonical_json);

sub new {
    my ($class, $engine, %options) = @_;
    return bless {
        engine => $engine,
        max_actions => integer($options{max_actions} // 10, 'planner action limit', 0, 20),
        max_states => integer($options{max_states} // 100_000, 'planner state limit', 1, 5_000_000),
    }, $class;
}

sub plan {
    my ($self, $input, %options) = @_;
    my $model = $self->{engine}->model;
    $input = $model->query($input) unless ref($input);
    my $query = deep_copy($input);
    $model->validate_query($query);
    my $repairs = $options{repairs} // $model->repairs;
    die "repairs must be an array\n" unless ref($repairs) eq 'ARRAY';
    die "planner action limit exceeded\n" if @$repairs > $self->{max_actions};
    my %known = map { $_->{name} => $_ } @{$model->repairs};
    my %seen;
    my @actions;
    for my $repair (@$repairs) {
        my $name = ref($repair) eq 'HASH' ? $repair->{name} : $repair;
        die "unknown or duplicate repair '$name'\n" unless exists($known{$name}) && !$seen{$name}++;
        push @actions, $known{$name};
    }
    @actions = sort { $a->{name} cmp $b->{name} } @actions;
    my $budget = integer($options{budget} // 1_000_000_000, 'repair budget', 0, 1_000_000_000);
    my $target = exists($options{target}) ? text(probability($options{target})) : undef;
    my %required = map { $_ => 1 } @{$options{required} // []};
    my %forbidden = map { $_ => 1 } @{$options{forbidden} // []};
    for my $name (keys %required, keys %forbidden) {
        die "constraint names an unavailable repair '$name'\n" unless $seen{$name};
        die "repair is both required and forbidden\n" if $required{$name} && $forbidden{$name};
    }
    my @candidates;
    my %stats = (states => 0, feasible => 0, budget_pruned => 0, conflicts => 0);
    my $search;
    $search = sub {
        my ($index, $cost, $chosen, $interventions) = @_;
        die "planner search state limit exceeded\n" if ++$stats{states} > $self->{max_states};
        if ($cost > $budget) {
            ++$stats{budget_pruned};
            return;
        }
        if ($index == @actions) {
            my $candidate_query = {%$query, interventions => {%$interventions}};
            my $evaluation = $options{evaluate}
                ? $options{evaluate}->($candidate_query)
                : $self->{engine}->solve($candidate_query);
            my $risk = text(probability($evaluation->{probability}));
            push @candidates, {actions => [@$chosen], cost => $cost, probability => $risk,
                interventions => {%$interventions}};
            ++$stats{feasible};
            return;
        }
        my $action = $actions[$index];
        my $name = $action->{name};
        $search->($index + 1, $cost, $chosen, $interventions) unless $required{$name};
        return if $forbidden{$name};
        my $node = $action->{node};
        if (exists($interventions->{$node}) && $interventions->{$node} != $action->{value}) {
            ++$stats{conflicts};
            return;
        }
        $search->($index + 1, $cost + $action->{cost}, [@$chosen, $name],
            {%$interventions, $node => $action->{value}});
    };
    $search->(0, 0, [], $query->{interventions});
    @candidates = sort {
        $a->{cost} <=> $b->{cost} || compare($a->{probability}, $b->{probability})
            || join(',', @{$a->{actions}}) cmp join(',', @{$b->{actions}})
    } @candidates;
    my @frontier;
    my $best_risk;
    for my $candidate (@candidates) {
        next if defined($best_risk) && compare($candidate->{probability}, $best_risk) >= 0;
        push @frontier, $candidate;
        $best_risk = $candidate->{probability};
    }
    my $selected;
    if (defined $target) {
        ($selected) = grep { compare($_->{probability}, $target) <= 0 } @frontier;
    } elsif (@frontier) {
        $selected = $frontier[-1];
    }
    return {schema => 'skein.plan/1', model_digest => $model->digest,
        status => $selected ? 'optimal' : @frontier ? 'target_unreachable' : 'infeasible',
        budget => $budget, target => $target, frontier => \@frontier,
        selected => $selected, stats => \%stats,
        objective => defined($target) ? 'minimum cost meeting exact risk target' : 'minimum exact risk within budget',
        tie_policy => 'One lexicographically first representative per equal cost and risk.'};
}

1;
