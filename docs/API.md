# Library API and experiments

Run examples from the checkout with `perl -Ilib SCRIPT.pl`, or add the checkout's
`lib` directory to `@INC`. No package installation is required.

```perl
use strict;
use warnings;
use Skein::Model;
use Skein::Engine;

my $model = Skein::Model->from_file('examples/rack.sk');
my $engine = Skein::Engine->new($model, max_nodes => 250_000);
my $result = $engine->solve('had_isolated_power');
print "$result->{probability}\n";  # 100/2599
```

The returned numerator is the joint event and evidence mass. The denominator
is the evidence mass. Fractions are exact; `decimal` is a display approximation.
The result identifies normalized source, priors, order, and reachable nodes.

## Query construction

```perl
use Skein::Expr qw(var op const);

my $observed = $engine->observational(var('outage'), var('replica_a'));
my $changed = $engine->interventional(var('outage'), {power => 0});
my $alternate = $engine->counterfactual(var('outage'), {power => 0}, var('outage'));
my $posterior = $engine->noise_posterior('baseline');
my $gradient = $engine->sensitivity('baseline');
my $joint = $engine->joint_worlds([
    {event => var('outage'), interventions => {disk_a => 0}},
    {event => op('not', var('outage')), interventions => {power => 0}},
], var('outage'));
```

`solve` also accepts an unnamed query object containing `event`, optional
`evidence`, optional `factual`, and `interventions`. Override independent priors
with `solve($query, priors => {...})`; the mapping must cover exactly every noise.
`distribution([NAMES], ...)` returns the exact joint binary distribution under
optional intervention and evidence. It is bounded because output grows as `2^n`.

## Independent backends and proofs

```perl
use Skein::Oracle;
use Skein::Eliminate;
use Skein::Certificate;

my $worlds = Skein::Oracle->new($model)->solve('baseline', ledger => 1);
my $factors = Skein::Eliminate->new($model)->solve('baseline');
my $proof = Skein::Certificate->create($engine, 'baseline');
my $checked = Skein::Certificate->verify($model, $proof);
```

The ledger includes zero-weight assignments. The certificate serializes
numerator and denominator diagrams, source identity, query, priors, exact
result, and dimensions. SHA-256 detects alteration; it does not authenticate
an author. Verification checks query semantics for every source world, including
zero-weight worlds. The checker never calls the symbolic compiler or weighted
counting engine. Creating a proof alone does not mean it was verified.

## Explanations and repairs

```perl
use Skein::Cutsets;
use Skein::Witness;
use Skein::Planner;
use Skein::Robust;
use Skein::Importance;

my $roots = $engine->compiler->query($model->query('baseline'));
my $cuts = Skein::Cutsets->new($engine->compiler->bdd, $roots->{numerator});
my $signed = $cuts->prime_implicants(limit => 1000);
my $map = Skein::Witness->new($engine)->explain('baseline');
my $frontier = Skein::Planner->new($engine)->plan('baseline', budget => 11);
my $box = Skein::Robust->new($engine)->bounds('baseline', include_vertices => 1);
my $allocation = Skein::Importance->new($engine)->shapley('baseline');
```

The rack's monotone minimal failure sets are `{power_noise}` and
`{disk_a_noise,disk_b_noise}`. They overlap in complete worlds. A minimal set
has no redundant positive literal; a signed prime implicant can also require
false literals. A MAP witness is a complete assignment, including irrelevant
noise variables and their prior contribution.

Planner options include `target`, `required`, `forbidden`, and a subset of
declared repairs. Existing query pins are preserved. Robust planning replaces
each candidate's risk with the maximum over the interval box. Shapley allocation
uses the cooperative game where unselected noises have prior zero and selected
noises retain nominal priors. It is not allocation of fitted observational effects.

## Adaptive diagnosis

```perl
use Skein::Policy;
use Skein::PolicyOracle;

my $diagnosis = Skein::Model->from_file('examples/diagnosis.sk');
my $solver = Skein::Policy->new(Skein::Engine->new($diagnosis));
my $policy = $solver->synthesize('baseline', budget => 12, failure_loss => 100);
my $replay = $solver->verify($policy);
my $reference = Skein::PolicyOracle->new($diagnosis)->solve(
    'baseline', budget => 12, failure_loss => 100);
```

The example's optimal expected cost is `7/2` with zero remaining failure risk.
A failure loss of one instead makes stopping without repair optimal. This is a
decision under a supplied model and cost function. Sensors read the original
world before any repair. Initial interventions are rejected; preexisting
observations belong in `factual(...)`.

## Causal response and physical systems

```perl
use Skein::Causal;
use Skein::Network;
use Skein::Mission;
use Skein::Util qw(decode_json_file);

my $response = Skein::Causal->new($engine)->response('power', var('outage'));
my $network = Skein::Network->new(decode_json_file('examples/bridge.json'));
my $network_model = $network->model;
my $physical_check = $network->verify;
my $mission = Skein::Mission->new(decode_json_file('examples/mission.json'));
my $temporal_model = $mission->build;
my $profile = $mission->profile;
```

Network JSON lists vertices, directedness, source, target, edge priors, and
optional shared domains. `mapping` maps physical names to generated endogenous
variables. An edge restoration pins its whole failure mechanism; isolating a
domain changes only the common cause. Mission JSON specifies initial failure,
per-step failure and repair probabilities, threshold, shocks, and optional
manually priced repair actions at particular ticks. Those declared actions do
not automatically run during the baseline mission.

## Exact algebra and reproducible sampling

```perl
use Skein::Polynomial;
use Skein::Spectrum;
use Skein::Sample;

my $polynomial = Skein::Polynomial->from_bdd($engine->compiler->bdd, $roots->{numerator});
my $derivative = $polynomial->derivative('power_noise');
my $spectrum = Skein::Spectrum->from_bdd($engine->compiler->bdd, $roots->{numerator});
my $sampler = Skein::Sample->new($engine, seed => 'experiment-1');
my $draws = $sampler->draws('had_isolated_power', 10);
my $estimate = $sampler->estimate('had_isolated_power', 1000);
```

Posterior sampling uses exact arbitrary-precision rational Bernoulli decisions
and rejection sampling from a deterministic SHA-256 counter stream. Identical
seeds and draw order reproduce the stream. This is an experimental sampler,
with no cryptographic-security claim. The estimator and its Wilson interval are
approximate; the exact query result is returned beside them.

## Output and errors

`Skein::Report->new($engine)->save(PATH)` creates an offline notebook.
`Skein::Render` writes SVG or DOT. JSON and text writers use a temporary file in
the output directory followed by rename. Outputs do not expose partially written
files after a normal failed write; this is not a durable storage protocol.

Library operations throw descriptive errors. CLI status zero means success,
two invalid input, three resource exhaustion, four impossible evidence, and
five rejected certificate verification. Catch exceptions where a particular
analysis is optional. Do not relabel an interrupted operation as a result.
