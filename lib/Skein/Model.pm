package Skein::Model;
use 5.020;
use strict;
use warnings;
use Skein::Parser;
use Skein::Expr qw(validate support evaluate const);
use Skein::Graph;
use Skein::Rat qw(probability text compare mul complement one);
use Skein::Util qw(check_keys identifier integer boolean deep_copy read_text);

sub from_text {
    my ($class, $source, %options) = @_;
    return $class->new(Skein::Parser->parse($source, %options));
}

sub from_file {
    my ($class, $path) = @_;
    return $class->from_text(read_text($path), name => $path);
}

sub new {
    my ($class, $input) = @_;
    check_keys($input, [qw(schema name title noise nodes queries repairs sensors intervals order)],
        [qw(noise nodes)], 'model');
    my $raw = deep_copy($input);
    $raw->{schema} //= 'skein.model/1';
    die "unsupported model schema\n" unless $raw->{schema} eq 'skein.model/1';
    $raw->{name} //= 'untitled';
    identifier($raw->{name}, 'model name');
    die "invalid model title\n" if exists($raw->{title}) && !defined($raw->{title});
    $raw->{title} //= '';
    die "invalid model title\n" if ref($raw->{title}) || length($raw->{title}) > 4096;
    $raw->{queries} //= [];
    $raw->{repairs} //= [];
    $raw->{sensors} //= [];
    $raw->{intervals} //= {};
    for my $list (qw(noise nodes queries repairs sensors)) {
        die "$list must be an array\n" unless ref($raw->{$list}) eq 'ARRAY';
        die "$list exceeds model size limit\n" if @{$raw->{$list}} > 4096;
    }
    my $self = bless {
        raw => $raw, noise => {}, nodes => {}, queries => {}, repairs => {},
        graph => Skein::Graph->new,
    }, $class;
    my %names;
    for my $noise (@{$raw->{noise}}) {
        check_keys($noise, [qw(name p)], [qw(name p)], 'noise');
        my $name = identifier($noise->{name}, 'noise name');
        die "duplicate variable '$name'\n" if $names{$name}++;
        $noise->{p} = text(probability($noise->{p}));
        $self->{noise}{$name} = $noise->{p};
        $self->{graph}->add_node($name);
    }
    for my $node (@{$raw->{nodes}}) {
        check_keys($node, [qw(name expr)], [qw(name expr)], 'node');
        my $name = identifier($node->{name}, 'node name');
        die "duplicate variable '$name'\n" if $names{$name}++;
        validate($node->{expr});
        $self->{nodes}{$name} = $node->{expr};
        $self->{graph}->add_node($name);
    }
    for my $name (sort keys %{$self->{nodes}}) {
        for my $parent (@{support($self->{nodes}{$name})}) {
            die "node '$name' refers to unknown variable '$parent'\n" unless $names{$parent};
            $self->{graph}->add_edge($parent, $name);
        }
    }
    $self->{topological} = $self->{graph}->topological;
    $self->{node_order} = [grep { exists $self->{nodes}{$_} } @{$self->{topological}}];
    if (exists $raw->{order}) {
        die "order must be an array\n" unless ref($raw->{order}) eq 'ARRAY';
        my %seen;
        for my $name (@{$raw->{order}}) {
            identifier($name, 'order variable');
            die "order includes non-noise variable '$name'\n" unless exists $self->{noise}{$name};
            die "duplicate order variable '$name'\n" if $seen{$name}++;
        }
        die "order must include every noise variable\n" unless keys(%seen) == keys(%{$self->{noise}});
    } else {
        $raw->{order} = [sort keys %{$self->{noise}}];
    }
    for my $query (@{$raw->{queries}}) {
        $self->validate_query($query);
        my $name = identifier($query->{name}, 'query name');
        die "duplicate query '$name'\n" if exists $self->{queries}{$name};
        $self->{queries}{$name} = $query;
    }
    for my $repair (@{$raw->{repairs}}) {
        check_keys($repair, [qw(name node value cost)], [qw(name node value cost)], 'repair');
        my $name = identifier($repair->{name}, 'repair name');
        die "duplicate repair '$name'\n" if exists $self->{repairs}{$name};
        die "repair target must be an endogenous node\n" unless exists $self->{nodes}{$repair->{node}};
        $repair->{value} = boolean($repair->{value});
        $repair->{cost} = integer($repair->{cost}, 'repair cost', 0, 1_000_000);
        $self->{repairs}{$name} = $repair;
    }
    my %sensor_names;
    for my $sensor (@{$raw->{sensors}}) {
        check_keys($sensor, [qw(name expr cost)], [qw(name expr cost)], 'sensor');
        my $name = identifier($sensor->{name}, 'sensor name');
        die "duplicate sensor '$name'\n" if $sensor_names{$name}++;
        $self->validate_expression($sensor->{expr});
        $sensor->{cost} = integer($sensor->{cost}, 'sensor cost', 0, 1_000_000);
    }
    die "intervals must be an object\n" unless ref($raw->{intervals}) eq 'HASH';
    for my $name (sort keys %{$raw->{intervals}}) {
        die "interval refers to unknown noise '$name'\n" unless exists $self->{noise}{$name};
        my $bounds = $raw->{intervals}{$name};
        die "interval must have two endpoints\n" unless ref($bounds) eq 'ARRAY' && @$bounds == 2;
        my ($low, $high) = map { probability($_) } @$bounds;
        die "interval endpoints are reversed\n" if compare($low, $high) > 0;
        die "nominal prior is outside interval\n"
            if compare($self->{noise}{$name}, $low) < 0 || compare($self->{noise}{$name}, $high) > 0;
        $raw->{intervals}{$name} = [text($low), text($high)];
    }
    # Canonical identity does not depend on declaration order.
    for my $key (qw(noise nodes queries repairs sensors)) {
        $raw->{$key} = [sort { $a->{name} cmp $b->{name} } @{$raw->{$key}}];
    }
    $self->{digest} = Skein::Util::digest($raw);
    return $self;
}

sub validate_expression {
    my ($self, $expr) = @_;
    validate($expr);
    for my $name (@{support($expr)}) {
        die "expression refers to unknown variable '$name'\n"
            unless exists($self->{noise}{$name}) || exists($self->{nodes}{$name});
    }
    return $expr;
}

sub validate_interventions {
    my ($self, $interventions) = @_;
    die "interventions must be an object\n" unless ref($interventions) eq 'HASH';
    for my $name (sort keys %$interventions) {
        die "intervention target '$name' must be endogenous\n" unless exists $self->{nodes}{$name};
        boolean($interventions->{$name});
    }
    return $interventions;
}

sub validate_query {
    my ($self, $query) = @_;
    check_keys($query, [qw(name event evidence factual interventions)], [qw(event)], 'query');
    $self->validate_expression($query->{event});
    $self->validate_expression($query->{$_}) for grep { exists $query->{$_} } qw(evidence factual);
    $query->{interventions} //= {};
    $self->validate_interventions($query->{interventions});
    return $query;
}

sub name { return $_[0]{raw}{name} }
sub title { return $_[0]{raw}{title} }
sub digest { return $_[0]{digest} }
sub raw { return deep_copy($_[0]{raw}) }
sub noise_names { return [sort keys %{$_[0]{noise}}] }
sub node_names { return [sort keys %{$_[0]{nodes}}] }
sub order { return [@{$_[0]{raw}{order}}] }
sub node_order { return [@{$_[0]{node_order}}] }
sub graph { return $_[0]{graph}->clone }
sub priors { return {%{$_[0]{noise}}} }
sub intervals { return deep_copy($_[0]{raw}{intervals}) }
sub query_names { return [sort keys %{$_[0]{queries}}] }
sub repairs { return deep_copy($_[0]{raw}{repairs}) }
sub sensors { return deep_copy($_[0]{raw}{sensors}) }

sub equation {
    my ($self, $name) = @_;
    die "unknown node '$name'\n" unless exists $self->{nodes}{$name};
    return deep_copy($self->{nodes}{$name});
}

sub query {
    my ($self, $name) = @_;
    die "unknown query '$name'\n" unless exists $self->{queries}{$name};
    return deep_copy($self->{queries}{$name});
}

sub world {
    my ($self, $noise, $interventions) = @_;
    $interventions //= {};
    $self->validate_interventions($interventions);
    die "noise assignment must be an object\n" unless ref($noise) eq 'HASH';
    my %values;
    for my $name (@{$self->noise_names}) {
        die "missing noise '$name'\n" unless exists $noise->{$name};
        $values{$name} = boolean($noise->{$name});
    }
    die "unknown noise assignment\n" if keys(%$noise) != keys(%{$self->{noise}});
    for my $name (@{$self->{node_order}}) {
        $values{$name} = exists $interventions->{$name}
            ? boolean($interventions->{$name})
            : evaluate($self->{nodes}{$name}, \%values);
    }
    return \%values;
}

sub assignment_mass {
    my ($self, $noise, $priors) = @_;
    $priors //= $self->{noise};
    my $mass = one();
    for my $name (@{$self->noise_names}) {
        die "missing noise '$name'\n" unless exists $noise->{$name};
        my $p = probability($priors->{$name});
        $mass = mul($mass, boolean($noise->{$name}) ? $p : complement($p));
    }
    return $mass;
}

1;
