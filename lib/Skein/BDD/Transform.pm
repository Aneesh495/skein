package Skein::BDD::Transform;
use 5.020;
use strict;
use warnings;
use Exporter 'import';
use Math::BigInt;
use Skein::BDD;
use Skein::Util qw(boolean integer check_keys);

our @EXPORT_OK = qw(restrict quantify compose transfer support sat_count cubes
    export_diagram import_diagram equivalent);

sub restrict {
    my ($bdd, $root, $assignment) = @_;
    die "restriction must be an object\n" unless ref($assignment) eq 'HASH';
    my %by_rank;
    for my $name (sort keys %$assignment) {
        $by_rank{$bdd->rank($name)} = boolean($assignment->{$name});
    }
    my %result = (0 => 0, 1 => 1);
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        $result{$id} = exists $by_rank{$rank}
            ? $result{$by_rank{$rank} ? $high : $low}
            : $bdd->mk($rank, $result{$low}, $result{$high});
    }
    return $result{$root};
}

sub quantify {
    my ($bdd, $root, $variables, $kind) = @_;
    $kind //= 'exists';
    die "unknown quantifier\n" unless $kind eq 'exists' || $kind eq 'forall';
    my %selected = map { $bdd->rank($_) => 1 } @$variables;
    my %result = (0 => 0, 1 => 1);
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        $result{$id} = $selected{$rank}
            ? $bdd->apply($kind eq 'exists' ? 'or' : 'and', $result{$low}, $result{$high})
            : $bdd->mk($rank, $result{$low}, $result{$high});
    }
    return $result{$root};
}

sub compose {
    my ($bdd, $root, $mapping) = @_;
    die "composition must be an object\n" unless ref($mapping) eq 'HASH';
    my %by_rank;
    for my $name (sort keys %$mapping) {
        $bdd->node($mapping->{$name});
        $by_rank{$bdd->rank($name)} = $mapping->{$name};
    }
    my %result = (0 => 0, 1 => 1);
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $condition = exists($by_rank{$rank}) ? $by_rank{$rank}
            : $bdd->variable($bdd->variables->[$rank]);
        $result{$id} = $bdd->ite($condition, $result{$high}, $result{$low});
    }
    return $result{$root};
}

sub transfer {
    my ($from, $to, $root) = @_;
    my $variables = $from->variables;
    $to->rank($_) for @$variables;
    my %result = (0 => 0, 1 => 1);
    for my $id (@{$from->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$from->node($id)};
        my $condition = $to->variable($variables->[$rank]);
        $result{$id} = $to->ite($condition, $result{$high}, $result{$low});
    }
    return $result{$root};
}

sub equivalent {
    my ($left_bdd, $left_root, $right_bdd, $right_root) = @_;
    my $converted = transfer($right_bdd, $left_bdd, $right_root);
    return $converted == $left_root ? 1 : 0;
}

sub support {
    my ($bdd, $root) = @_;
    my %ranks;
    for my $id (@{$bdd->reachable($root)}) {
        $ranks{$bdd->node($id)->[0]} = 1 if $id >= 2;
    }
    my $variables = $bdd->variables;
    return [map { $variables->[$_] } sort { $a <=> $b } keys %ranks];
}

sub sat_count {
    my ($bdd, $root) = @_;
    my %counts = (0 => Math::BigInt->new(0), 1 => Math::BigInt->new(1));
    for my $id (@{$bdd->reachable($root)}) {
        next if $id < 2;
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $low_gap = $bdd->node($low)->[0] - $rank - 1;
        my $high_gap = $bdd->node($high)->[0] - $rank - 1;
        my $a = $counts{$low}->copy->blsft($low_gap, 2);
        my $b = $counts{$high}->copy->blsft($high_gap, 2);
        $counts{$id} = $a->badd($b);
    }
    return $counts{$root}->copy->blsft($bdd->node($root)->[0], 2);
}

sub cubes {
    my ($bdd, $root, %options) = @_;
    my $limit = integer($options{limit} // 100_000, 'cube limit', 1, 1_000_000);
    my $variables = $bdd->variables;
    $bdd->node($root);
    my @stack = ([$root, {}]);
    my @result;
    while (@stack) {
        my ($id, $path) = @{pop @stack};
        next if $id == 0;
        if ($id == 1) {
            die "cube enumeration limit exceeded\n" if @result >= $limit;
            if ($options{callback}) {
                $options{callback}->({%$path});
                push @result, undef;
            } else {
                push @result, $path;
            }
            next;
        }
        my ($rank, $low, $high) = @{$bdd->node($id)};
        my $name = $variables->[$rank];
        push @stack, [$high, {%$path, $name => 1}], [$low, {%$path, $name => 0}];
    }
    return $options{callback} ? scalar @result : \@result;
}

sub export_diagram {
    my ($bdd, $roots) = @_;
    $roots = [$roots] unless ref($roots) eq 'ARRAY';
    $bdd->node($_) for @$roots;
    my %mapping = (0 => 0, 1 => 1);
    my @rows;
    for my $root (@$roots) {
        my @stack = ([$root, 0]);
        while (@stack) {
            my ($id, $expanded) = @{pop @stack};
            next if exists $mapping{$id};
            my ($rank, $low, $high) = @{$bdd->node($id)};
            if (!$expanded) {
                push @stack, [$id, 1], [$high, 0], [$low, 0];
                next;
            }
            die "diagram export dependency failure\n" unless exists($mapping{$low}) && exists($mapping{$high});
            my $new_id = 2 + @rows;
            $mapping{$id} = $new_id;
            push @rows, { id => $new_id, rank => $rank, low => $mapping{$low}, high => $mapping{$high} };
        }
    }
    return {
        schema => 'skein.bdd/1', variables => $bdd->variables,
        nodes => \@rows, roots => [map { $mapping{$_} } @$roots],
    };
}

sub import_diagram {
    my ($data, %options) = @_;
    check_keys($data, [qw(schema variables nodes roots)], [qw(schema variables nodes roots)], 'diagram');
    die "unsupported diagram schema\n" unless $data->{schema} eq 'skein.bdd/1';
    die "diagram nodes and roots must be arrays\n"
        unless ref($data->{nodes}) eq 'ARRAY' && ref($data->{roots}) eq 'ARRAY';
    my $bdd = Skein::BDD->new($data->{variables}, %options);
    die "diagram exceeds node limit\n" if @{$data->{nodes}} + 2 > $bdd->{max_nodes};
    for my $row (@{$data->{nodes}}) {
        check_keys($row, [qw(id rank low high)], [qw(id rank low high)], 'diagram node');
        integer($row->{id}, 'diagram id', $bdd->node_count, $bdd->node_count);
        my $id = $bdd->mk($row->{rank}, $row->{low}, $row->{high});
        die "diagram contains unreduced or duplicate node\n" unless $id == $row->{id};
    }
    $bdd->node($_) for @{$data->{roots}};
    $bdd->assert_invariants;
    return ($bdd, [@{$data->{roots}}]);
}

1;
