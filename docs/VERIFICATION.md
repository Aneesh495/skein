# Verification and evidence

## Commands

| Command | Work performed | Output |
|---|---|---|
| `perl tools/check.pl` | Load every library, scan source conventions, run every test, execute examples and certificates | `.runtime/check.json`, raw TAP log |
| `perl tools/campaign.pl` | Seeded causal DAGs, all small Boolean functions, sampled set-family pairs | `.runtime/campaign.json` |
| `perl tools/bench.pl` | Fresh-manager repetitions of defined workloads and closed-form checks | `.runtime/benchmark.json` |
| `perl tools/fresh.pl` | Copy source into a clean temporary path with spaces, run real demo and complete check | `.runtime/fresh.json` |
| `perl tools/accept.pl` | Freeze source, perform tests, examples, campaign and benchmark, recheck source | `.runtime/acceptance.json` |
| `perl tools/verify.pl` | Check published receipt integrity and current source, replay example certificates | Structured verification result |
| `perl tools/package.pl` | Create archive and compare every archived byte and path to source | `.runtime/Skein-0.1.0.tar.gz`, package record |

All commands use the running Perl interpreter and core modules. Tools find the
repository relative to their own location. Model paths supplied to the CLI are
relative to the current working directory. Generated output is excluded from
source identity by an explicit inventory policy.

## Acceptance receipt

The committed receipt is `evidence/acceptance.json`. Its envelope contains a
canonical SHA-256 of the payload. The payload contains:

* Every source file path, byte length, and SHA-256.
* The source inventory policy and aggregate source hash.
* Individual test-file statuses, assertion counts, exits, and parser errors.
* Exact results and complete-world certificates for every supplied source model.
* The seeded campaign's case digests, results, invariant counts, and rolling receipt.
* Every benchmark repetition, environment, exact answer, or explicit bound.

The source inventory includes documentation and workflow configuration. An
added file, removed file, changed test, or edited source invalidates the receipt.
Runtime, build, Git metadata, and evidence outputs are excluded to avoid circular
hashes. The distribution's `MANIFEST` is included. Its reserved receipt path is
established before acceptance generation.

The tracked `.gitattributes` pins text checkout bytes to LF on every platform.
It is part of source identity, and CI verifies the published receipt on each OS.
This keeps Git's `core.autocrlf` preference from changing the receipt's input.

```sh
perl tools/verify.pl
perl tools/accept.pl --out .runtime/acceptance.json
perl tools/verify.pl .runtime/acceptance.json
```

The lightweight verifier replays source-world example certificates and validates
source bytes and envelope integrity. It does not independently infer that every
reported test ran. Reproduce the expensive work with `accept.pl`, or reproduce
the campaign with its recorded seed and dimensions. These are unsigned receipts,
not authenticated attestations. Rehashing fabricated output cannot create an
authenticity guarantee.

## Verification layers

1. Arithmetic tests check exact normalization, zero operations, long intermediate
   fractions, mutation isolation, and nonfinite input refusal.
2. Boolean tests exhaust complete small truth-function spaces, arbitrary gate
   tables, prime families, quantified functions, and reordered diagrams.
3. Causal tests compare joint masses and populations across BDDs, independently
   lowered sparse factors, and directly interpreted worlds.
4. Differential tests include zero and one priors, internal interventions,
   contradictory evidence, both conditioning worlds, and dependent thresholds.
5. Metamorphic tests check alpha-renaming, declaration permutation, source
   round trips, conditional derivatives, and interval-box interiors.
6. Policy tests compare optima with an explicit-world solver and replay execution
   separately. Costs, repeated sensors, action conflicts, and per-world budgets
   are checked.
7. Physical-network tests compare symbolic connectivity with BFS. Temporal tests
   compare mission outcomes with Markov chains and first-passage identities.
8. Adversarial certificates include rehashed numeric forgeries, false truth
   functions with unchanged zero-weight mass, changed dimensions, rank corruption,
   and invalid query mechanisms.
9. Process tests invoke the real CLI outside the checkout and exercise every
   command, output writer, and failure exit status.
10. Fresh-copy and package checks remove reliance on runtime artifacts and compare
    actual distributed bytes. Hosted CI exercises different interpreters and OSes.

This is evidence about tested behavior. It cannot prove the absence of every
possible implementation error or validate assumptions about a real system.

## Campaign reproduction

```sh
perl tools/campaign.pl --cases 128 --families 2048 --seed skein.frozen/1
```

Each causal case has a stable source emitter, independent priors including
boundary values, reconvergent Boolean equations, and five query kinds.
Every successful query compares `N`, `D`, and `N/D`; impossible populations must
agree across all backends. Sampling verifies evidence in source worlds. MAP
masses, gradients, polynomials, spectra, repair optima, and paired responses
receive separate checks.

All 256 three-variable functions are tested. Prime completeness is checked by
enumerating every ternary cube and testing every matching complete assignment.
The family phase compares ZDD operations with explicit subset bit masks.
Use `--families 65536` to check every ordered pair of three-element set families.
An invariant failure writes `.runtime/failure.json` and, for a causal model,
`.runtime/failure.sk`. The failure records seed, phase, case, and assertion count.
Warnings during a campaign are treated as failures.

## Benchmark interpretation

The default suite uses 256-noise prefix chains for OR, AND, and parity, a
32-input threshold, sixteen shared domains with four replicas each, and two
multiplexers. Exact closed forms are derived in `Skein::Workload` and checked
against small independently executed worlds in the test suite.

Each repetition constructs a fresh manager. Timing includes compilation and
counting. Every repetition is retained. CPU time uses Perl's process counters;
elapsed time uses `Time::HiRes`. The receipt identifies OS, Perl, architecture,
integer width, and arbitrary-precision integer backend. No warmup is dropped.

Allocated nodes include cached intermediate prefix functions. Reachable nodes
measure the queried roots. Their difference is meaningful: the manager retains
intermediates and has no garbage collection. The data-first multiplexer exposes
order sensitivity and can exhaust the node bound. A bound is recorded without a
fabricated probability or timing extrapolation.

Results apply to the named workloads and measured machine. They do not establish
general throughput, latency under service load, comparative language performance,
or superiority over specialized inference engines.

## Offline report inspection

The report is checked for title escaping, absence of remote resources and
scripts, complete analysis statuses, and preserved snapshots. It was also
visually inspected in a browser at desktop width and a 390-pixel phone viewport.
Tables and diagrams scroll inside their containers. The document has no page
overflow at that phone width, and SVG identifiers do not collide.

Large or undefined analyses appear as unavailable with a reason. A report for
more than twelve noises explicitly marks queries as symbolic-only rather than
pretending exhaustive verification occurred. The report is an explanation of
the supplied model, not a dashboard fed by hidden services.
