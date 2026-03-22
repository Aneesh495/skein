# Design notes and references

## A model of the same incident

Faults in a shared domain are a good place to make causal assumptions visible.
The primitive objects here are independent latent bits and deterministic
mechanisms. Correlated failures then emerge from shared ancestry instead of
being silently treated as independent component events.

I wanted an incident to remain the same incident while changing one mechanism.
That led to two compiled environments with one shared noise namespace. The
original environment filters possible latent realizations; the target
environment evaluates what the replacement mechanism would have produced.
The same representation extends naturally to paired response types, model
regressions, diagnosis, and interventions on internal network mechanisms.

Perl makes the boundaries visible: hashes for immutable contracts, bit strings
for sparse factor assignments, integer node identities, arbitrary-precision
rational arithmetic, and native text/SVG output. A small standard-library
footprint makes every demonstration reproducible without infrastructure.

## Composition rather than a new fundamental algorithm

ROBDDs, ZDDs, weighted model counting, variable elimination, potential outcomes,
and finite Markov chains have established literature. Skein does not claim to
have invented these algorithms. The experiment is their integration into a
small causal reliability language with explicit populations, shared-noise
counterfactuals, inspectable decisions, and several independent verification paths.

Some deliberate restrictions make the results easier to audit:

* Boolean acyclic mechanisms keep complete-world interpretation unambiguous.
* Independent rational noise priors make weighted mass exact and reproducible.
* Explicit resource budgets expose where a representation becomes expensive.
* An offline report carries its assumptions and evidence in one file.
* Complete small-model proof checking includes zero-weight worlds, which a
  probability-only comparison could miss.

These choices leave room for experiments with other variable orders, factor
elimination heuristics, continuous distributions, larger proof systems, or
continuous-time models. Those extensions would need their own semantics and
verification paths.

## References

* Randal E. Bryant, [Graph-Based Algorithms for Boolean Function Manipulation](https://www.cs.cmu.edu/~wklieber/15817-f08/ieeetc86.pdf),
  IEEE Transactions on Computers, 1986. Canonical ordered diagrams and Boolean
  operations are the foundation of the symbolic representation.
* Shin-ichi Minato, [Zero-Suppressed BDDs for Set Manipulation in Combinatorial Problems](https://doi.org/10.1145/157485.164890),
  DAC, 1993. The zero-suppression rule motivates compact families of literal sets.
* Alexander Balke and Judea Pearl, [Probabilistic Evaluation of Counterfactual Queries](https://arxiv.org/abs/1302.4929),
  UAI, 1994. Shared latent realizations provide the causal-world interpretation.
* [ADDMC](https://github.com/vardigroup/ADDMC), the authors' implementation of
  weighted model counting with algebraic decision diagrams. A related exact
  inference system with a different representation and problem interface.
* [Fault Trees and Binary Decision Diagrams](https://arxiv.org/abs/2310.04448).
  Relevant context for Boolean reliability representations and analysis.

The implementation is written for this repository. Dependencies are modules
shipped with Perl. References identify algorithmic context, not a claim that
Skein reproduces another project's performance or supports its full feature set.
