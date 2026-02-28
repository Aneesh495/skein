package Skein::CLI;
use 5.020;
use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;
use File::Basename qw(dirname);
use File::Spec;
use Skein;
use Skein::Model;
use Skein::Engine;
use Skein::Oracle;
use Skein::Eliminate;
use Skein::Witness;
use Skein::Cutsets;
use Skein::Planner;
use Skein::Robust;
use Skein::Importance;
use Skein::Policy;
use Skein::Sample;
use Skein::Polynomial;
use Skein::Certificate;
use Skein::Compare;
use Skein::Causal;
use Skein::Network;
use Skein::Source;
use Skein::Spectrum;
use Skein::Mission;
use Skein::Markov;
use Skein::Parser;
use Skein::Expr qw(render);
use Skein::Util qw(decode_json_file write_json write_text canonical_json integer check_keys);

sub usage {
    return <<'HELP';
skein: exact causal reliability in Perl

Usage: perl bin/skein COMMAND MODEL [QUERY] [OPTIONS]

  demo                         Run the offline rack demonstration
  check MODEL                  Validate source and show model identity
  run MODEL [QUERY]            Compute exact probabilities
  explain MODEL [QUERY]        Produce a complete MAP noise witness
  cuts MODEL [QUERY]           Derive minimal failure sets
  importance MODEL [QUERY]     Compute derivatives and reliability importance
  polynomial MODEL [QUERY]     Derive symbolic numerator and denominator
  spectrum MODEL [QUERY]       Analyze exact uniform Walsh structure and noise stability
  plan MODEL [QUERY]           Search exact repair frontiers
  bounds MODEL [QUERY]         Bound risk over interval priors
  policy MODEL [QUERY]         Synthesize and verify an adaptive sensor policy
  sample MODEL [QUERY]         Draw exact posterior worlds and estimate risk
  order MODEL [QUERY]          Measure alternate BDD variable orders
  certificate MODEL [QUERY]    Produce an independently checkable result
  verify MODEL CERTIFICATE     Check integrity and full source-world equivalence
  compare OLD NEW              Compare model structure and a coupled event
  effect MODEL CAUSE OUTCOME    Analyze paired potential-outcome response types
  mission SPEC.json            Analyze discrete-time shared-domain evolution
  network SPEC.json            Compile cyclic physical connectivity into causal equations
  source MODEL                 Emit canonical, editable model source
  markov SPEC.json             Analyze exact stochastic transitions
  report MODEL                 Write a standalone HTML research report
  dot MODEL [QUERY]            Write the structural graph or query diagram
  export MODEL                 Write the normalized model as JSON

Options:
  --json                       Print complete canonical JSON
  --out PATH                   Atomically save the result
  --backend bdd|factor|oracle   Select inference implementation (run)
  --expr BOOLEAN               Use a query expression instead of a name
  --budget INTEGER             Per-realization repair or policy budget
  --target RATIONAL            Exact repair risk target
  --robust                     Optimize the worst interval-prior repair risk
  --signed                     Return signed prime implicants (cuts)
  --shapley                    Return exact cooperative allocation (importance)
  --loss RATIONAL              Failure loss for adaptive diagnosis
  --seed STRING                Reproducible posterior sampling seed
  --samples INTEGER            Posterior sample count
  --max-nodes INTEGER          Explicit diagram node bound
  --steps INTEGER              Markov horizon
  --help                       Show this help
  --version                    Show the version

Exit codes: 0 success, 2 invalid input, 3 resource bound, 4 impossible evidence,
5 rejected certificate. Exact inference has exponential worst-case cost.
HELP
}

sub _options {
    my ($arguments) = @_;
    my %options = (backend => 'bdd', seed => 1, samples => 1000, max_nodes => 250_000);
    Getopt::Long::Configure(qw(no_auto_abbrev no_ignore_case permute));
    my $ok = GetOptionsFromArray($arguments,
        'help' => \$options{help}, 'version' => \$options{version},
        'json' => \$options{json}, 'out=s' => \$options{out},
        'backend=s' => \$options{backend}, 'expr=s' => \$options{expr},
        'budget=s' => \$options{budget}, 'target=s' => \$options{target},
        'robust' => \$options{robust}, 'signed' => \$options{signed},
        'shapley' => \$options{shapley}, 'loss=s' => \$options{loss},
        'seed=s' => \$options{seed}, 'samples=s' => \$options{samples},
        'max-nodes=s' => \$options{max_nodes}, 'steps=s' => \$options{steps});
    die "invalid command options\n" unless $ok;
    integer($options{max_nodes}, 'diagram node limit', 2, 5_000_000);
    integer($options{samples}, 'sample count', 1, 1_000_000);
    return \%options;
}

sub _query {
    my ($model, $arguments, $options) = @_;
    if (defined $options->{expr}) {
        die "query name and --expr cannot be combined\n" if @$arguments;
        return {event => Skein::Parser->parse_expression($options->{expr}), interventions => {}};
    }
    die "too many query arguments\n" if @$arguments > 1;
    my $name = @$arguments ? shift @$arguments : undef;
    if (!defined $name) {
        my $names = $model->query_names;
        die "model has no named queries; supply --expr\n" unless @$names;
        my $has_baseline = scalar grep { $_ eq 'baseline' } @$names;
        $name = $has_baseline ? 'baseline' : $names->[0];
    }
    return $model->query($name);
}

sub _output {
    my ($data, $options, $text) = @_;
    if ($options->{out}) {
        ref($data) ? write_json($options->{out}, $data) : write_text($options->{out}, $data);
    }
    if ($options->{json} && ref($data)) {
        print JSON::PP->new->canonical->pretty->encode($data);
    } elsif (defined $text) {
        print $text;
        print "\n" unless $text =~ /\n\z/;
    } elsif (!ref $data) {
        print $data;
    } else {
        print JSON::PP->new->canonical->pretty->encode($data);
    }
    return;
}

sub _run {
    my ($class, $arguments, $options) = @_;
    my $command = shift(@$arguments) // 'help';
    if ($command eq 'version' || $options->{version}) {
        print "skein $Skein::VERSION\n";
        return;
    }
    if ($command eq 'help' || $options->{help}) {
        print usage();
        return;
    }
    if ($command eq 'demo') {
        die "demo takes no positional arguments\n" if @$arguments;
        require Skein::Report;
        my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..', '..'));
        my $path = File::Spec->catfile($root, 'examples', 'rack.sk');
        my $model = Skein::Model->from_file($path);
        my $engine = Skein::Engine->new($model, max_nodes => $options->{max_nodes});
        my $results = $engine->solve_all;
        for my $result (@$results) {
            my $oracle = Skein::Oracle->new($model)->solve($result->{query});
            my $factor = Skein::Eliminate->new($model)->solve($result->{query});
            die "demo backends disagree\n" unless $oracle->{probability} eq $result->{probability}
                && $factor->{probability} eq $result->{probability};
        }
        my $output = $options->{out} // '.runtime/demo.html';
        Skein::Report->new($engine)->save($output);
        my $lines = join '', map { $_->{query}{name} . ' = ' . $_->{probability} . "\n" } @$results;
        print $lines . "Three inference implementations agree. Report: $output\n";
        return;
    }
    my $path = shift @$arguments;
    die "missing input path\n" unless defined $path;
    if ($command eq 'mission') {
        die "mission takes one specification\n" if @$arguments;
        my $mission = Skein::Mission->new(decode_json_file($path));
        _output($mission->profile(max_nodes => $options->{max_nodes}), $options);
        return;
    }
    if ($command eq 'network') {
        die "network takes one specification\n" if @$arguments;
        my $network = Skein::Network->new(decode_json_file($path));
        _output(Skein::Source->emit($network->model),$options);
        return;
    }
    if ($command eq 'markov') {
        die "markov takes one specification\n" if @$arguments;
        my $spec = decode_json_file($path);
        check_keys($spec, [qw(states transitions initial targets rewards horizon)],
            [qw(states transitions)], 'Markov specification');
        my $chain = Skein::Markov->new($spec->{states}, $spec->{transitions});
        my $steps = $options->{steps} // $spec->{horizon} // 10;
        my $data = {trajectory => $chain->trajectory($steps, $spec->{initial}),
            classes => $chain->communicating_classes};
        if ($spec->{targets}) {
            $data->{first_passage} = $chain->first_passage($spec->{targets}, $steps, $spec->{initial});
            $data->{hitting_times} = $chain->hitting_times($spec->{targets});
        }
        $data->{reward} = $chain->expected_reward($spec->{rewards}, $steps, $spec->{initial}) if $spec->{rewards};
        _output($data, $options);
        return;
    }
    my $model = $path =~ /\.json\z/i ? Skein::Model->new(decode_json_file($path)) : Skein::Model->from_file($path);
    if ($command eq 'check') {
        die "check takes one model\n" if @$arguments;
        my $data = {name => $model->name, model_digest => $model->digest,
            noise => scalar @{$model->noise_names}, nodes => scalar @{$model->node_names},
            queries => $model->query_names};
        _output($data, $options, "$data->{name}: $data->{noise} noises, $data->{nodes} equations, "
            . scalar(@{$data->{queries}}) . " queries\nSHA-256 $data->{model_digest}");
        return;
    }
    if ($command eq 'export') {
        die "export takes one model\n" if @$arguments;
        _output($model->raw, $options);
        return;
    }
    if ($command eq 'source') {
        die "source takes one model\n" if @$arguments;
        _output(Skein::Source->emit($model),$options);
        return;
    }
    if ($command eq 'verify') {
        my $certificate = shift @$arguments;
        die "verify requires a model and certificate\n" unless defined($certificate) && !@$arguments;
        my $result = Skein::Certificate->verify($model, decode_json_file($certificate));
        _output($result, $options, "Verified $result->{worlds} worlds; exact probability $result->{probability}");
        return;
    }
    if ($command eq 'compare') {
        my $other_path = shift @$arguments;
        die "compare requires two models\n" unless defined($other_path) && !@$arguments;
        my $other = $other_path =~ /\.json\z/i
            ? Skein::Model->new(decode_json_file($other_path)) : Skein::Model->from_file($other_path);
        my $data = Skein::Compare->model_diff($model, $other);
        $data->{coupled_event} = Skein::Compare->coupled_event($model, $other,
            Skein::Parser->parse_expression($options->{expr})) if defined $options->{expr};
        _output($data, $options);
        return;
    }
    my $engine = Skein::Engine->new($model, max_nodes => $options->{max_nodes});
    if ($command eq 'effect') {
        my ($cause,$outcome) = @$arguments;
        die "effect requires a treatment node and outcome expression\n" unless @$arguments == 2;
        my $analysis = Skein::Causal->new($engine);
        my $data = $analysis->response($cause,Skein::Parser->parse_expression($outcome));
        $data->{verification} = $analysis->verify_response($data) if @{$model->noise_names} <= 12;
        _output($data,$options);
        return;
    }
    if ($command eq 'report') {
        die "report takes one model\n" if @$arguments;
        require Skein::Report;
        my $output = $options->{out} // '.runtime/report.html';
        Skein::Report->new($engine)->save($output);
        print "Report: $output\n";
        return;
    }
    if ($command eq 'run') {
        my @queries = @$arguments || defined($options->{expr})
            ? (_query($model, $arguments, $options))
            : map { $model->query($_) } @{$model->query_names};
        die "model has no queries\n" unless @queries;
        die "unknown backend '$options->{backend}'\n" unless $options->{backend} =~ /\A(?:bdd|factor|oracle)\z/;
        my $backend = $options->{backend} eq 'bdd' ? $engine
            : $options->{backend} eq 'factor' ? Skein::Eliminate->new($model) : Skein::Oracle->new($model);
        my @results = map { my $q = $_; +{%{$backend->solve($q)}, query => $q} } @queries;
        _output({backend => $options->{backend}, model_digest => $model->digest, results => \@results},
            $options, join('', map { ($_->{query}{name} // render($_->{query}{event}))
                . ' = ' . $_->{probability} . "\n" } @results));
        return;
    }
    if ($command eq 'dot' && !@$arguments && !defined($options->{expr})) {
        require Skein::Render;
        _output(Skein::Render->model_dot($model), $options);
        return;
    }
    my $query = _query($model, $arguments, $options);
    my $data;
    if ($command eq 'explain') {
        $data = Skein::Witness->new($engine)->explain($query);
    } elsif ($command eq 'cuts') {
        my $root = $engine->compiler->query($query)->{numerator};
        my $cuts = Skein::Cutsets->new($engine->compiler->bdd, $root);
        $data = $options->{signed} ? {prime_implicants => $cuts->prime_implicants}
            : {minimal_positive_sets => $cuts->positive_sets};
    } elsif ($command eq 'importance') {
        my $importance = Skein::Importance->new($engine);
        $data = $options->{shapley} ? $importance->shapley($query) : $importance->profile($query);
    } elsif ($command eq 'polynomial') {
        my $roots = $engine->compiler->query($query);
        my %parts;
        for my $part (qw(numerator denominator)) {
            my $polynomial = Skein::Polynomial->from_bdd($engine->compiler->bdd, $roots->{$part});
            $parts{$part} = {expression => $polynomial->render, variables => $polynomial->variables, terms => $polynomial->terms};
        }
        $data = \%parts;
    } elsif ($command eq 'spectrum') {
        my $root = $engine->compiler->query($query)->{numerator};
        $data = Skein::Spectrum->from_bdd($engine->compiler->bdd,$root)->profile;
    } elsif ($command eq 'plan') {
        my %planning = (budget => $options->{budget} // 20);
        $planning{target} = $options->{target} if defined $options->{target};
        $data = $options->{robust} ? Skein::Robust->new($engine)->plan($query, %planning)
            : Skein::Planner->new($engine)->plan($query, %planning);
    } elsif ($command eq 'bounds') {
        $data = Skein::Robust->new($engine)->bounds($query, include_vertices => 1);
    } elsif ($command eq 'policy') {
        my $policy = Skein::Policy->new($engine);
        $data = $policy->synthesize($query, budget => $options->{budget} // 20,
            failure_loss => $options->{loss} // 100);
        $data->{independent_verification} = $policy->verify($data);
    } elsif ($command eq 'sample') {
        $data = Skein::Sample->new($engine, seed => $options->{seed})->estimate($query, $options->{samples});
    } elsif ($command eq 'order') {
        $data = Skein::Compare->order_experiment($engine, $query);
    } elsif ($command eq 'certificate') {
        $data = Skein::Certificate->create($engine, $query);
    } elsif ($command eq 'dot') {
        require Skein::Render;
        $data = defined($options->{expr}) || exists($query->{name})
            ? Skein::Render->diagram_dot($engine->compiler->bdd, $engine->compiler->query($query)->{numerator})
            : Skein::Render->model_dot($model);
    } else {
        die "unknown command '$command'; use --help\n";
    }
    _output($data, $options);
    return;
}

sub main {
    my ($class, $input) = @_;
    my @arguments = @$input;
    my $command = @arguments ? $arguments[0] : 'help';
    my $ok = eval {
        my $options = _options(\@arguments);
        $class->_run(\@arguments, $options);
        1;
    };
    return 0 if $ok;
    my $error = $@ || "unknown error\n";
    print STDERR "skein: $error";
    return 5 if $command eq 'verify';
    return 4 if $error =~ /impossible evidence/;
    return 3 if $error =~ /limit exceeded|exceeds .*limit|too large/;
    return 2;
}

1;
