# Build plan

Skein studies Boolean structural causal models of shared failure domains.
Independent exogenous noise variables have exact rational priors. Endogenous
variables are acyclic deterministic Boolean equations. Observation conditions
the factual world. Intervention replaces equations. Counterfactual inference
keeps factual evidence and evaluates the changed world using the same noise.

## Implementation sequence

1. Repository contracts and reproducible commands.
2. Exact arithmetic and bounded canonical I/O.
3. Directed graph analysis.
4. Boolean expressions and reference evaluation.
5. Source lexer and diagnostics.
6. Model language parser.
7. Validated structural models.
8. Reduced ordered binary decision diagram manager.
9. Quantification, substitution, and diagram inspection.
10. Exact weighted counting and derivatives.
11. Shared-noise world compilation.
12. Observation, intervention, and counterfactual inference.
13. Independent exhaustive semantic oracle.
14. Sparse factors and joins.
15. Independent variable elimination backend.
16. Zero-suppressed set diagrams.
17. Minimal cut sets and Boolean explanation.
18. Posterior witnesses and structural traces.
19. Sensitivity and importance analysis.
20. Exact repair frontier search.
21. Interval-prior robustness.
22. Model comparison and ordering experiments.
23. Portable CLI and offline examples.
24. Result certificates and independent verification.
25. DOT, SVG, and static report generation in Perl.
26. Seeded differential and malformed-input campaigns.
27. Benchmark and source-bound acceptance artifacts.
28. Packaging, Linux/macOS/Windows CI, documentation.
29. Clean checkout verification and regression hardening.
30. Final frozen acceptance and publication.

Each checkpoint gets its own commit. Additional corrective commits are normal.
All runtime, analysis, rendering, tests, and evidence tooling are written in
Perl using modules shipped with Perl. No solver binaries, Python numerical
libraries, browser service, or network connection are required to run examples.

## Verification contract

* Compare decision diagram inference to independently evaluated worlds.
* Compare sparse elimination to both inference and enumeration.
* Check canonical diagram invariants after transformations.
* Reject impossible evidence instead of inventing a probability.
* Verify certificates against the supplied source model, including exact mass.
* Exercise interventions on internal nodes and shared-noise counterfactuals.
* Differentially test all gates, variable orders, and small random DAGs.
* Exercise explicit node, factor, world, and search limits.
* Test CLI errors, file corruption, and portable packaging from a clean copy.
* Hash acceptance inputs and outputs; reject stale or altered evidence.

Exact inference is exponential in the worst case. Limits fail explicitly.
These are specified synthetic structural models, not causal identification
from observational data. Benchmarks report actual workloads and elapsed time.
