package Skein::Markov;
use 5.020;
use strict;
use warnings;
use Skein::Rat qw(probability rat zero one add subr mul compare text is_zero);
use Skein::Linear qw(matrix solve transpose);
use Skein::Util qw(identifier integer);

sub new {
    my ($class, $states, $transitions, %options) = @_;
    die "Markov states must be a nonempty array\n" unless ref($states) eq 'ARRAY' && @$states;
    die "Markov state limit exceeded\n" if @$states > 64;
    my %index;
    for my $i (0 .. $#$states) {
        identifier($states->[$i], 'Markov state');
        die "duplicate Markov state\n" if exists $index{$states->[$i]};
        $index{$states->[$i]} = $i;
    }
    my $p = matrix($transitions);
    die "Markov transition dimensions mismatch\n" unless @$p == @$states
        && @{$p->[0]} == @$states;
    for my $row (@$p) {
        my $sum = zero();
        for my $value (@$row) {
            probability($value);
            $sum = add($sum, $value);
        }
        die "Markov transition row is not stochastic\n" unless compare($sum, 1) == 0;
    }
    return bless {states => [@$states], index => \%index, transitions => $p,
        max_steps => integer($options{max_steps} // 256, 'Markov step limit', 0, 4096)}, $class;
}

sub states { return [@{$_[0]{states}}] }
sub transitions { return [map { [map { text($_) } @$_] } @{$_[0]{transitions}}] }

sub _distribution {
    my ($self, $input) = @_;
    my @values;
    if (!defined $input) {
        @values = (one(), (zero()) x ($self->states->@* - 1));
    } elsif (ref($input) eq 'ARRAY') {
        die "Markov initial distribution dimension mismatch\n" unless @$input == @{$self->{states}};
        @values = map { probability($_) } @$input;
    } elsif (ref($input) eq 'HASH') {
        die "unknown Markov initial state\n" if grep { !exists $self->{index}{$_} } keys %$input;
        @values = map { probability($input->{$_} // 0) } @{$self->{states}};
    } else {
        die "invalid Markov initial distribution\n";
    }
    my $total = zero();
    $total = add($total, $_) for @values;
    die "Markov initial distribution is not normalized\n" if compare($total, 1) != 0;
    return \@values;
}

sub _step {
    my ($self, $distribution) = @_;
    my @next = map { zero() } @{$self->{states}};
    for my $from (0 .. $#$distribution) {
        next if is_zero($distribution->[$from]);
        for my $to (0 .. $#next) {
            $next[$to] = add($next[$to], mul($distribution->[$from], $self->{transitions}[$from][$to]));
        }
    }
    return \@next;
}

sub distribution {
    my ($self, $steps, $initial) = @_;
    integer($steps, 'Markov horizon', 0, $self->{max_steps});
    my $values = $self->_distribution($initial);
    $values = $self->_step($values) for 1 .. $steps;
    return {map { $self->{states}[$_] => text($values->[$_]) } 0 .. $#$values};
}

sub trajectory {
    my ($self, $steps, $initial) = @_;
    integer($steps, 'Markov horizon', 0, $self->{max_steps});
    my $values = $self->_distribution($initial);
    my @rows;
    for my $time (0 .. $steps) {
        push @rows, {time => $time,
            distribution => {map { $self->{states}[$_] => text($values->[$_]) } 0 .. $#$values}};
        $values = $self->_step($values) if $time < $steps;
    }
    return \@rows;
}

sub _targets {
    my ($self, $targets) = @_;
    die "target states must be a nonempty array\n" unless ref($targets) eq 'ARRAY' && @$targets;
    my %result;
    for my $name (@$targets) {
        die "unknown Markov target '$name'\n" unless exists $self->{index}{$name};
        $result{$self->{index}{$name}} = 1;
    }
    return \%result;
}

sub first_passage {
    my ($self, $targets, $steps, $initial) = @_;
    integer($steps, 'Markov horizon', 0, $self->{max_steps});
    my $target = $self->_targets($targets);
    my $values = $self->_distribution($initial);
    my $initial_hit = zero();
    for my $index (keys %$target) {
        $initial_hit = add($initial_hit, $values->[$index]);
        $values->[$index] = zero();
    }
    my $cumulative = $initial_hit;
    my $truncated_mean = zero();
    my @rows = ({time => 0, mass => text($initial_hit), survival => text(subr(1,$initial_hit))});
    for my $time (1 .. $steps) {
        my $next = $self->_step($values);
        my $hit = zero();
        for my $index (keys %$target) {
            $hit = add($hit, $next->[$index]);
            $next->[$index] = zero();
        }
        $cumulative = add($cumulative, $hit);
        $truncated_mean = add($truncated_mean, mul($hit, $time));
        push @rows, {time => $time, mass => text($hit), survival => text(subr(1,$cumulative))};
        $values = $next;
    }
    return {times => \@rows, cumulative => text($cumulative),
        survival => text(subr(1,$cumulative)), truncated_first_moment => text($truncated_mean)};
}

sub expected_reward {
    my ($self, $rewards, $steps, $initial) = @_;
    integer($steps, 'Markov reward horizon', 0, $self->{max_steps});
    die "rewards must be a state object\n" unless ref($rewards) eq 'HASH';
    die "reward names an unknown state\n" if grep { !exists $self->{index}{$_} } keys %$rewards;
    my @reward = map { rat($rewards->{$_} // 0) } @{$self->{states}};
    my $values = $self->_distribution($initial);
    my $total = zero();
    my @rows;
    for my $time (0 .. $steps - 1) {
        my $at_time = zero();
        $at_time = add($at_time, mul($values->[$_], $reward[$_])) for 0 .. $#reward;
        $total = add($total, $at_time);
        push @rows, {time => $time, reward => text($at_time)};
        $values = $self->_step($values);
    }
    return {total => text($total), times => \@rows, convention => 'Rewards accrue at times 0 through horizon minus 1.'};
}

sub communicating_classes {
    my ($self) = @_;
    my $n = scalar @{$self->{states}};
    my @reach = map {
        my $from = $_;
        [map { $from == $_ || !is_zero($self->{transitions}[$from][$_]) ? 1 : 0 } 0 .. $n - 1];
    } 0 .. $n - 1;
    for my $via (0 .. $n - 1) {
        for my $from (0 .. $n - 1) {
            next unless $reach[$from][$via];
            $reach[$from][$_] ||= $reach[$via][$_] for 0 .. $n - 1;
        }
    }
    my %seen;
    my @classes;
    for my $start (0 .. $n - 1) {
        next if $seen{$start};
        my @members = grep { $reach[$start][$_] && $reach[$_][$start] } 0 .. $n - 1;
        my %member = map { $_ => 1 } @members;
        $seen{$_} = 1 for @members;
        my $closed = 1;
        for my $from (@members) {
            for my $to (0 .. $n - 1) {
                $closed = 0 if !$member{$to} && !is_zero($self->{transitions}[$from][$to]);
            }
        }
        push @classes, {states => [map { $self->{states}[$_] } @members], closed => $closed};
    }
    return \@classes;
}

sub hitting_probabilities {
    my ($self, $targets) = @_;
    my $target = $self->_targets($targets);
    my %boundary = map { $_ => one() } keys %$target;
    for my $class (@{$self->communicating_classes}) {
        next unless $class->{closed};
        my @indices = map { $self->{index}{$_} } @{$class->{states}};
        next if grep { $target->{$_} } @indices;
        $boundary{$_} = zero() for @indices;
    }
    my @unknown = grep { !exists $boundary{$_} } 0 .. $#{$self->{states}};
    my (@a, @b);
    for my $from (@unknown) {
        push @a, [map { subr($from == $_ ? 1 : 0, $self->{transitions}[$from][$_]) } @unknown];
        my $rhs = zero();
        $rhs = add($rhs, mul($self->{transitions}[$from][$_], $boundary{$_})) for keys %boundary;
        push @b, $rhs;
    }
    my $solution = @unknown ? solve(\@a, \@b) : [];
    $boundary{$unknown[$_]} = $solution->[$_] for 0 .. $#unknown;
    return {map { $self->{states}[$_] => text($boundary{$_}) } 0 .. $#{$self->{states}}};
}

sub hitting_times {
    my ($self, $targets) = @_;
    my $target = $self->_targets($targets);
    my $h = $self->hitting_probabilities($targets);
    my @finite = grep { !$target->{$_} && compare($h->{$self->{states}[$_]}, 1) == 0 }
        0 .. $#{$self->{states}};
    my @a = map {
        my $from = $_;
        [map { subr($from == $_ ? 1 : 0, $self->{transitions}[$from][$_]) } @finite];
    } @finite;
    my $solution = @finite ? solve(\@a, [(1) x @finite]) : [];
    my %result = map { $self->{states}[$_] => $target->{$_} ? '0' : undef } 0 .. $#{$self->{states}};
    $result{$self->{states}[$finite[$_]]} = text($solution->[$_]) for 0 .. $#finite;
    return {expected_steps => \%result, hitting_probability => $h,
        infinite_convention => 'A null expected time means positive probability of never reaching a target.'};
}

sub stationary {
    my ($self) = @_;
    my $p = $self->{transitions};
    my $n = scalar @$p;
    my @a = map {
        my $row = $_;
        [map { subr($p->[$_][$row], $_ == $row ? 1 : 0) } 0 .. $n - 1];
    } 0 .. $n - 1;
    $a[-1] = [(1) x $n];
    my @b = ((0) x ($n - 1), 1);
    my $solution = solve(\@a, \@b);
    probability($_) for @$solution;
    return {map { $self->{states}[$_] => text($solution->[$_]) } 0 .. $n - 1};
}

1;
