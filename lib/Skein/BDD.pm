package Skein::BDD;
use 5.020;
use strict;
use warnings;
use Skein::Util qw(identifier integer boolean);

my %TABLE = (and => 8, or => 14, xor => 6, implies => 11, eq => 9,
    nand => 7, nor => 1);

sub new {
    my ($class, $variables, %options) = @_;
    die "BDD variables must be an array\n" unless ref($variables) eq 'ARRAY';
    die "BDD variable limit exceeded\n" if @$variables > 4096;
    my %rank;
    for my $index (0 .. $#$variables) {
        my $name = identifier($variables->[$index], 'BDD variable');
        die "duplicate BDD variable '$name'\n" if exists $rank{$name};
        $rank{$name} = $index;
    }
    my $terminal_rank = scalar @$variables;
    return bless {
        variables => [@$variables], rank => \%rank,
        nodes => [[$terminal_rank, 0, 0], [$terminal_rank, 1, 1]],
        unique => {}, cache => {},
        max_nodes => integer($options{max_nodes} // 250_000, 'BDD node limit', 2, 5_000_000),
        max_work => integer($options{max_work} // 2_000_000, 'BDD work limit', 1, 20_000_000),
        cache_limit => integer($options{cache_limit} // 100_000, 'BDD cache limit', 0, 5_000_000),
        stats => { apply_calls => 0, cache_hits => 0, unique_hits => 0, peak_work => 0 },
    }, $class;
}

sub variables { return [@{$_[0]{variables}}] }
sub node_count { return scalar @{$_[0]{nodes}} }
sub rank {
    my ($self, $name) = @_;
    die "unknown BDD variable '$name'\n" unless exists $self->{rank}{$name};
    return $self->{rank}{$name};
}

sub _id {
    my ($self, $id) = @_;
    return integer($id, 'BDD node id', 0, $#{$self->{nodes}});
}

sub node {
    my ($self, $id) = @_;
    $self->_id($id);
    return [@{$self->{nodes}[$id]}];
}

sub mk {
    my ($self, $rank, $low, $high) = @_;
    integer($rank, 'BDD rank', 0, $#{$self->{variables}});
    $self->_id($low);
    $self->_id($high);
    return $low if $low == $high;
    die "BDD child violates variable order\n"
        if $self->{nodes}[$low][0] <= $rank || $self->{nodes}[$high][0] <= $rank;
    my $key = "$rank,$low,$high";
    if (exists $self->{unique}{$key}) {
        ++$self->{stats}{unique_hits};
        return $self->{unique}{$key};
    }
    die "BDD node limit exceeded\n" if $self->node_count >= $self->{max_nodes};
    my $id = $self->node_count;
    push @{$self->{nodes}}, [$rank, $low, $high];
    $self->{unique}{$key} = $id;
    return $id;
}

sub variable {
    my ($self, $name) = @_;
    return $self->mk($self->rank($name), 0, 1);
}

sub _table {
    my ($operator) = @_;
    return $TABLE{$operator} if exists $TABLE{$operator};
    return integer($operator, 'Boolean truth table', 0, 15);
}

sub _key {
    my ($table, $a, $b) = @_;
    ($a, $b) = ($b, $a) if (($table >> 1) & 1) == (($table >> 2) & 1) && $a > $b;
    return "$table,$a,$b";
}

sub _terminal {
    my ($table, $a, $b) = @_;
    return ($table >> (($a << 1) | $b)) & 1 if $a < 2 && $b < 2;
    return 0 if $table == 0;
    return 1 if $table == 15;
    return $a if $table == 12;
    return $b if $table == 10;
    if ($table == 8) {
        return 0 if $a == 0 || $b == 0;
        return $b if $a == 1;
        return $a if $b == 1 || $a == $b;
    }
    if ($table == 14) {
        return 1 if $a == 1 || $b == 1;
        return $b if $a == 0;
        return $a if $b == 0 || $a == $b;
    }
    if ($table == 6) {
        return 0 if $a == $b;
        return $b if $a == 0;
        return $a if $b == 0;
    }
    if ($table == 9 && $a == $b) {
        return 1;
    }
    return undef;
}

sub apply {
    my ($self, $operator, $a, $b) = @_;
    my $table = _table($operator);
    $self->_id($a);
    $self->_id($b);
    ++$self->{stats}{apply_calls};
    my $root_key = _key($table, $a, $b);
    if (exists $self->{cache}{$root_key}) {
        ++$self->{stats}{cache_hits};
        return $self->{cache}{$root_key};
    }
    my %results;
    my %pending;
    my @stack = ([$a, $b]);
    my $work = 0;
    while (@stack) {
        die "BDD apply work limit exceeded\n" if ++$work > $self->{max_work};
        my ($left, $right) = @{$stack[-1]};
        my $key = _key($table, $left, $right);
        if (exists $results{$key}) {
            pop @stack;
            next;
        }
        if (exists $self->{cache}{$key}) {
            $results{$key} = $self->{cache}{$key};
            ++$self->{stats}{cache_hits};
            pop @stack;
            next;
        }
        my $trivial = _terminal($table, $left, $right);
        if (defined $trivial) {
            $results{$key} = $trivial;
            pop @stack;
            next;
        }
        if (exists $pending{$key}) {
            my ($rank, $low_key, $high_key) = @{$pending{$key}};
            die "BDD apply internal dependency failure\n"
                unless exists($results{$low_key}) && exists($results{$high_key});
            $results{$key} = $self->mk($rank, $results{$low_key}, $results{$high_key});
            pop @stack;
            next;
        }
        my $left_node = $self->{nodes}[$left];
        my $right_node = $self->{nodes}[$right];
        my $rank = $left_node->[0] < $right_node->[0] ? $left_node->[0] : $right_node->[0];
        my ($ll, $lh) = $left_node->[0] == $rank ? @$left_node[1, 2] : ($left, $left);
        my ($rl, $rh) = $right_node->[0] == $rank ? @$right_node[1, 2] : ($right, $right);
        my $low_key = _key($table, $ll, $rl);
        my $high_key = _key($table, $lh, $rh);
        $pending{$key} = [$rank, $low_key, $high_key];
        push @stack, [$lh, $rh] unless exists $results{$high_key};
        push @stack, [$ll, $rl] unless exists $results{$low_key};
    }
    $self->{stats}{peak_work} = $work if $work > $self->{stats}{peak_work};
    if ($self->{cache_limit}) {
        $self->{cache} = {} if keys(%{$self->{cache}}) + keys(%results) > $self->{cache_limit};
        if (keys(%results) <= $self->{cache_limit}) {
            @{$self->{cache}}{keys %results} = values %results;
        }
    }
    return $results{$root_key};
}

sub negate { return $_[0]->apply('xor', $_[1], 1) }

sub ite {
    my ($self, $condition, $yes, $no) = @_;
    $self->_id($_) for ($condition, $yes, $no);
    return $condition == 1 ? $yes : $no if $condition < 2;
    return $yes if $yes == $no;
    return $self->apply('or', $self->apply('and', $condition, $yes),
        $self->apply('and', $self->negate($condition), $no));
}

sub fold {
    my ($self, $operator, $roots, $identity) = @_;
    my $result = $identity;
    $result = $self->apply($operator, $result, $_) for @$roots;
    return $result;
}

sub threshold {
    my ($self, $roots, $k, $exact) = @_;
    integer($k, 'BDD threshold', 0, scalar @$roots);
    $self->_id($_) for @$roots;
    my $maximum = $exact ? $k + 1 : $k;
    my @atleast = (1, (0) x $maximum);
    my $processed = 0;
    for my $root (@$roots) {
        ++$processed;
        my $top = $processed < $maximum ? $processed : $maximum;
        for (my $j = $top; $j >= 1; --$j) {
            $atleast[$j] = $self->ite($root, $atleast[$j - 1], $atleast[$j]);
        }
    }
    return $atleast[$k] unless $exact;
    return $self->apply('and', $atleast[$k], $self->negate($atleast[$k + 1]));
}

sub evaluate {
    my ($self, $root, $assignment) = @_;
    $self->_id($root);
    die "BDD assignment must be an object\n" unless ref($assignment) eq 'HASH';
    while ($root >= 2) {
        my ($rank, $low, $high) = @{$self->{nodes}[$root]};
        my $name = $self->{variables}[$rank];
        die "missing BDD assignment '$name'\n" unless exists $assignment->{$name};
        $root = boolean($assignment->{$name}) ? $high : $low;
    }
    return $root;
}

sub reachable {
    my ($self, $roots) = @_;
    $roots = [$roots] unless ref($roots) eq 'ARRAY';
    $self->_id($_) for @$roots;
    my %seen;
    my @stack = @$roots;
    while (@stack) {
        my $id = pop @stack;
        next if $seen{$id}++;
        push @stack, @{$self->{nodes}[$id]}[1, 2] if $id >= 2;
    }
    return [sort { $a <=> $b } keys %seen];
}

sub stats {
    my ($self) = @_;
    return { %{$self->{stats}}, nodes => $self->node_count,
        cache_entries => scalar keys %{$self->{cache}} };
}

sub clear_cache {
    $_[0]{cache} = {};
    return;
}

sub assert_invariants {
    my ($self) = @_;
    my %unique;
    for my $id (2 .. $#{$self->{nodes}}) {
        my ($rank, $low, $high) = @{$self->{nodes}[$id]};
        die "unreduced BDD node\n" if $low == $high;
        die "BDD child is not older than parent\n" if $low >= $id || $high >= $id;
        die "unordered BDD edge\n" if $self->{nodes}[$low][0] <= $rank
            || $self->{nodes}[$high][0] <= $rank;
        my $key = "$rank,$low,$high";
        die "duplicate BDD node\n" if $unique{$key}++;
        die "BDD unique table mismatch\n" unless $self->{unique}{$key} == $id;
    }
    return 1;
}

1;
