package Skein::Expr;
use 5.020;
use strict;
use warnings;
no warnings 'recursion';
use Exporter 'import';
use Skein::Util qw(identifier integer boolean check_keys canonical_json deep_copy);

our @EXPORT_OK = qw(const var op validate evaluate support render substitute
    simplify size fingerprint);

my %ARITY = (not => 1, and => 2, or => 2, xor => 2, implies => 2,
    eq => 2, ite => 3);

sub const { return { op => 'const', value => boolean($_[0]) } }
sub var { return { op => 'var', name => identifier($_[0]) } }

sub op {
    my ($operator, @arguments) = @_;
    my $result;
    if ($operator eq 'atleast' || $operator eq 'exactly') {
        my $k = shift @arguments;
        $result = { op => $operator, k => $k, args => \@arguments };
    } else {
        $result = { op => $operator, args => \@arguments };
    }
    validate($result);
    return $result;
}

sub validate {
    my ($root, $max_nodes, $max_depth) = @_;
    $max_nodes //= 100_000;
    $max_depth //= 128;
    my $count = 0;
    my $walk;
    $walk = sub {
        my ($node, $depth) = @_;
        die "expression exceeds depth limit\n" if $depth > $max_depth;
        die "expression exceeds node limit\n" if ++$count > $max_nodes;
        die "expression must be an object\n" unless ref($node) eq 'HASH';
        my $operator = $node->{op};
        die "expression operator missing\n" unless defined($operator) && !ref($operator);
        if ($operator eq 'const') {
            check_keys($node, [qw(op value)], [qw(op value)], 'constant');
            boolean($node->{value});
        } elsif ($operator eq 'var') {
            check_keys($node, [qw(op name)], [qw(op name)], 'variable');
            identifier($node->{name});
        } else {
            die "unknown Boolean operator '$operator'\n"
                unless exists($ARITY{$operator}) || $operator eq 'atleast'
                || $operator eq 'exactly';
            my @keys = qw(op args);
            push @keys, 'k' if $operator eq 'atleast' || $operator eq 'exactly';
            check_keys($node, \@keys, \@keys, 'expression');
            die "expression arguments must be an array\n" unless ref($node->{args}) eq 'ARRAY';
            if (exists $ARITY{$operator}) {
                die "wrong arity for '$operator'\n"
                    unless @{$node->{args}} == $ARITY{$operator};
            } else {
                integer($node->{k}, 'threshold', 0, scalar @{$node->{args}});
                die "threshold has too many arguments\n" if @{$node->{args}} > 4096;
            }
            $walk->($_, $depth + 1) for @{$node->{args}};
        }
    };
    $walk->($root, 0);
    return $root;
}

sub evaluate {
    my ($node, $values) = @_;
    my $operator = $node->{op};
    return $node->{value} if $operator eq 'const';
    if ($operator eq 'var') {
        die "missing value for '$node->{name}'\n" unless exists $values->{$node->{name}};
        return boolean($values->{$node->{name}});
    }
    my @values = map { evaluate($_, $values) } @{$node->{args}};
    return 1 - $values[0] if $operator eq 'not';
    return ($values[0] && $values[1]) ? 1 : 0 if $operator eq 'and';
    return ($values[0] || $values[1]) ? 1 : 0 if $operator eq 'or';
    return ($values[0] != $values[1]) ? 1 : 0 if $operator eq 'xor';
    return (!$values[0] || $values[1]) ? 1 : 0 if $operator eq 'implies';
    return ($values[0] == $values[1]) ? 1 : 0 if $operator eq 'eq';
    return $values[0] ? $values[1] : $values[2] if $operator eq 'ite';
    if ($operator eq 'atleast' || $operator eq 'exactly') {
        my $count = 0;
        $count += $_ for @values;
        return $operator eq 'atleast'
            ? ($count >= $node->{k} ? 1 : 0)
            : ($count == $node->{k} ? 1 : 0);
    }
    die "unknown Boolean operator '$operator'\n";
}

sub support {
    my ($root) = @_;
    my %names;
    my @stack = ($root);
    while (@stack) {
        my $node = pop @stack;
        if ($node->{op} eq 'var') {
            $names{$node->{name}} = 1;
        } elsif ($node->{args}) {
            push @stack, @{$node->{args}};
        }
    }
    return [sort keys %names];
}

sub size {
    my ($root) = @_;
    my $count = 0;
    my @stack = ($root);
    while (@stack) {
        my $node = pop @stack;
        ++$count;
        push @stack, @{$node->{args}} if $node->{args};
    }
    return $count;
}

sub fingerprint { return canonical_json($_[0]) }

sub render {
    my ($node) = @_;
    my $operator = $node->{op};
    return "$node->{value}" if $operator eq 'const';
    return $node->{name} if $operator eq 'var';
    my @parts = map { render($_) } @{$node->{args}};
    return '!(' . $parts[0] . ')' if $operator eq 'not';
    my %symbol = (and => '&', or => '|', xor => '^', implies => '->', eq => '<->');
    return '(' . join(' ' . $symbol{$operator} . ' ', @parts) . ')'
        if exists $symbol{$operator};
    unshift @parts, $node->{k} if exists $node->{k};
    return $operator . '(' . join(', ', @parts) . ')';
}

sub substitute {
    my ($node, $mapping) = @_;
    if ($node->{op} eq 'var' && exists $mapping->{$node->{name}}) {
        my $replacement = $mapping->{$node->{name}};
        validate($replacement);
        return deep_copy($replacement);
    }
    return deep_copy($node) unless $node->{args};
    my %result = %$node;
    $result{args} = [map { substitute($_, $mapping) } @{$node->{args}}];
    return \%result;
}

sub simplify {
    my ($node) = @_;
    return deep_copy($node) unless $node->{args};
    my $operator = $node->{op};
    my @args = map { simplify($_) } @{$node->{args}};
    my %result = (%$node, args => \@args);
    if (!grep { $_->{op} ne 'const' } @args) {
        return const(evaluate(\%result, {}));
    }
    if ($operator eq 'not' && $args[0]{op} eq 'not') {
        return $args[0]{args}[0];
    }
    if ($operator eq 'and' || $operator eq 'or') {
        my $identity = $operator eq 'and' ? 1 : 0;
        for my $index (0, 1) {
            if ($args[$index]{op} eq 'const') {
                return $args[1 - $index] if $args[$index]{value} == $identity;
                return const(1 - $identity);
            }
        }
        return $args[0] if fingerprint($args[0]) eq fingerprint($args[1]);
    }
    if ($operator eq 'xor' || $operator eq 'eq') {
        return const($operator eq 'eq' ? 1 : 0)
            if fingerprint($args[0]) eq fingerprint($args[1]);
    }
    if ($operator eq 'ite') {
        return $args[0]{value} ? $args[1] : $args[2] if $args[0]{op} eq 'const';
        return $args[1] if fingerprint($args[1]) eq fingerprint($args[2]);
    }
    return \%result;
}

1;
