package Skein::Eliminate;
use 5.020;
use strict;
use warnings;
use Skein::Factor;
use Skein::Graph;
use Skein::Expr qw(const);
use Skein::Rat qw(probability complement divr text is_zero);
use Skein::Util qw(integer canonical_json deep_copy);

sub new {
    my ($class, $model, %options) = @_;
    return bless {
        model => $model,
        max_rows => integer($options{max_rows} // 250_000, 'elimination row limit', 1, 2_000_000),
        max_ops => integer($options{max_ops} // 2_000_000, 'elimination operation limit', 1, 20_000_000),
        max_gates => integer($options{max_gates} // 20_000, 'elimination gate limit', 1, 200_000),
    }, $class;
}

sub _options {
    my ($self) = @_;
    return (max_rows => $self->{max_rows}, max_ops => $self->{max_ops});
}

sub _gate {
    my ($self, $circuit, $operator, $inputs, $value) = @_;
    my $key = canonical_json([$operator, $inputs, $value]);
    return $circuit->{gate_cache}{$key} if exists $circuit->{gate_cache}{$key};
    die "elimination gate limit exceeded\n" if $circuit->{next_gate} >= $self->{max_gates};
    my $output = 'g_' . $circuit->{next_gate}++;
    my %scope = map { $_ => 1 } (@$inputs, $output);
    my @scope = sort keys %scope;
    my $factor = Skein::Factor->from_function(\@scope, sub {
        my ($assignment) = @_;
        my @bits = map { $assignment->{$_} } @$inputs;
        my $expected;
        if ($operator eq 'const') { $expected = $value }
        elsif ($operator eq 'not') { $expected = 1 - $bits[0] }
        elsif ($operator eq 'and') { $expected = $bits[0] && $bits[1] ? 1 : 0 }
        elsif ($operator eq 'or') { $expected = $bits[0] || $bits[1] ? 1 : 0 }
        elsif ($operator eq 'xor') { $expected = $bits[0] != $bits[1] ? 1 : 0 }
        elsif ($operator eq 'eq') { $expected = $bits[0] == $bits[1] ? 1 : 0 }
        elsif ($operator eq 'implies') { $expected = !$bits[0] || $bits[1] ? 1 : 0 }
        elsif ($operator eq 'ite') { $expected = $bits[0] ? $bits[1] : $bits[2] }
        else { die "unknown elimination gate '$operator'\n" }
        return $assignment->{$output} == $expected ? 1 : 0;
    }, $self->_options);
    push @{$circuit->{factors}}, $factor;
    $circuit->{gate_cache}{$key} = $output;
    return $output;
}

sub _expression {
    my ($self, $circuit, $expr, $environment) = @_;
    my $operator = $expr->{op};
    return $environment->{$expr->{name}} if $operator eq 'var';
    return $self->_gate($circuit, 'const', [], $expr->{value}) if $operator eq 'const';
    my @inputs = map { $self->_expression($circuit, $_, $environment) } @{$expr->{args}};
    if ($operator eq 'atleast' || $operator eq 'exactly') {
        my $k = $expr->{k};
        my $maximum = $operator eq 'exactly' ? $k + 1 : $k;
        my $true = $self->_gate($circuit, 'const', [], 1);
        my $false = $self->_gate($circuit, 'const', [], 0);
        my @states = ($true, ($false) x $maximum);
        my $processed = 0;
        for my $input (@inputs) {
            ++$processed;
            my $top = $processed < $maximum ? $processed : $maximum;
            for (my $j = $top; $j >= 1; --$j) {
                $states[$j] = $self->_gate($circuit, 'ite', [$input, $states[$j - 1], $states[$j]], undef);
            }
        }
        return $states[$k] if $operator eq 'atleast';
        my $not_next = $self->_gate($circuit, 'not', [$states[$k + 1]], undef);
        return $self->_gate($circuit, 'and', [$states[$k], $not_next], undef);
    }
    return $self->_gate($circuit, $operator, \@inputs, undef);
}

sub _world {
    my ($self, $circuit, $interventions) = @_;
    my $key = canonical_json($interventions);
    return $circuit->{worlds}{$key} if exists $circuit->{worlds}{$key};
    my %environment = %{$circuit->{noise_variables}};
    for my $name (@{$self->{model}->node_order}) {
        $environment{$name} = exists($interventions->{$name})
            ? $self->_gate($circuit, 'const', [], $interventions->{$name})
            : $self->_expression($circuit, $self->{model}->equation($name), \%environment);
    }
    $circuit->{worlds}{$key} = \%environment;
    return \%environment;
}

sub _circuit {
    my ($self, $query, $priors) = @_;
    my $circuit = {factors => [], worlds => {}, gate_cache => {}, noise_variables => {}, next_gate => 0};
    my $names = $self->{model}->noise_names;
    die "elimination priors must match noise variables\n" unless ref($priors) eq 'HASH' && keys(%$priors) == @$names;
    my $noise_index = 0;
    for my $name (@$names) {
        die "missing elimination prior '$name'\n" unless exists $priors->{$name};
        my $p = probability($priors->{$name});
        my $variable = 'u_' . $noise_index++;
        $circuit->{noise_variables}{$name} = $variable;
        push @{$circuit->{factors}}, Skein::Factor->new([$variable],
            {'0' => complement($p), '1' => $p}, $self->_options);
    }
    my $target_world = $self->_world($circuit, $query->{interventions});
    my $factual_world = $self->_world($circuit, {});
    $circuit->{event} = $self->_expression($circuit, $query->{event}, $target_world);
    $circuit->{evidence} = $self->_expression($circuit, $query->{evidence} // const(1), $target_world);
    $circuit->{factual} = $self->_expression($circuit, $query->{factual} // const(1), $factual_world);
    return $circuit;
}

sub partition {
    my ($self, $factors, %options) = @_;
    my %variables;
    $variables{$_} = 1 for map { @{$_->variables} } @$factors;
    my $ordering = Skein::Graph->min_fill_order([map { $_->variables } @$factors], [sort keys %variables]);
    my $order = $options{order} // $ordering->{order};
    my %rank;
    for my $i (0 .. $#$order) {
        die "invalid elimination order\n" unless $variables{$order->[$i]} && !exists $rank{$order->[$i]};
        $rank{$order->[$i]} = $i;
    }
    die "incomplete elimination order\n" unless @$order == keys %variables;
    my @buckets = map { [] } @$order;
    my $scalar = Skein::Factor->scalar_factor(1, $self->_options);
    my $place = sub {
        my ($factor) = @_;
        my @scope = @{$factor->variables};
        if (!@scope) {
            $scalar = $scalar->multiply($factor);
            return;
        }
        my ($first) = sort { $rank{$a} <=> $rank{$b} } @scope;
        push @{$buckets[$rank{$first}]}, $factor;
    };
    $place->($_) for @$factors;
    my @trace;
    my $peak_rows = 0;
    for my $i (0 .. $#$order) {
        my @bucket = sort { $a->row_count <=> $b->row_count
            || @{$a->variables} <=> @{$b->variables} } @{$buckets[$i]};
        next unless @bucket;
        my $joined = shift @bucket;
        my $input_count = 1 + @bucket;
        for my $factor (@bucket) {
            $joined = $joined->multiply($factor);
            $peak_rows = $joined->row_count if $joined->row_count > $peak_rows;
        }
        $peak_rows = $joined->row_count if $joined->row_count > $peak_rows;
        my $reduced = $joined->sum_out($order->[$i]);
        push @trace, {variable => $order->[$i], input_factors => $input_count,
            joined_rows => $joined->row_count, output_rows => $reduced->row_count,
            scope_width => scalar @{$joined->variables}};
        $buckets[$i] = [];
        $place->($reduced);
    }
    return {mass => $scalar->total, order => [@$order], trace => \@trace,
        peak_rows => $peak_rows, induced_width => $ordering->{induced_width}};
}

sub solve {
    my ($self, $input, %options) = @_;
    $input = $self->{model}->query($input) unless ref($input);
    my $query = deep_copy($input);
    $self->{model}->validate_query($query);
    my $circuit = $self->_circuit($query, $options{priors} // $self->{model}->priors);
    my @base = @{$circuit->{factors}};
    push @base, Skein::Factor->new([$circuit->{evidence}], {'1' => 1}, $self->_options);
    push @base, Skein::Factor->new([$circuit->{factual}], {'1' => 1}, $self->_options);
    my $denominator = $self->partition(\@base);
    die "impossible evidence: probability is zero\n" if is_zero($denominator->{mass});
    my $event = Skein::Factor->new([$circuit->{event}], {'1' => 1}, $self->_options);
    my $numerator = $self->partition([@base, $event]);
    return {probability => text(divr($numerator->{mass}, $denominator->{mass})),
        numerator => text($numerator->{mass}), denominator => text($denominator->{mass}),
        gates => $circuit->{next_gate}, factors => scalar @base + 1,
        numerator_trace => $numerator->{trace}, denominator_trace => $denominator->{trace},
        peak_rows => $numerator->{peak_rows} > $denominator->{peak_rows}
            ? $numerator->{peak_rows} : $denominator->{peak_rows}};
}

1;
