package Skein::Report;
use 5.020;
use strict;
use warnings;
use JSON::PP;
use Skein::Render;
use Skein::Oracle;
use Skein::Eliminate;
use Skein::Cutsets;
use Skein::Witness;
use Skein::Planner;
use Skein::Policy;
use Skein::Importance;
use Skein::Robust;
use Skein::Polynomial;
use Skein::Certificate;
use Skein::Expr qw(render const);
use Skein::Rat qw(decimal rat);
use Skein::Util qw(html_escape write_text canonical_json);

sub new {
    my ($class, $engine) = @_;
    return bless {engine => $engine}, $class;
}

sub _table {
    my ($headers,$rows) = @_;
    my $html = '<div class="table-scroll"><table><thead><tr>';
    $html .= '<th scope="col">' . html_escape($_) . '</th>' for @$headers;
    $html .= '</tr></thead><tbody>';
    for my $row (@$rows) {
        $html .= '<tr>';
        $html .= '<td>' . html_escape(defined($_) ? $_ : 'undefined') . '</td>' for @$row;
        $html .= '</tr>';
    }
    return $html . '</tbody></table></div>';
}

sub _json {
    my ($value) = @_;
    return '<pre>' . html_escape(JSON::PP->new->canonical->pretty->encode($value)) . '</pre>';
}

sub _optional {
    my ($label,$function) = @_;
    my $result = eval { $function->() };
    return {status => 'available', value => $result} unless $@;
    my $error = $@;
    $error =~ s/\s+\z//;
    return {status => 'unavailable', reason => $error, analysis => $label};
}

sub data {
    my ($self) = @_;
    my $engine = $self->{engine};
    my $model = $engine->model;
    my $names = $model->query_names;
    die "report requires at least one named query\n" unless @$names;
    my $baseline_name = (grep { $_ eq 'baseline' } @$names) ? 'baseline' : $names->[0];
    my $query = $model->query($baseline_name);
    my $results = $engine->solve_all;
    my %verification;
    if (@{$model->noise_names} <= 12) {
        for my $result (@$results) {
            my $oracle = Skein::Oracle->new($model)->solve($result->{query});
            my $factor = Skein::Eliminate->new($model)->solve($result->{query});
            for my $field (qw(probability numerator denominator)) {
                die "report independent backends disagree\n" unless $oracle->{$field} eq $result->{$field}
                    && $factor->{$field} eq $result->{$field};
            }
            $verification{$result->{query}{name}} = {status => 'three_backends_agree',
                worlds => $oracle->{worlds}, factor_peak_rows => $factor->{peak_rows}};
        }
    } else {
        $verification{$_->{query}{name}} = {status => 'symbolic_only',
            reason => 'The report enumeration profile is limited to 12 noise variables.'} for @$results;
    }
    my $roots = $engine->compiler->query($query);
    my $cuts = _optional('prime explanations',sub {
        my $analysis = Skein::Cutsets->new($engine->compiler->bdd,$roots->{numerator});
        my $monotone = $analysis->monotonicity->{monotone};
        return {monotone => $monotone, implicants => $analysis->prime_implicants(limit => 1000)};
    });
    my $importance = _optional('importance',sub { Skein::Importance->new($engine)->profile($query) });
    my $witness = _optional('witness',sub { Skein::Witness->new($engine)->explain($query) });
    my $polynomial = _optional('reliability polynomial',sub {
        my $p = Skein::Polynomial->from_bdd($engine->compiler->bdd,$roots->{numerator},max_terms => 5000);
        return {expression => $p->render, terms => $p->term_count};
    });
    my $certificate = _optional('complete-world certificate',sub {
        die "report certificate profile exceeds 12 variables\n" if @{$model->noise_names} > 12;
        my $cert = Skein::Certificate->create($engine,$query);
        return Skein::Certificate->verify($model,$cert);
    });
    my $data = {model => $model->raw, model_digest => $model->digest,
        primary_query => $baseline_name, results => $results, verification => \%verification,
        cuts => $cuts, importance => $importance, witness => $witness,
        polynomial => $polynomial, certificate => $certificate,
        diagram_stats => $engine->compiler->stats};
    if (@{$model->repairs}) {
        $data->{plan} = _optional('repair frontier',sub { Skein::Planner->new($engine)->plan($query,budget => 20) });
    }
    if (@{$model->sensors}) {
        $data->{policy} = _optional('adaptive diagnosis',sub {
            my $policy = Skein::Policy->new($engine);
            my $result = $policy->synthesize($query,budget => 20,failure_loss => 100);
            $result->{verification} = $policy->verify($result);
            return $result;
        });
    }
    if (keys %{$model->intervals}) {
        $data->{bounds} = _optional('prior interval bounds',sub { Skein::Robust->new($engine)->bounds($query) });
    }
    return $data;
}

sub _unavailable {
    my ($analysis) = @_;
    return '<p class="note">Analysis unavailable: ' . html_escape($analysis->{reason}) . '</p>';
}

sub html {
    my ($self,$data) = @_;
    $data //= $self->data;
    my $engine = $self->{engine};
    my $model = $engine->model;
    my $primary = $model->query($data->{primary_query});
    my ($baseline) = grep { $_->{query}{name} eq $data->{primary_query} } @{$data->{results}};
    my $title = length($model->title) ? $model->title : $model->name;
    my $html = <<'HTML';
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="An exact causal reliability analysis generated entirely in Perl.">
<title>Skein / causal reliability notebook</title>
<style>
:root{--paper:#f4f1e8;--ink:#20372a;--muted:#667166;--line:#d7d7c8;--green:#54755b;--white:#fffdf8}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.65 system-ui,sans-serif}
a{color:var(--green)}header{border-bottom:1px solid var(--line);padding:19px 5%;display:flex;justify-content:space-between;align-items:center}
.wordmark{font:600 19px/1.2 ui-monospace,monospace;letter-spacing:6px}.header-note{font:11px ui-monospace,monospace;color:var(--muted);letter-spacing:1px}
main{max-width:1200px;margin:auto;padding:58px 42px 70px}.eyebrow{font:11px ui-monospace,monospace;letter-spacing:2px;text-transform:uppercase;color:var(--muted)}
h1{font:normal clamp(34px,5vw,63px)/1.08 Georgia,serif;max-width:930px;margin:19px 0 25px;letter-spacing:-1.8px}
h2{font:normal 29px/1.25 Georgia,serif;margin:0 0 16px}h3{font:600 15px/1.4 system-ui,sans-serif;margin:19px 0 10px}
p{max-width:800px}.lead{font-size:17px;color:#526253;max-width:760px}.hero-rule{border-bottom:1px solid var(--line);padding-bottom:38px;margin-bottom:33px}
.metrics{display:grid;grid-template-columns:2fr 1fr 1fr;gap:25px;margin-top:28px}.metric{border-left:2px solid #95ad92;padding-left:17px}.metric strong{font:normal 33px Georgia,serif;display:block}.metric span{font:11px ui-monospace,monospace;color:var(--muted)}
.section{border-top:1px solid var(--line);padding-top:28px;margin-top:38px}.section:first-of-type{border-top:0;margin-top:0}.section-index{font:10px ui-monospace,monospace;color:var(--muted);letter-spacing:2px;margin-bottom:9px}
.columns{display:grid;grid-template-columns:minmax(0,1.5fr) minmax(0,1fr);gap:35px}.columns>*{min-width:0}.card{background:var(--white);border:1px solid var(--line);border-radius:8px;padding:23px;margin:18px 0;min-width:0}
.card p{margin-bottom:0}.note{font-size:12px;color:var(--muted)}.exact{font-family:ui-monospace,monospace}.tag{font:10px ui-monospace,monospace;background:#e3ebdf;border:1px solid #c4d0be;color:#416046;border-radius:3px;padding:3px 6px;white-space:nowrap}
.figure{overflow:auto;background:#fffdf8;border:1px solid var(--line);border-radius:7px;padding:15px}.figure svg{display:block;margin:auto;max-width:none}.figure-caption{font-size:12px;color:var(--muted);margin:10px 0}
.table-scroll{overflow:auto}table{border-collapse:collapse;width:100%;text-align:left;font-size:12px}th{font-size:10px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);padding:11px 12px;border-bottom:1px solid #aebba7}
td{padding:12px;border-bottom:1px solid #dfdfd1;vertical-align:top}td:first-child{font-family:ui-monospace,monospace}tbody tr:hover{background:#eaeedd}
pre{font:11px/1.65 ui-monospace,monospace;overflow:auto;background:#eae9df;padding:17px;border-radius:5px;max-height:420px}
details{border-top:1px solid var(--line);margin:18px 0;padding-top:12px}summary{cursor:pointer;font-size:12px;font-weight:600}footer{border-top:1px solid var(--line);margin-top:48px;padding-top:21px;color:var(--muted);font-size:11px}
.hash{overflow-wrap:anywhere;font:10px/1.7 ui-monospace,monospace}.pill-row{display:flex;gap:8px;flex-wrap:wrap}.query-note{font:11px ui-monospace,monospace;color:var(--muted)}
@media(max-width:760px){main{padding:32px 18px}.columns{grid-template-columns:1fr}.metrics{grid-template-columns:1fr 1fr}.metric:first-child{grid-column:1/-1}header{padding:16px 18px}.header-note{max-width:155px;text-align:right}h1{letter-spacing:-1px}.card{padding:17px}td,th{padding:9px}}
@media print{body{background:white}main{max-width:none;padding:20px}header{padding:10px}details{display:none}.figure{overflow:visible}.figure svg{max-width:100%;height:auto}.section{break-inside:avoid}}
</style>
</head>
<body>
<header><div class="wordmark">skein</div><div class="header-note">EXACT CAUSAL RELIABILITY<br>AN OFFLINE RESEARCH NOTEBOOK</div></header>
<main>
HTML
    $html .= '<div class="hero-rule"><div class="eyebrow">Model / ' . html_escape($model->name) . '</div>';
    $html .= '<h1>' . html_escape($title) . '</h1>';
    $html .= '<p class="lead">Shared causes tie apparently separate failures together. This notebook keeps those dependencies explicit, separates observation from intervention, and evaluates alternate worlds under the same underlying noise.</p>';
    $html .= '<div class="pill-row"><span class="tag">EXACT RATIONAL ARITHMETIC</span><span class="tag">SHARED-NOISE WORLDS</span><span class="tag">PURE PERL</span></div>';
    $html .= '<div class="metrics"><div class="metric"><strong>' . html_escape($baseline->{probability})
        . '</strong><span>' . html_escape($data->{primary_query}) . ' / exact probability</span></div>';
    $html .= '<div class="metric"><strong>' . scalar(@{$model->noise_names}) . '</strong><span>independent exogenous noises</span></div>';
    $html .= '<div class="metric"><strong>' . scalar(@{$model->node_names}) . '</strong><span>structural equations</span></div></div></div>';
    $html .= '<section class="section"><div class="section-index">01 / QUESTIONS</div><h2>Observation changes what we know.<br>Intervention changes what happens.</h2>';
    $html .= '<p>Each result names its conditioning world. Factual evidence stays in the original world while counterfactual outcomes use replaced equations and the same exogenous realization.</p>';
    my @query_rows;
    for my $result (@{$data->{results}}) {
        my $q = $result->{query};
        my $evidence = exists($q->{evidence}) ? 'given ' . render($q->{evidence}) : 'no changed-world evidence';
        my $factual = exists($q->{factual}) ? 'factual ' . render($q->{factual}) : 'no factual evidence';
        my $interventions = join ', ', map { $_ . '=' . $q->{interventions}{$_} } sort keys %{$q->{interventions}};
        push @query_rows, [$q->{name},render($q->{event}),$result->{probability},$result->{decimal},
            $interventions || 'none',$evidence . '; ' . $factual];
    }
    $html .= _table(['query','event','exact probability','decimal','do','conditioning'],\@query_rows);
    $html .= '<p class="note">Decimals are display approximations. Fractions are the computed results. Conditional rows can describe different populations, so they do not represent a single intervention ranking.</p></section>';
    $html .= '<section class="section"><div class="section-index">02 / MECHANISM</div><h2>The model is the assumption.</h2><div class="columns"><div>';
    my $graph = _optional('graph rendering',sub { Skein::Render->model_svg($model) });
    $html .= $graph->{status} eq 'available' ? '<div class="figure">' . $graph->{value} . '</div>' : _unavailable($graph);
    $html .= '<p class="figure-caption">Noise nodes have independent priors. Every other node is a deterministic function of its parents. Correlation is induced by shared ancestry.</p></div><div class="card"><h3>Exact priors</h3>';
    $html .= _table(['noise','P(noise=1)'],[map { [$_,$model->priors->{$_}] } @{$model->noise_names}]);
    $html .= '<h3>Equation replacement</h3><p>An intervention pins an endogenous node and removes its original incoming mechanism. Downstream equations still execute.</p><h3>Scope</h3><p>These results follow from a specified structural model. They do not identify that model from observational data.</p></div></div>';
    $html .= '<details><summary>Inspect every structural equation</summary>'
        . _table(['node','Boolean equation'],[map { [$_,render($model->equation($_))] } @{$model->node_order}]) . '</details></section>';
    $html .= '<section class="section"><div class="section-index">03 / SYMBOLIC STRUCTURE</div><h2>One event, a shared decision graph.</h2><div class="columns"><div>';
    my $roots = $engine->compiler->query($primary);
    my $diagram = _optional('diagram rendering',sub { Skein::Render->diagram_svg($engine->compiler->bdd,$roots->{numerator}) });
    $html .= $diagram->{status} eq 'available' ? '<div class="figure">' . $diagram->{value} . '</div>' : _unavailable($diagram);
    $html .= '<p class="figure-caption">Dashed edges select false; solid edges select true. Identical subfunctions share a node. Skipped noise variables integrate to one.</p></div><div>';
    if ($data->{cuts}{status} eq 'available') {
        my $cuts = $data->{cuts}{value};
        $html .= '<div class="card"><h3>Minimal sufficient noise assignments</h3><p class="note">'
            . ($cuts->{monotone} ? 'The event is monotone in its noise variables.' : 'Signed literals are required for this nonmonotone event.') . '</p>';
        my @rows = map { my $cube = $_; [join(' & ',map { $_ . '=' . $cube->{$_} } sort keys %$cube) || 'true'] } @{$cuts->{implicants}};
        $html .= _table(['prime implicant'],\@rows) . '<p class="note">Implicants can overlap. Their probabilities must not be added.</p></div>';
    } else {
        $html .= _unavailable($data->{cuts});
    }
    if ($data->{polynomial}{status} eq 'available') {
        $html .= '<div class="card"><h3>Exact numerator polynomial</h3><pre>' . html_escape($data->{polynomial}{value}{expression})
            . '</pre><p class="note">The coefficients are exact. The monomials describe prior probabilities, not independent failure scenarios.</p></div>';
    } else { $html .= _unavailable($data->{polynomial}) }
    $html .= '</div></div></section>';
    if ($data->{importance}{status} eq 'available') {
        $html .= '<section class="section"><div class="section-index">04 / SENSITIVITY</div><h2>Where does the probability move?</h2>';
        $html .= _table(['noise','exact local derivative','risk at prior=0','risk at prior=1','removable risk'],
            [map { [$_->{variable},$_->{derivative},$_->{risk_at_zero},$_->{risk_at_one},$_->{removable_risk}] }
                @{$data->{importance}{value}{variables}}]);
        $html .= '<p class="note">The derivative is with respect to a noise prior. Changing an exogenous prior is a different operation from replacing an endogenous equation.</p></section>';
    }
    if ($data->{plan} && $data->{plan}{status} eq 'available') {
        my $plan = $data->{plan}{value};
        $html .= '<section class="section"><div class="section-index">05 / REPAIR</div><h2>The complete cost and risk frontier.</h2><div class="columns"><div class="figure">'
            . Skein::Render->frontier_svg($plan->{frontier}) . '</div><div>';
        $html .= _table(['cost','residual risk','actions'],[map { [$_->{cost},$_->{probability},join(', ',@{$_->{actions}}) || 'none'] } @{$plan->{frontier}}]);
        $html .= '<p class="note">All feasible action subsets within budget 20 were considered. A state limit raises an error instead of returning a partial optimum.</p></div></div>';
        $html .= '<details><summary>Inspect repair search evidence</summary>' . _json($plan) . '</details></section>';
    }
    if ($data->{policy} && $data->{policy}{status} eq 'available') {
        my $policy = $data->{policy}{value};
        $html .= '<section class="section"><div class="section-index">06 / DIAGNOSIS</div><h2>Sometimes the next action is a measurement.</h2>';
        $html .= '<div class="metrics"><div class="metric"><strong>' . html_escape($policy->{tree}{expected_loss})
            . '</strong><span>expected sensing cost + repair cost + failure loss</span></div><div class="metric"><strong>'
            . html_escape($policy->{tree}{expected_risk}) . '</strong><span>residual failure probability</span></div><div class="metric"><strong>'
            . html_escape($policy->{tree}{expected_cost}) . '</strong><span>expected observation and repair cost</span></div></div>';
        $html .= '<p>The adaptive policy observes factual sensors before choosing repairs. The per-realization budget is 20 and the failure loss is 100. Every possible noise realization was independently replayed to verify the expected cost and risk.</p>';
        $html .= '<details><summary>Inspect the entire diagnostic policy and its verification</summary>' . _json($policy) . '</details></section>';
    }
    if ($data->{bounds} && $data->{bounds}{status} eq 'available') {
        my $bounds = $data->{bounds}{value};
        $html .= '<section class="section"><div class="section-index">07 / PRIOR UNCERTAINTY</div><h2>Exact bounds over a box of priors.</h2>';
        $html .= _table(['bound','exact probability','attaining priors'],[
            ['minimum',$bounds->{minimum}{probability},canonical_json($bounds->{minimum}{priors})],
            ['maximum',$bounds->{maximum}{probability},canonical_json($bounds->{maximum}{priors})]]);
        $html .= '<p class="note">All ' . $bounds->{vertices} . ' distinct corners were evaluated. The result assumes an independent-prior box and strictly positive evidence at every corner.</p></section>';
    }
    if ($data->{witness}{status} eq 'available' && $data->{witness}{value}{status} eq 'witness') {
        my $witness = $data->{witness}{value};
        $html .= '<section class="section"><div class="section-index">08 / A REALIZATION</div><h2>A complete most-probable witness.</h2>';
        $html .= _table(['noise','value'],[map { [$_,$witness->{noise}{$_}] } sort keys %{$witness->{noise}}]);
        $html .= '<p class="note">This complete assignment has joint mass ' . html_escape($witness->{mass})
            . '. Its mass conditional on query evidence is ' . html_escape($witness->{posterior_mass})
            . '. It is one realization, not a minimal explanation.</p>';
        $html .= '<details><summary>Replay factual and target structural equations</summary>' . _json($witness) . '</details></section>';
    }
    $html .= '<section class="section"><div class="section-index">09 / VERIFICATION</div><h2>Results you can recompute.</h2>';
    $html .= _table(['query','independent verification','worlds'],[map { my $v=$data->{verification}{$_}; [$_,$v->{status},$v->{worlds}//'not enumerated'] } sort keys %{$data->{verification}}]);
    $html .= '<p>The symbolic engine uses reduced ordered decision diagrams. The factor engine lowers equations into sparse rational gate constraints and eliminates variables. The enumerator executes each source world directly. The certificate checker compares the complete diagram truth function with the source, including zero-weight worlds.</p>';
    $html .= '<details><summary>Inspect certificate verification and runtime progress</summary>' . _json({certificate => $data->{certificate},diagram_stats => $data->{diagram_stats}}) . '</details>';
    $html .= '<details><summary>Inspect the normalized input model</summary>' . _json($data->{model}) . '</details>';
    $html .= '<p class="hash">MODEL SHA-256<br>' . html_escape($model->digest) . '</p></section>';
    $html .= '<footer>Generated entirely in Perl. No remote assets, JavaScript, or service connection are required. Exact inference is exponential in the worst case; bounded analyses identify unavailable results explicitly. This notebook records a specified model, not evidence that its assumptions describe a particular real system.</footer></main></body></html>';
    return $html;
}

sub save {
    my ($self,$path,$data) = @_;
    return write_text($path,$self->html($data));
}

1;
