package Skein::Compare;
use 5.020;
use strict;
use warnings;
use Skein::Compiler;
use Skein::BDD::Transform qw(transfer);
use Skein::BDD::Count qw(weighted_count);
use Skein::Expr qw(render);
use Skein::Rat qw(text subr);
use Skein::Util qw(canonical_json integer);

sub model_diff {
    my ($class, $old, $new) = @_;
    my $old_raw = $old->raw;
    my $new_raw = $new->raw;
    my @changes;
    for my $kind (qw(noise nodes queries repairs sensors)) {
        my %before = map { $_->{name} => $_ } @{$old_raw->{$kind}};
        my %after = map { $_->{name} => $_ } @{$new_raw->{$kind}};
        my %all = (%before, %after);
        for my $name (sort keys %all) {
            if (!exists $before{$name}) {
                push @changes, {kind => $kind, name => $name, change => 'added', after => $after{$name}};
            } elsif (!exists $after{$name}) {
                push @changes, {kind => $kind, name => $name, change => 'removed', before => $before{$name}};
            } elsif (canonical_json($before{$name}) ne canonical_json($after{$name})) {
                push @changes, {kind => $kind, name => $name, change => 'modified',
                    before => $before{$name}, after => $after{$name}};
            }
        }
    }
    for my $kind (qw(schema name title intervals order)) {
        next if canonical_json($old_raw->{$kind}) eq canonical_json($new_raw->{$kind});
        push @changes,{kind=>'metadata',name=>$kind,change=>'modified',
            before=>$old_raw->{$kind},after=>$new_raw->{$kind}};
    }
    return {before_digest => $old->digest, after_digest => $new->digest, changes => \@changes};
}

sub coupled_event {
    my ($class, $old, $new, $event, %options) = @_;
    die "coupled models require identical exogenous variables and priors\n"
        unless canonical_json($old->priors) eq canonical_json($new->priors);
    $old->validate_expression($event);
    $new->validate_expression($event);
    my $left = Skein::Compiler->new($old, %options);
    my $right = Skein::Compiler->new($new, %options);
    my $old_root = $left->expression($event);
    my $new_root = transfer($right->bdd, $left->bdd, $right->expression($event));
    my $bdd = $left->bdd;
    my $priors = $old->priors;
    my $regression = $bdd->apply('and', $bdd->negate($old_root), $new_root);
    my $improvement = $bdd->apply('and', $old_root, $bdd->negate($new_root));
    my $disagreement = $bdd->apply('xor', $old_root, $new_root);
    my $old_risk = weighted_count($bdd, $old_root, $priors);
    my $new_risk = weighted_count($bdd, $new_root, $priors);
    return {before_digest => $old->digest, after_digest => $new->digest,
        event => render($event), old_probability => text($old_risk), new_probability => text($new_risk),
        delta => text(subr($new_risk, $old_risk)),
        regression_mass => text(weighted_count($bdd, $regression, $priors)),
        improvement_mass => text(weighted_count($bdd, $improvement, $priors)),
        disagreement_mass => text(weighted_count($bdd, $disagreement, $priors)),
        logically_equivalent => $old_root == $new_root ? 1 : 0,
        coupling => 'Identically named noises are the same exogenous realization.'};
}

sub order_experiment {
    my ($class, $engine, $query, %options) = @_;
    my $model = $engine->model;
    $query = $model->query($query) unless ref($query);
    my $max_trials = integer($options{max_trials} // 32, 'ordering trial limit', 1, 500);
    my @base = @{$model->order};
    my @orders = ([@base], [reverse @base], [sort @base]);
    # Adjacent swaps produce a measured local neighborhood, not a global optimum.
    for my $i (0 .. $#base - 1) {
        my @candidate = @base;
        @candidate[$i, $i + 1] = @candidate[$i + 1, $i];
        push @orders, \@candidate;
    }
    for my $rotation (1 .. $#base) {
        push @orders, [@base[$rotation .. $#base], @base[0 .. $rotation - 1]];
    }
    my %seen;
    my @trials;
    my $expected = $engine->solve($query);
    for my $order (@orders) {
        my $key = join ',', @$order;
        next if $seen{$key}++;
        last if @trials >= $max_trials;
        my $compiler = Skein::Compiler->new($model, order => $order,
            max_nodes => $options{max_nodes} // 250_000);
        my $roots = $compiler->query($query);
        my $n = text(weighted_count($compiler->bdd, $roots->{numerator}, $model->priors));
        my $d = text(weighted_count($compiler->bdd, $roots->{denominator}, $model->priors));
        die "ordering changed weighted semantics\n" unless $n eq $expected->{numerator} && $d eq $expected->{denominator};
        $compiler->bdd->assert_invariants;
        push @trials, {order => [@$order], allocated_nodes => $compiler->bdd->node_count,
            reachable_nodes => scalar @{$compiler->bdd->reachable([$roots->{numerator}, $roots->{denominator}])},
            numerator => $n, denominator => $d};
    }
    my @ranked = sort { $a->{reachable_nodes} <=> $b->{reachable_nodes}
        || $a->{allocated_nodes} <=> $b->{allocated_nodes}
        || join(',', @{$a->{order}}) cmp join(',', @{$b->{order}}) } @trials;
    return {trials => \@trials, best_measured => $ranked[0], complete_search => 0};
}

1;
