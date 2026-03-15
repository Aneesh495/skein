package Skein::Mission;
use 5.020;
use strict;
use warnings;
use Skein::Model;
use Skein::Engine;
use Skein::Expr qw(const var op);
use Skein::Rat qw(probability zero add complement compare text);
use Skein::Util qw(check_keys identifier integer deep_copy);

sub new {
    my ($class, $input) = @_;
    check_keys($input, [qw(name horizon processes threshold shared_shock persistent_shock repairs)],
        [qw(horizon processes)], 'mission');
    my $spec = deep_copy($input);
    $spec->{name} //= 'mission';
    identifier($spec->{name}, 'mission name');
    $spec->{horizon} = integer($spec->{horizon}, 'mission horizon', 0, 64);
    die "mission processes must be a nonempty array\n"
        unless ref($spec->{processes}) eq 'ARRAY' && @{$spec->{processes}};
    die "mission process limit exceeded\n" if @{$spec->{processes}} > 16;
    $spec->{threshold} = integer($spec->{threshold} // 1, 'outage threshold', 1, scalar @{$spec->{processes}});
    $spec->{shared_shock} = text(probability($spec->{shared_shock} // 0));
    $spec->{persistent_shock} = text(probability($spec->{persistent_shock} // 0));
    my %names;
    for my $process (@{$spec->{processes}}) {
        check_keys($process, [qw(name initial failure repair)], [qw(name failure repair)], 'mission process');
        my $name = identifier($process->{name}, 'process name');
        die "mission process name exceeds expansion limit\n" if length($name) > 100;
        die "duplicate mission process\n" if $names{$name}++;
        $process->{initial} = text(probability($process->{initial} // 0));
        $process->{failure} = text(probability($process->{failure}));
        $process->{repair} = text(probability($process->{repair}));
    }
    $spec->{repairs} //= [];
    die "mission repairs must be an array\n" unless ref($spec->{repairs}) eq 'ARRAY';
    for my $repair (@{$spec->{repairs}}) {
        check_keys($repair, [qw(name process tick cost)], [qw(name process tick cost)], 'mission repair');
        identifier($repair->{name}, 'mission repair name');
        die "mission repair names unknown process\n" unless $names{$repair->{process}};
        integer($repair->{tick}, 'mission repair tick', 0, $spec->{horizon});
        integer($repair->{cost}, 'mission repair cost', 0, 1_000_000);
    }
    return bless {spec => $spec}, $class;
}

sub specification { return deep_copy($_[0]{spec}) }

sub _noise {
    my ($self, $raw, $name, $p) = @_;
    return const(0) if compare($p, 0) == 0;
    return const(1) if compare($p, 1) == 0;
    push @{$raw->{noise}}, {name => $name, p => $p};
    push @{$raw->{order}}, $name;
    return var($name);
}

sub build {
    my ($self) = @_;
    my $spec = $self->{spec};
    my $raw = {schema => 'skein.model/1', name => $spec->{name},
        title => 'Discrete-time shared-domain mission reliability',
        noise => [], nodes => [], queries => [], repairs => [], order => []};
    my $persistent = $self->_noise($raw, 'n_persistent_shock', $spec->{persistent_shock});
    for my $process (@{$spec->{processes}}) {
        my $initial = $self->_noise($raw, 'n_' . $process->{name} . '_initial', $process->{initial});
        push @{$raw->{nodes}}, {name => 's_' . $process->{name} . '_0', expr => op('or', $persistent, $initial)};
    }
    for my $tick (1 .. $spec->{horizon}) {
        my $shared = $self->_noise($raw, 'n_shared_' . $tick, $spec->{shared_shock});
        my $shock = op('or', $persistent, $shared);
        for my $process (@{$spec->{processes}}) {
            my $name = $process->{name};
            my $failure = $self->_noise($raw, 'n_' . $name . '_fail_' . $tick, $process->{failure});
            my $repair = $self->_noise($raw, 'n_' . $name . '_repair_' . $tick, $process->{repair});
            my $previous = var('s_' . $name . '_' . ($tick - 1));
            my $state = op('ite', $previous, op('not', $repair), $failure);
            push @{$raw->{nodes}}, {name => 's_' . $name . '_' . $tick, expr => op('or', $shock, $state)};
        }
    }
    for my $tick (0 .. $spec->{horizon}) {
        my @states = map { var('s_' . $_->{name} . '_' . $tick) } @{$spec->{processes}};
        my $outage = 'outage_' . $tick;
        my $ever = 'ever_' . $tick;
        my $first = 'first_' . $tick;
        push @{$raw->{nodes}}, {name => $outage, expr => op('atleast', $spec->{threshold}, @states)};
        my $previous_ever = $tick ? var('ever_' . ($tick - 1)) : const(0);
        push @{$raw->{nodes}}, {name => $ever, expr => op('or', $previous_ever, var($outage))};
        push @{$raw->{nodes}}, {name => $first, expr => op('and', var($outage), op('not', $previous_ever))};
        push @{$raw->{queries}}, {name => 'at_' . $tick, event => var($outage)};
        push @{$raw->{queries}}, {name => 'first_at_' . $tick, event => var($first)};
    }
    push @{$raw->{queries}}, {name => 'ever', event => var('ever_' . $spec->{horizon})};
    push @{$raw->{queries}}, {name => 'terminal', event => var('outage_' . $spec->{horizon})};
    for my $repair (@{$spec->{repairs}}) {
        push @{$raw->{repairs}}, {name => $repair->{name},
            node => 's_' . $repair->{process} . '_' . $repair->{tick}, value => 0, cost => $repair->{cost}};
    }
    return Skein::Model->new($raw);
}

sub profile {
    my ($self, %options) = @_;
    my $model = $self->build;
    my $engine = Skein::Engine->new($model, max_nodes => $options{max_nodes} // 250_000);
    my @times;
    my $total_first = zero();
    my $uptime = zero();
    for my $tick (0 .. $self->{spec}{horizon}) {
        my $failure = $engine->solve('at_' . $tick)->{probability};
        my $first = $engine->solve('first_at_' . $tick)->{probability};
        $total_first = add($total_first, $first);
        $uptime = add($uptime, complement($failure)) if $tick < $self->{spec}{horizon};
        push @times, {tick => $tick, failure => $failure, first_passage => $first};
    }
    my $ever = $engine->solve('ever')->{probability};
    die "mission first-passage partition invariant failed\n" if compare($total_first, $ever) != 0;
    return {schema => 'skein.mission/1', specification => $self->specification,
        model_digest => $model->digest, noise_variables => scalar @{$model->noise_names},
        times => \@times, ever_failure => $ever,
        terminal_failure => $engine->solve('terminal')->{probability},
        expected_uptime => text($uptime), diagram_stats => $engine->compiler->stats,
        time_convention => 'States exist at times zero through horizon; uptime accrues before each transition.'};
}

1;
