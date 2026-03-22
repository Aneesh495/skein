# Development and packaging

## Repository layout

```text
bin/skein             portable command entry point
lib/Skein/            language, inference, decisions, algebra, reports
lib/Skein/BDD/        transformations and exact counting
t/                    direct, property, differential and process tests
examples/             small causal models and physical specifications
tools/                checks, campaigns, acceptance and packaging
docs/                 semantics, algorithms, API and evidence methodology
evidence/             generated public receipts and offline notebook
.runtime/             ignored local outputs
```

Keep numerical results exact until a display approximation is requested.
`Math::BigRat` is mutable; use `Skein::Rat` helpers or copy values before changing
them. A BigRat operation can have different list-context behavior, so arithmetic
helpers return one scalar value. Do not store a caller's mutable AST or model
object as an unvalidated contract.

Library inputs must report invalid shapes and resource exhaustion explicitly.
Avoid `eval` on model text. Resource limits are algorithmic contracts, not a
reason to return partial optima. Independent reference implementations must not
call the implementation they are supposed to check.

## Run focused checks

```sh
prove -Ilib t/14-elimination.t
prove -Ilib t/40-policy-oracle.t
perl tools/check.pl
```

The suite uses core `Test::More`, `TAP::Harness`, `File::Temp`, and deterministic
seeds. A failed campaign retains the full model. Add the failure as a regression
case and fix the implementation; do not change the seed to avoid it.

## Package

```sh
perl tools/package.pl --manifest
perl tools/accept.pl --out evidence/acceptance.json
perl tools/package.pl
```

The manifest reserves the acceptance receipt before its generation. Packaging
includes source and evidence, excludes runtime state, assigns fixed archive
member metadata, and verifies each archived byte against its source hash.
The gzip container itself is not promised byte-identical across Perl versions.

An optional conventional Perl-module installation is also supported:

```sh
perl Makefile.PL
make test
make install
```

The direct checkout commands require no `make`. On Windows, the installation
command depends on the make tool bundled with the Perl distribution. Core
library dependencies are listed in `Makefile.PL`; no XS extension is compiled.
The installed CLI embeds the complete offline demonstration model.

## Freeze evidence after edits

Any source, test, doc, workflow, or manifest edit invalidates prior acceptance.
Finish changes first, regenerate the receipt, then verify it against the exact
source that will be published. Generated evidence is excluded from the source
inventory to prevent a circular hash. Preserve raw repetitions and negative
resource-bound results. Do not insert claims inferred from a different workload.

CI actions are pinned to official commit revisions. Its scripts use Perl as the
shell so Windows and Unix run the same process invocation logic. New model
capabilities should receive source-world checks wherever exhaustive evaluation
is practical, plus an explicit explanation of the unchecked larger-model scope.
