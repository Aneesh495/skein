# Language and semantics

## Model contract

A model has independent binary exogenous noises `U`, exact rational priors,
and binary endogenous variables in a directed acyclic graph. Every endogenous
variable is a deterministic Boolean expression of earlier variables. Forward
declarations are allowed; validation computes a topological order and rejects
cycles and missing dependencies.

An intervention changes an endogenous equation to a constant. All downstream
equations continue to execute. Exogenous variables cannot be intervention
targets. Changing a noise prior is a separate library operation.

For a complete noise assignment `u`, its probability is:

```text
w(u) = product_i p_i^u_i * (1-p_i)^(1-u_i)
```

Let `F(u)` denote the original world and `T_a(u)` the world under intervention
`a`. A query has an event `E`, changed-world evidence `G`, and factual evidence
`H`. Omitted evidence is true. The exact result is:

```text
N = sum_u w(u) * E(T_a(u)) * G(T_a(u)) * H(F(u))
D = sum_u w(u) * G(T_a(u)) * H(F(u))
P = N/D, provided D > 0
```

No independent noise is drawn for the target world. That coupling is essential
to a counterfactual. Zero evidence produces an error, including when the event
is false. A false event with positive evidence returns zero normally.

## Declarations

```text
model name;
title "A human-readable title";
noise u ~ 1/100;
node x = u;
query baseline = P(x);
repair replace = x=0 cost 3;
sensor alarm = x cost 1;
interval u = [1/200, 1/50];
order u;
```

Every declaration ends with a semicolon. `#` begins a comment through the end
of the line. Identifiers contain ASCII letters, digits, and underscores and
begin with a letter or underscore. They are case-sensitive. Strings support
`\"`, `\\`, `\n`, `\r`, and `\t`. Titles can contain Unicode.

Priors accept integer, fraction, or finite decimal literals. Decimal `0.1` means
the exact fraction `1/10`. Scientific notation, infinity, NaN, signs in source
probability tokens, and whitespace inside fractions are rejected. Priors must
lie in `[0,1]`; zero and one are valid.

Repairs pin a single endogenous variable and have nonnegative integer cost.
Sensors have a Boolean expression and nonnegative integer cost. Sensor names
and repair names are unique within their respective declaration kinds.
An interval must include the nominal prior and have ordered endpoints.
An explicit order must list each exogenous variable exactly once.

## Expressions

| Syntax | Meaning | Precedence, high to low |
|---|---|---:|
| `!a` | complement | 6 |
| `a & b` | conjunction | 5 |
| `a ^ b` | exclusive OR | 4 |
| `a \| b` | disjunction | 3 |
| `a -> b` | implication | 2 |
| `a <-> b` | equivalence | 1 |

Implication associates right. Other binary operators associate left.
Parentheses override precedence. Constants are `0` and `1`.

* `ite(condition, true_value, false_value)` selects one branch.
* `atleast(k, a, b, ...)` holds if at least `k` arguments hold.
* `exactly(k, a, b, ...)` holds if exactly `k` arguments hold.

Thresholds are integers between zero and the argument count. Repeated arguments
count repeatedly. Empty threshold expressions are allowed: `atleast(0)` and
`exactly(0)` are true. Arbitrary Perl evaluation is never used to interpret a
model. Function names and arities are validated.

## Observation, intervention, counterfactual

```text
query observation = P(y) given(x);
query intervention = P(y) do(x=1);
query counterfactual = P(y) do(x=1) factual(!y);
query mixed = P(y) given(z) factual(x) do(x=0);
```

`given(...)` is evaluated in the changed world. `factual(...)` is evaluated in
the original world. With no intervention, both refer to the same equations.
Clauses can appear in any order, once each. Multiple interventions inside one
`do(...)` are simultaneous. Pinning an ancestor and its descendant replaces both
equations, so the descendant stays pinned.

The confounding example demonstrates why conditioning on a treatment is not
the same operation as replacing its mechanism. The rack example demonstrates
why factual evidence must survive a repair in a counterfactual query.

## Normalized JSON

`perl bin/skein export MODEL` emits schema `skein.model/1`. Each AST node has an
`op` and the exact fields required by that operator. Unknown fields are errors.
Queries contain `event`, optional `evidence` and `factual`, and an
`interventions` map. Named model queries also require a `name`.

`Skein::Model` deep-copies supplied data, sorts declarations by name, reduces
priors, and hashes canonical UTF-8 JSON. Declaration order does not affect model
identity. The explicit BDD order, title, sensors, intervals, and repair costs do
affect identity. Equivalent Boolean formulas can still have different source
identities. Source identity is not logical equivalence.

`perl bin/skein source MODEL` emits deterministic editable source and preserves
optional clauses. The emitter and parser are checked by full model round trips.

## Scope and limits

| Resource | Default or fixed bound |
|---|---:|
| Source file | 4 MiB |
| Tokens | 200,000 |
| Identifier | 128 characters |
| Source rational token | 1,024 characters |
| Arithmetic result text | 65,536 characters |
| AST | 100,000 nodes, depth 128 |
| Parser nesting | 96 |
| Declarations of each kind | 4,096 |
| BDD variables | 4,096 |
| Allocated BDD nodes | 250,000 |
| One BDD operation | 2,000,000 work steps |
| Cached compiled worlds | 4,096 |
| Factor rows | 250,000 |
| Factor join operations | 2,000,000 |
| Exhaustive oracle | 16 noises, 65,536 worlds |
| Default certificate check | 16 noises |
| Report cross-check | 12 noises |
| Signed prime implicants | 256 noises |
| ZDD variables | 512 |
| Repair planner | 10 actions, 100,000 search states |
| Adaptive policy | 6 sensors, 10,000 belief states |
| Independent policy oracle | 8 noises, 6 sensors, 10 repairs |
| Prior-box robustness | 12 varying priors, 4,096 corners |
| Walsh spectrum | 16 noises |
| Markov chain | 64 states, requested horizon 256 |
| Mission | 16 processes, horizon 64, process names at most 100 characters |
| Physical network | 12 vertices, 256 edges, 64 fault domains |

Several bounds can be configured through the library within larger hard bounds.
`--max-nodes` sets the CLI diagram bound. A limit stops the operation and does
not turn an incomplete search into an optimum. Allocated BDD nodes include
retained intermediate functions; reachable nodes count the selected result.
There is no automatic diagram garbage collection or global order optimization.

Interval bounds assume independent priors in a rectangular box. They do not
describe arbitrary dependence uncertainty. Evidence must be positive at every
corner. Adaptive policies observe before any repair and use a per-realization
budget. Continuous variables, cyclic causal equations, inference of structural
equations from data, and continuous-time failure processes are outside scope.
