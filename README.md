# skein

An exact causal reliability lab, written in Perl.

Two replicas can fail together because they share a power supply. After an
outage, replacing a disk and isolating the power domain answer very different
counterfactual questions. Skein keeps the shared causes explicit, computes the
answers as rational numbers, and produces evidence you can inspect and replay.

The question that started this project was: **given that this system failed,
what would have happened to the same system if one mechanism had changed?**

## Run it

Perl 5.20 or newer, with its standard library. No CPAN installation, native
solver, database, account, dataset download, or network connection is needed.
The runtime, parsers, inference algorithms, graphics, tests, and verification
tools are all Perl.

```sh
git clone https://github.com/Aneesh495/skein.git
cd skein
perl bin/skein demo
perl tools/check.pl
```

The demo checks three inference implementations and writes
`.runtime/demo.html`. Open that file in any modern browser. It is an offline
research notebook with native SVG diagrams, exact results, repair frontiers,
uncertainty bounds, and expandable evidence. It contains no JavaScript or remote
assets. The same commands work in PowerShell and a Unix shell.

The check command runs the full suite and every supplied model. Its raw TAP log
is `.runtime/tests.tap.txt`. The first command is a short demonstration; the full
check also exhausts small Boolean functions and can take a few minutes.

## A small model with an uncomfortable dependency

```text
noise power_noise ~ 1/100;
noise disk_a_noise ~ 1/50;
noise disk_b_noise ~ 1/50;
node power = power_noise;
node disk_a = disk_a_noise;
node disk_b = disk_b_noise;
node replica_a = power | disk_a;
node replica_b = power | disk_b;
node outage = replica_a & replica_b;

query baseline = P(outage);
query repaired_power = P(outage) do(power=0);
query had_isolated_power = P(outage) do(power=0) factual(outage);
query had_repaired_a = P(outage) do(disk_a=0) factual(outage);
```

The complete [rack example](examples/rack.sk) adds observations, repair costs,
sensors, interval priors, and an explicit variable order.

| Question | Exact probability |
|---|---:|
| Does the rack fail? | `2599/250000` |
| Does it fail with the power equation pinned false? | `1/2500` |
| Given an actual outage, would isolating power have left it failed? | `100/2599` |
| Given an actual outage, would replacing disk A have left it failed? | `2500/2599` |

The last two queries condition on the original outage and reuse its latent
noise in the changed world. Replacing a disk rarely resolves a failure whose
posterior explanation is a shared power fault. These fractions come from the
specified model; they are recomputed by the demo and acceptance suite.

```sh
perl bin/skein run examples/rack.sk --backend bdd
perl bin/skein run examples/rack.sk --backend factor
perl bin/skein run examples/rack.sk --backend oracle
perl bin/skein explain examples/rack.sk had_isolated_power
```

## What is inside

| Layer | Implementation |
|---|---|
| Language | Bounded lexer, Pratt parser, validated Boolean AST, deterministic source emitter |
| Causal model | Immutable DAG, shared independent exogenous variables, replaced endogenous equations |
| Symbolic inference | Canonical ROBDDs, iterative apply, ITE, thresholds, substitution, quantification, reordered transfer |
| Exact probability | Arbitrary-precision rationals, weighted counting, reverse-mode gradients, posterior marginals |
| Independent inference | Sparse gate factors and min-fill bucket elimination; complete source-world enumeration |
| Explanations | ZDD antichains, monotone minimal cut sets, complete signed prime implicants, MAP and nearest witnesses |
| Decisions | Complete repair Pareto frontiers, interval-prior worst-case planning, adaptive sensor policies |
| Causal response | Paired potential outcomes, principal response strata, necessity and sufficiency |
| Temporal reliability | Shared-shock mission unrolling, exact Markov chains, first passage, rewards, hitting times |
| Network reliability | Physical cycles expanded into acyclic reachability stages; shared edge fault domains |
| Algebra | Multilinear reliability polynomials, exact Walsh spectra, uniform influence and noise stability |
| Reproducibility | Seeded posterior draws, model coupling, source-bound acceptance receipts, complete truth-function certificates |
| Presentation | Perl-generated DOT, SVG, and standalone HTML |

All three inference backends agree on the probability, joint numerator, and
evidence denominator. They use separate Boolean evaluators. The certificate
checker executes source worlds and compares the entire diagram truth function,
including worlds with zero prior weight.

## Experiments

```sh
# Minimal explanations and sensitivity
perl bin/skein cuts examples/rack.sk
perl bin/skein cuts examples/voter.sk --signed
perl bin/skein importance examples/rack.sk --shapley
perl bin/skein polynomial examples/rack.sk
perl bin/skein spectrum examples/rack.sk

# A complete cost and residual-risk frontier
perl bin/skein plan examples/rack.sk --budget 11 --target 0
perl bin/skein plan examples/rack.sk --budget 11 --robust
perl bin/skein bounds examples/rack.sk

# An adaptive policy that observes before selecting repairs
perl bin/skein policy examples/diagnosis.sk --budget 12 --loss 100

# Paired potential-outcome response types
perl bin/skein effect examples/rack.sk power outage

# Cyclic connectivity with a shared flood domain
perl bin/skein network examples/bridge.json --out .runtime/bridge.sk
perl bin/skein run .runtime/bridge.sk
perl bin/skein report .runtime/bridge.sk --out .runtime/bridge.html

# Time-dependent failure, repair, and common shocks
perl bin/skein mission examples/mission.json
perl bin/skein markov examples/availability.json

# Create and independently check a source-world certificate
perl bin/skein certificate examples/rack.sk had_isolated_power --out .runtime/proof.json
perl bin/skein verify examples/rack.sk .runtime/proof.json
```

Use `--json` for complete structured output, `--out PATH` to save it atomically,
and `--expr 'BOOLEAN'` to supply an event expression. `perl bin/skein --help`
lists every command and exit status.

## Verification and measured limits

```sh
perl tools/check.pl
perl tools/campaign.pl --cases 128 --families 2048
perl tools/bench.pl
perl tools/fresh.pl
perl tools/verify.pl
```

The checked-in [acceptance receipt](evidence/acceptance.json) binds the source
inventory to test records, randomized cases, complete-world certificates, and
raw benchmark repetitions. `verify.pl` detects changed source and rechecks the
example certificates. It does not rerun the expensive campaign. To regenerate
the entire receipt, run `perl tools/accept.pl --out .runtime/acceptance.json`.

Benchmarks include prefix chains, parity, a voting threshold, shared domains,
and multiplexers under sharply different orders. Every solved result is checked
against an exact closed form. Exhausting a node budget produces a recorded
`resource_bound` result. Raw timings include compilation and counting, retain
every repetition, and identify the interpreter and arithmetic backend.

The [CI workflow](.github/workflows/check.yml) checks Perl 5.20, 5.34, and 5.40
across Linux, macOS, and Windows. It runs the complete suite, examples, a seeded
campaign, bounded benchmarks, and byte-verified archive packaging.

Exact inference can require exponential space or time. Skein makes no causal
identification claim: the equations and independent priors are assumptions.
Adaptive diagnosis observes factual sensors before any repair. Prior-box bounds
require positive evidence at every corner. Limits and undefined populations are
reported explicitly. See [scope and limits](docs/SEMANTICS.md#scope-and-limits).

## Read the implementation

* [Language and query semantics](docs/SEMANTICS.md)
* [Algorithms and invariants](docs/ALGORITHMS.md)
* [Library API and worked experiments](docs/API.md)
* [Evidence, verification, and benchmark methodology](docs/VERIFICATION.md)
* [Design notes and references](docs/RESEARCH.md)
* [Contributing and packaging](docs/DEVELOPMENT.md)
* [Implementation sequence](docs/PLAN.md)

MIT license.
