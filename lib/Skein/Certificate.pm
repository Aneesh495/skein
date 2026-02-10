package Skein::Certificate;
use 5.020;
use strict;
use warnings;
use Skein::BDD::Transform qw(export_diagram import_diagram);
use Skein::Model;
use Skein::Oracle;
use Skein::Expr qw(evaluate const);
use Skein::Rat qw(probability zero add divr text compare is_zero);
use Skein::Util qw(check_keys deep_copy digest canonical_json integer);

sub create {
    my ($class, $engine, $input, %options) = @_;
    my $model = $engine->model;
    $input = $model->query($input) unless ref($input);
    my $query = deep_copy($input);
    $model->validate_query($query);
    my $max_variables = integer($options{max_variables} // 16, 'certificate variable limit', 0, 20);
    die "certificate variable limit exceeded\n" if @{$model->noise_names} > $max_variables;
    my $result = $engine->solve($query);
    my $roots = $engine->compiler->query($query);
    my $payload = {
        schema => 'skein.certificate/1', model_digest => $model->digest,
        query => $query, priors => $model->priors,
        diagram => export_diagram($engine->compiler->bdd, [$roots->{numerator}, $roots->{denominator}]),
        result => {map { $_ => $result->{$_} } qw(probability numerator denominator)},
        verification => {method => 'complete source-world equivalence',
            variables => scalar @{$model->noise_names}, worlds => 2 ** @{$model->noise_names}},
    };
    return {payload => $payload, sha256 => digest($payload)};
}

sub verify {
    my ($class, $model, $envelope, %options) = @_;
    check_keys($envelope, [qw(payload sha256)], [qw(payload sha256)], 'certificate envelope');
    my $payload = $envelope->{payload};
    check_keys($payload, [qw(schema model_digest query priors diagram result verification)],
        [qw(schema model_digest query priors diagram result verification)], 'certificate');
    die "certificate integrity mismatch\n" unless digest($payload) eq $envelope->{sha256};
    die "unsupported certificate schema\n" unless $payload->{schema} eq 'skein.certificate/1';
    die "certificate model identity mismatch\n" unless $payload->{model_digest} eq $model->digest;
    die "certificate priors do not match model\n" unless canonical_json($payload->{priors}) eq canonical_json($model->priors);
    check_keys($payload->{result}, [qw(probability numerator denominator)],
        [qw(probability numerator denominator)], 'certificate result');
    check_keys($payload->{verification}, [qw(method variables worlds)], [qw(method variables worlds)], 'verification claim');
    die "unknown certificate verification method\n" unless $payload->{verification}{method} eq 'complete source-world equivalence';
    my $max_variables = integer($options{max_variables} // 16, 'certificate verification limit', 0, 20);
    my $names = $model->noise_names;
    die "certificate verification variable limit exceeded\n" if @$names > $max_variables;
    die "certificate verification dimensions mismatch\n"
        unless $payload->{verification}{variables} == @$names && $payload->{verification}{worlds} == 2 ** @$names;
    my $query = deep_copy($payload->{query});
    $model->validate_query($query);
    my ($bdd, $roots) = import_diagram($payload->{diagram}, max_nodes => $options{max_nodes} // 250_000);
    die "certificate requires numerator and denominator roots\n" unless @$roots == 2;
    die "certificate diagram variable mismatch\n"
        unless canonical_json([sort @{$bdd->variables}]) eq canonical_json($names);
    my ($numerator, $denominator) = (zero(), zero());
    # This path never calls the symbolic compiler or weighted-count engine.
    my $oracle = Skein::Oracle->new($model, max_variables => $max_variables,
        max_worlds => 2 ** $max_variables);
    my $worlds = $oracle->each_assignment(sub {
        my ($noise, $mass, $index) = @_;
        my $factual = $model->world($noise, {});
        my $target = $model->world($noise, $query->{interventions});
        my $d = evaluate($query->{factual} // const(1), $factual)
            && evaluate($query->{evidence} // const(1), $target) ? 1 : 0;
        my $n = $d && evaluate($query->{event}, $target) ? 1 : 0;
        die "certificate denominator disagrees with source at world $index\n"
            unless $bdd->evaluate($roots->[1], $noise) == $d;
        die "certificate numerator disagrees with source at world $index\n"
            unless $bdd->evaluate($roots->[0], $noise) == $n;
        $denominator = add($denominator, $mass) if $d;
        $numerator = add($numerator, $mass) if $n;
    });
    die "certificate claims probability for impossible evidence\n" if is_zero($denominator);
    my %actual = (numerator => text($numerator), denominator => text($denominator),
        probability => text(divr($numerator, $denominator)));
    for my $field (qw(numerator denominator probability)) {
        probability($payload->{result}{$field});
        die "certificate $field mismatch\n" if compare($actual{$field}, $payload->{result}{$field}) != 0;
    }
    return {verified => 1, model_digest => $model->digest, worlds => $worlds,
        diagram_nodes => $bdd->node_count, %actual};
}

1;
