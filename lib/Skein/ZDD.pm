package Skein::ZDD;
use 5.020;
use strict;
use warnings;
no warnings 'recursion';
use Math::BigInt;
use Skein::Util qw(identifier integer);

sub new {
    my ($class, $variables, %options) = @_;
    die "ZDD variables must be an array\n" unless ref($variables) eq 'ARRAY';
    die "ZDD variable limit exceeded\n" if @$variables > 512;
    my %rank;
    for my $i (0 .. $#$variables) {
        identifier($variables->[$i], 'ZDD variable');
        die "duplicate ZDD variable\n" if exists $rank{$variables->[$i]};
        $rank{$variables->[$i]} = $i;
    }
    return bless {
        variables => [@$variables], rank => \%rank,
        nodes => [[scalar @$variables, 0, 0], [scalar @$variables, 1, 1]],
        unique => {}, cache => {},
        max_nodes => integer($options{max_nodes} // 250_000, 'ZDD node limit', 2, 2_000_000),
        max_work => integer($options{max_work} // 2_000_000, 'ZDD work limit', 1, 20_000_000),
        work => 0,
    }, $class;
}

sub variables { return [@{$_[0]{variables}}] }
sub node_count { return scalar @{$_[0]{nodes}} }

sub node {
    my ($self, $id) = @_;
    integer($id, 'ZDD id', 0, $#{$self->{nodes}});
    return [@{$self->{nodes}[$id]}];
}

sub mk {
    my ($self, $rank, $low, $high) = @_;
    integer($rank, 'ZDD rank', 0, $#{$self->{variables}});
    $self->node($low);
    $self->node($high);
    return $low if $high == 0;
    die "ZDD variable order violated\n" if $self->{nodes}[$low][0] <= $rank
        || $self->{nodes}[$high][0] <= $rank;
    my $key = "$rank,$low,$high";
    return $self->{unique}{$key} if exists $self->{unique}{$key};
    die "ZDD node limit exceeded\n" if $self->node_count >= $self->{max_nodes};
    my $id = $self->node_count;
    push @{$self->{nodes}}, [$rank, $low, $high];
    $self->{unique}{$key} = $id;
    return $id;
}

sub singleton {
    my ($self, $set) = @_;
    die "ZDD set must be an array\n" unless ref($set) eq 'ARRAY';
    my %seen;
    my @ranks;
    for my $name (@$set) {
        die "unknown ZDD element '$name'\n" unless exists $self->{rank}{$name};
        die "duplicate ZDD set element '$name'\n" if $seen{$name}++;
        push @ranks, $self->{rank}{$name};
    }
    my $root = 1;
    $root = $self->mk($_, 0, $root) for sort { $b <=> $a } @ranks;
    return $root;
}

sub _split {
    my ($self, $root, $rank) = @_;
    return @{$self->{nodes}[$root]}[1, 2] if $self->{nodes}[$root][0] == $rank;
    return ($root, 0);
}

sub _step {
    my ($self) = @_;
    die "ZDD work limit exceeded\n" if ++$self->{work} > $self->{max_work};
}

sub _apply {
    my ($self, $kind, $a, $b) = @_;
    $self->_step;
    ($a, $b) = ($b, $a) if $kind ne 'difference' && $a > $b;
    my $key = "$kind,$a,$b";
    return $self->{cache}{$key} if exists $self->{cache}{$key};
    my $result;
    if ($kind eq 'union') {
        return $b if $a == 0;
        return $a if $b == 0 || $a == $b;
    } elsif ($kind eq 'intersection') {
        return 0 if $a == 0 || $b == 0;
        return $a if $a == $b;
    } elsif ($kind eq 'difference') {
        return $a if $b == 0;
        return 0 if $a == 0 || $a == $b;
    } else {
        die "unknown ZDD operation\n";
    }
    if ($a < 2 && $b < 2) {
        $result = $kind eq 'union' ? ($a || $b ? 1 : 0)
            : $kind eq 'intersection' ? ($a && $b ? 1 : 0)
            : ($a && !$b ? 1 : 0);
    } else {
        my $rank = $self->{nodes}[$a][0] < $self->{nodes}[$b][0]
            ? $self->{nodes}[$a][0] : $self->{nodes}[$b][0];
        my ($a0, $a1) = $self->_split($a, $rank);
        my ($b0, $b1) = $self->_split($b, $rank);
        $result = $self->mk($rank, $self->_apply($kind, $a0, $b0), $self->_apply($kind, $a1, $b1));
    }
    $self->{cache}{$key} = $result;
    return $result;
}

sub _public_apply {
    my ($self, $kind, $a, $b) = @_;
    $self->node($a);
    $self->node($b);
    $self->{work} = 0;
    return $self->_apply($kind, $a, $b);
}

sub union { return $_[0]->_public_apply('union', $_[1], $_[2]) }
sub intersection { return $_[0]->_public_apply('intersection', $_[1], $_[2]) }
sub difference { return $_[0]->_public_apply('difference', $_[1], $_[2]) }

sub _product {
    my ($self, $a, $b) = @_;
    $self->_step;
    return 0 if $a == 0 || $b == 0;
    return $b if $a == 1;
    return $a if $b == 1;
    ($a, $b) = ($b, $a) if $a > $b;
    my $key = "product,$a,$b";
    return $self->{cache}{$key} if exists $self->{cache}{$key};
    my $rank = $self->{nodes}[$a][0] < $self->{nodes}[$b][0]
        ? $self->{nodes}[$a][0] : $self->{nodes}[$b][0];
    my ($a0, $a1) = $self->_split($a, $rank);
    my ($b0, $b1) = $self->_split($b, $rank);
    my $low = $self->_product($a0, $b0);
    my $high = $self->_apply('union', $self->_product($a1, $b0), $self->_product($a0, $b1));
    $high = $self->_apply('union', $high, $self->_product($a1, $b1));
    my $result = $self->mk($rank, $low, $high);
    $self->{cache}{$key} = $result;
    return $result;
}

sub product {
    my ($self, $a, $b) = @_;
    $self->node($a);
    $self->node($b);
    $self->{work} = 0;
    return $self->_product($a, $b);
}

sub _exclude_supersets {
    my ($self, $candidates, $subsets) = @_;
    $self->_step;
    return $candidates if $subsets == 0;
    return 0 if $candidates == 0 || $subsets == 1;
    my $key = "nonsuper,$candidates,$subsets";
    return $self->{cache}{$key} if exists $self->{cache}{$key};
    my $rank = $self->{nodes}[$candidates][0] < $self->{nodes}[$subsets][0]
        ? $self->{nodes}[$candidates][0] : $self->{nodes}[$subsets][0];
    my ($a0, $a1) = $self->_split($candidates, $rank);
    my ($b0, $b1) = $self->_split($subsets, $rank);
    my $low = $self->_exclude_supersets($a0, $b0);
    my $high = $self->_exclude_supersets($a1, $self->_apply('union', $b0, $b1));
    my $result = $self->mk($rank, $low, $high);
    $self->{cache}{$key} = $result;
    return $result;
}

sub exclude_supersets {
    my ($self, $a, $b) = @_;
    $self->node($a);
    $self->node($b);
    $self->{work} = 0;
    return $self->_exclude_supersets($a, $b);
}

sub _minimal {
    my ($self, $root) = @_;
    $self->_step;
    return $root if $root < 2;
    my $key = "minimal,$root";
    return $self->{cache}{$key} if exists $self->{cache}{$key};
    my ($rank, $low, $high) = @{$self->{nodes}[$root]};
    $low = $self->_minimal($low);
    $high = $self->_exclude_supersets($self->_minimal($high), $low);
    my $result = $self->mk($rank, $low, $high);
    $self->{cache}{$key} = $result;
    return $result;
}

sub minimal {
    my ($self, $root) = @_;
    $self->node($root);
    $self->{work} = 0;
    return $self->_minimal($root);
}

sub count {
    my ($self, $root) = @_;
    $self->node($root);
    my %count = (0 => Math::BigInt->new(0), 1 => Math::BigInt->new(1));
    for my $id (2 .. $root) {
        my ($rank, $low, $high) = @{$self->{nodes}[$id]};
        $count{$id} = $count{$low}->copy->badd($count{$high});
    }
    return $count{$root}->copy;
}

sub sets {
    my ($self, $root, %options) = @_;
    $self->node($root);
    my $limit = integer($options{limit} // 100_000, 'ZDD enumeration limit', 1, 1_000_000);
    my @stack = ([$root, []]);
    my @sets;
    while (@stack) {
        my ($id, $set) = @{pop @stack};
        next if $id == 0;
        if ($id == 1) {
            die "ZDD enumeration limit exceeded\n" if @sets >= $limit;
            push @sets, $set;
            next;
        }
        my ($rank, $low, $high) = @{$self->{nodes}[$id]};
        push @stack, [$high, [@$set, $self->{variables}[$rank]]], [$low, [@$set]];
    }
    return \@sets;
}

sub from_sets {
    my ($self, $sets) = @_;
    my $root = 0;
    $root = $self->union($root, $self->singleton($_)) for @$sets;
    return $root;
}

sub assert_invariants {
    my ($self) = @_;
    my %seen;
    for my $id (2 .. $#{$self->{nodes}}) {
        my ($rank, $low, $high) = @{$self->{nodes}[$id]};
        die "ZDD zero suppression violated\n" if $high == 0;
        die "ZDD acyclic order violated\n" if $low >= $id || $high >= $id;
        die "ZDD rank order violated\n" if $self->{nodes}[$low][0] <= $rank
            || $self->{nodes}[$high][0] <= $rank;
        die "ZDD duplicate node\n" if $seen{"$rank,$low,$high"}++;
    }
    return 1;
}

1;
