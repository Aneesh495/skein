package Skein::Compiler;
use 5.020;
use strict;
use warnings;
use Skein::BDD;
use Skein::Expr qw(const fingerprint);
use Skein::Util qw(canonical_json deep_copy);

sub new {
    my ($class, $model, %options) = @_;
    die "compiler requires a structural model\n" unless ref($model) && $model->isa('Skein::Model');
    my $order = delete($options{order}) // $model->order;
    die "compiler order must be an array\n" unless ref($order) eq 'ARRAY';
    my %noise = map { $_ => 1 } @{$model->noise_names};
    my %seen;
    for my $name (@$order) {
        die "invalid compiler variable order\n" unless $noise{$name} && !$seen{$name}++;
    }
    die "incomplete compiler variable order\n" unless @$order == keys %noise;
    my $self = bless {
        model => $model, bdd => Skein::BDD->new($order, %options),
        worlds => {}, expression_cache => {}, max_worlds => 4096,
        compiled_expressions => 0,
    }, $class;
    return $self;
}

sub bdd { return $_[0]{bdd} }
sub model { return $_[0]{model} }

sub _expression {
    my ($self, $expr, $environment) = @_;
    my $operator = $expr->{op};
    return $expr->{value} if $operator eq 'const';
    if ($operator eq 'var') {
        die "uncompiled variable '$expr->{name}'\n" unless exists $environment->{$expr->{name}};
        return $environment->{$expr->{name}};
    }
    my @roots = map { $self->_expression($_, $environment) } @{$expr->{args}};
    my $bdd = $self->{bdd};
    return $bdd->negate($roots[0]) if $operator eq 'not';
    return $bdd->ite(@roots) if $operator eq 'ite';
    return $bdd->threshold(\@roots, $expr->{k}, $operator eq 'exactly' ? 1 : 0)
        if $operator eq 'atleast' || $operator eq 'exactly';
    return $bdd->apply($operator, @roots);
}

sub world {
    my ($self, $interventions) = @_;
    $interventions //= {};
    $self->{model}->validate_interventions($interventions);
    my $key = canonical_json($interventions);
    return {%{$self->{worlds}{$key}}} if exists $self->{worlds}{$key};
    die "compiled world limit exceeded\n" if keys(%{$self->{worlds}}) >= $self->{max_worlds};
    my %environment;
    for my $name (@{$self->{model}->noise_names}) {
        $environment{$name} = $self->{bdd}->variable($name);
    }
    for my $name (@{$self->{model}->node_order}) {
        $environment{$name} = exists($interventions->{$name})
            ? 0 + $interventions->{$name}
            : $self->_expression($self->{model}->equation($name), \%environment);
    }
    $self->{worlds}{$key} = \%environment;
    return {%environment};
}

sub expression {
    my ($self, $expr, $interventions) = @_;
    $interventions //= {};
    $self->{model}->validate_expression($expr);
    $self->{model}->validate_interventions($interventions);
    my $key = canonical_json([$interventions, $expr]);
    return $self->{expression_cache}{$key} if exists $self->{expression_cache}{$key};
    my $root = $self->_expression($expr, $self->world($interventions));
    ++$self->{compiled_expressions};
    $self->{expression_cache}{$key} = $root;
    return $root;
}

sub query {
    my ($self, $input) = @_;
    my $query = deep_copy($input);
    $self->{model}->validate_query($query);
    my $interventions = $query->{interventions};
    my $event = $self->expression($query->{event}, $interventions);
    my $evidence = $self->expression($query->{evidence} // const(1), $interventions);
    my $factual = $self->expression($query->{factual} // const(1), {});
    my $denominator = $self->{bdd}->apply('and', $evidence, $factual);
    my $numerator = $self->{bdd}->apply('and', $event, $denominator);
    return { event => $event, evidence => $evidence, factual => $factual,
        numerator => $numerator, denominator => $denominator, query => $query };
}

sub joint_worlds {
    my ($self, $events, $factual) = @_;
    die "joint worlds must be an array\n" unless ref($events) eq 'ARRAY';
    my $root = 1;
    for my $event (@$events) {
        die "joint world event must be an object\n" unless ref($event) eq 'HASH';
        my $part = $self->expression($event->{event}, $event->{interventions} // {});
        $root = $self->{bdd}->apply('and', $root, $part);
    }
    my $evidence = $self->expression($factual // const(1), {});
    return { numerator => $self->{bdd}->apply('and', $root, $evidence), denominator => $evidence };
}

sub stats {
    my ($self) = @_;
    return { %{$self->{bdd}->stats}, worlds => scalar keys %{$self->{worlds}},
        compiled_expressions => $self->{compiled_expressions} };
}

1;
