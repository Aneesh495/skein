package Skein::Generate;
use 5.020;
use strict;
use warnings;
use Skein::RNG;
use Skein::Model;
use Skein::Expr qw(const var op);
use Skein::Util qw(integer);

sub new {
    my ($class, %options) = @_;
    return bless {rng => Skein::RNG->new($options{seed} // 'skein.generate/1'),
        seed => $options{seed} // 'skein.generate/1', sequence => 0}, $class;
}

sub shuffle {
    my ($self, $items) = @_;
    my @copy = @$items;
    for (my $i = $#copy; $i > 0; --$i) {
        my $j = $self->{rng}->integer($i + 1);
        @copy[$i,$j] = @copy[$j,$i];
    }
    return \@copy;
}

sub _leaf {
    my ($self, $names) = @_;
    return const($self->{rng}->integer(2)) if !@$names || !$self->{rng}->integer(8);
    return var($names->[$self->{rng}->integer(scalar @$names)]);
}

sub expression {
    my ($self, $names, $depth) = @_;
    $depth //= 2;
    integer($depth, 'generator depth', 0, 4);
    return $self->_leaf($names) if !$depth || !$self->{rng}->integer(4);
    my @operators = qw(not and or xor implies eq ite atleast exactly);
    my $operator = $operators[$self->{rng}->integer(scalar @operators)];
    my %arity = (not => 1, and => 2, or => 2, xor => 2, implies => 2, eq => 2, ite => 3);
    my $count = $arity{$operator} // $self->{rng}->integer(5);
    my @arguments = map { $self->expression($names, $depth - 1) } 1 .. $count;
    return op($operator, $self->{rng}->integer($count + 1), @arguments)
        if $operator eq 'atleast' || $operator eq 'exactly';
    return op($operator, @arguments);
}

sub model {
    my ($self, %options) = @_;
    my $noise_count = integer($options{noise} // (1 + $self->{rng}->integer(6)),
        'generator noises', 0, 12);
    my $node_count = integer($options{nodes} // (2 + $self->{rng}->integer(7)),
        'generator nodes', 1, 32);
    my $depth = integer($options{depth} // 2, 'generator depth', 0, 4);
    my @probabilities = qw(0 1 1/2 1/3 2/3 1/10 9/10 17/31);
    my @noise;
    my @names;
    for my $i (0 .. $noise_count - 1) {
        my $name = "u$i";
        push @noise, {name => $name, p => $probabilities[$self->{rng}->integer(scalar @probabilities)]};
        push @names, $name;
    }
    my @nodes;
    for my $i (0 .. $node_count - 1) {
        my $name = "n$i";
        push @nodes, {name => $name, expr => $self->expression(\@names, $depth)};
        push @names, $name;
    }
    my @queries = ({name => 'baseline', event => var($nodes[-1]{name})});
    push @queries, {name => 'observation', event => $self->expression(\@names, 1),
        evidence => $self->expression(\@names, 1)};
    my $target = $nodes[$self->{rng}->integer(scalar @nodes)]{name};
    my %interventions = ($target => $self->{rng}->integer(2));
    push @queries, {name => 'counterfactual', event => $self->expression(\@names, 1),
        factual => $self->expression(\@names, 1), interventions => {%interventions}};
    push @queries, {name => 'mixed', event => $self->expression(\@names, 1),
        evidence => $self->expression(\@names, 1), factual => $self->expression(\@names, 1),
        interventions => {%interventions}};
    push @queries, {name => 'impossible', event => const(1), evidence => const(0)};
    my @repairs;
    my @sensors;
    for my $i (0 .. ($node_count < 3 ? $node_count : 3) - 1) {
        push @repairs, {name => "fix$i", node => $nodes[$i]{name}, value => 0, cost => 1+$i};
        push @sensors, {name => "read$i", expr => var($nodes[$i]{name}), cost => 1};
    }
    my %intervals = map { $_->{name} => ['0','1'] } @noise;
    return Skein::Model->new({name => 'generated_' . $self->{sequence}++,
        title => 'Deterministic differential case', noise => \@noise, nodes => \@nodes,
        queries => \@queries, repairs => \@repairs, sensors => \@sensors,
        intervals => \%intervals, order => $self->shuffle([map { $_->{name} } @noise])});
}

sub truth_table {
    my ($self, $variables) = @_;
    integer($variables, 'truth table variables', 0, 12);
    return [map { $self->{rng}->integer(2) } 1 .. 2 ** $variables];
}

sub network {
    my ($self, %options) = @_;
    my $vertices = integer($options{vertices} // 5, 'generated vertices', 2, 12);
    my $density = $options{density} // '1/3';
    my @edges;
    for my $from (0 .. $vertices - 2) {
        for my $to ($from + 1 .. $vertices - 1) {
            next unless $to == $from + 1 || $self->{rng}->bernoulli($density);
            push @edges, {name => 'e' . scalar(@edges), from => "v$from", to => "v$to", p => '1/10'};
        }
    }
    return {name => 'generated_network', vertices => [map { "v$_" } 0 .. $vertices - 1],
        edges => \@edges, source => 'v0', target => 'v' . ($vertices - 1), directed => 0};
}

1;
