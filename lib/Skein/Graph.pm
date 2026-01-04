package Skein::Graph;
use 5.020;
use strict;
use warnings;
use Skein::Util qw(identifier);

sub new {
    my ($class, $nodes, $edges) = @_;
    my $self = bless { parents => {}, children => {} }, $class;
    $self->add_node($_) for @{$nodes // []};
    $self->add_edge(@$_) for @{$edges // []};
    return $self;
}

sub add_node {
    my ($self, $name) = @_;
    identifier($name, 'graph node');
    $self->{parents}{$name} //= {};
    $self->{children}{$name} //= {};
    return $self;
}

sub add_edge {
    my ($self, $from, $to) = @_;
    $self->add_node($from);
    $self->add_node($to);
    $self->{children}{$from}{$to} = 1;
    $self->{parents}{$to}{$from} = 1;
    return $self;
}

sub nodes { return [sort keys %{$_[0]{parents}}] }

sub _require {
    my ($self, $name) = @_;
    die "unknown graph node '$name'\n" unless exists $self->{parents}{$name};
    return;
}

sub parents {
    my ($self, $name) = @_;
    $self->_require($name);
    return [sort keys %{$self->{parents}{$name}}];
}

sub children {
    my ($self, $name) = @_;
    $self->_require($name);
    return [sort keys %{$self->{children}{$name}}];
}

sub edges {
    my ($self) = @_;
    my @edges;
    for my $from (@{$self->nodes}) {
        push @edges, map { [$from, $_] } @{$self->children($from)};
    }
    return \@edges;
}

sub clone {
    my ($self) = @_;
    return ref($self)->new($self->nodes, $self->edges);
}

sub topological {
    my ($self) = @_;
    my %degree = map { $_ => scalar @{$self->parents($_)} } @{$self->nodes};
    my @ready = sort grep { $degree{$_} == 0 } keys %degree;
    my @order;
    while (@ready) {
        my $next = shift @ready;
        push @order, $next;
        for my $child (@{$self->children($next)}) {
            push @ready, $child if --$degree{$child} == 0;
        }
        @ready = sort @ready;
    }
    if (@order != keys %degree) {
        my @blocked = sort grep { $degree{$_} > 0 } keys %degree;
        die 'structural cycle involving ' . join(', ', @blocked) . "\n";
    }
    return \@order;
}

sub closure {
    my ($self, $starts, $direction) = @_;
    die "invalid graph direction\n" unless $direction eq 'parents'
        || $direction eq 'children';
    $self->_require($_) for @$starts;
    my %seen;
    my @queue = @$starts;
    while (@queue) {
        my $current = shift @queue;
        next if $seen{$current}++;
        push @queue, sort keys %{$self->{$direction}{$current}};
    }
    return [sort keys %seen];
}

sub ancestors { return $_[0]->closure($_[1], 'parents') }
sub descendants { return $_[0]->closure($_[1], 'children') }

sub induced {
    my ($self, $names) = @_;
    $self->_require($_) for @$names;
    my %keep = map { $_ => 1 } @$names;
    my @edges = grep { $keep{$_->[0]} && $keep{$_->[1]} } @{$self->edges};
    return ref($self)->new($names, \@edges);
}

sub intervene {
    my ($self, $names) = @_;
    $self->_require($_) for @$names;
    my %cut = map { $_ => 1 } @$names;
    my @edges = grep { !$cut{$_->[1]} } @{$self->edges};
    return ref($self)->new($self->nodes, \@edges);
}

sub moral {
    my ($self) = @_;
    my %adj = map { $_ => {} } @{$self->nodes};
    for my $node (@{$self->nodes}) {
        my @parents = @{$self->parents($node)};
        for my $parent (@parents) {
            $adj{$node}{$parent} = 1;
            $adj{$parent}{$node} = 1;
        }
        for my $i (0 .. $#parents) {
            for my $j ($i + 1 .. $#parents) {
                $adj{$parents[$i]}{$parents[$j]} = 1;
                $adj{$parents[$j]}{$parents[$i]} = 1;
            }
        }
    }
    return \%adj;
}

sub d_separated {
    my ($self, $left, $right, $given) = @_;
    $self->topological;
    $self->_require($_) for (@$left, @$right, @$given);
    my %blocked = map { $_ => 1 } @$given;
    die "separation sets overlap evidence\n"
        if grep { $blocked{$_} } (@$left, @$right);
    my %target = map { $_ => 1 } @$right;
    my $relevant = $self->ancestors([@$left, @$right, @$given]);
    my $moral = $self->induced($relevant)->moral;
    my %seen;
    my @queue = @$left;
    while (@queue) {
        my $node = shift @queue;
        next if $blocked{$node} || $seen{$node}++;
        return 0 if $target{$node};
        push @queue, sort keys %{$moral->{$node}};
    }
    return 1;
}

sub shortest_path {
    my ($self, $from, $to) = @_;
    $self->_require($from);
    $self->_require($to);
    my %previous = ($from => undef);
    my @queue = ($from);
    while (@queue) {
        my $node = shift @queue;
        if ($node eq $to) {
            my @path;
            while (defined $node) {
                unshift @path, $node;
                $node = $previous{$node};
            }
            return \@path;
        }
        for my $child (@{$self->children($node)}) {
            next if exists $previous{$child};
            $previous{$child} = $node;
            push @queue, $child;
        }
    }
    return undef;
}

sub transitive_reduction {
    my ($self) = @_;
    $self->topological;
    my $reduced = $self->clone;
    for my $edge (@{$self->edges}) {
        my ($from, $to) = @$edge;
        delete $reduced->{children}{$from}{$to};
        delete $reduced->{parents}{$to}{$from};
        $reduced->add_edge($from, $to)
            unless $reduced->shortest_path($from, $to);
    }
    return $reduced;
}

sub components {
    my ($self) = @_;
    my %seen;
    my @result;
    for my $start (@{$self->nodes}) {
        next if $seen{$start};
        my @queue = ($start);
        my @component;
        while (@queue) {
            my $node = shift @queue;
            next if $seen{$node}++;
            push @component, $node;
            push @queue, @{$self->parents($node)}, @{$self->children($node)};
        }
        push @result, [sort @component];
    }
    return \@result;
}

sub min_fill_order {
    my ($class, $scopes, $eliminate) = @_;
    my %adj;
    for my $scope (@$scopes) {
        $adj{$_} //= {} for @$scope;
        for my $i (0 .. $#$scope) {
            for my $j ($i + 1 .. $#$scope) {
                $adj{$scope->[$i]}{$scope->[$j]} = 1;
                $adj{$scope->[$j]}{$scope->[$i]} = 1;
            }
        }
    }
    my %remaining = map { $_ => 1 } @$eliminate;
    $adj{$_} //= {} for @$eliminate;
    my @order;
    my $width = 0;
    while (%remaining) {
        my %score;
        for my $node (keys %remaining) {
            my @neighbors = sort keys %{$adj{$node}};
            my $fill = 0;
            for my $i (0 .. $#neighbors) {
                for my $j ($i + 1 .. $#neighbors) {
                    ++$fill unless $adj{$neighbors[$i]}{$neighbors[$j]};
                }
            }
            $score{$node} = [$fill, scalar @neighbors];
        }
        my ($next) = sort {
            $score{$a}[0] <=> $score{$b}[0]
                || $score{$a}[1] <=> $score{$b}[1] || $a cmp $b
        } keys %remaining;
        my @neighbors = sort keys %{$adj{$next}};
        $width = @neighbors if @neighbors > $width;
        for my $a (@neighbors) {
            for my $b (@neighbors) {
                $adj{$a}{$b} = 1 unless $a eq $b;
            }
            delete $adj{$a}{$next};
        }
        delete $adj{$next};
        delete $remaining{$next};
        push @order, $next;
    }
    return { order => \@order, induced_width => $width };
}

1;
