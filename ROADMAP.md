# Lambë roadmap

What we're working toward, what we're explicitly not, and why. Updated as releases ship; concrete issue tracking lives on GitHub.

## Scope and identity

Lambë is a **query language for structured data**, narrow on purpose. The goal is to make it as correct, elegant, and ergonomic as possible within that domain. Every design decision is measured against "does this make Lambë better at its job?" — not against "does this make Lambë more like jq" or "does this let Lambë do more."

The author's real programming-language projects (Fungal, Doxa) live elsewhere. Lambë is deliberately not one.

## 0.7.0 — shipped

Shape-gated completion and spec-driven op dispatch.

- **Shape-gated tab completion.** `.deps | <TAB>` where `.deps` is a map no longer offers list-only ops like `flatten` or `sort`. Only ops whose input-shape predicate accepts the inferred shape are shown.
- **Single source of truth for pipe-op metadata.** `lib/src/shape/pipe_ops.dart` owns, for each of the 27 ops: name, input-shape acceptance predicate, output-shape inference rule, and parse metadata (zero-arg / one-arg / custom grammar). The parser's alternatives are generated from this table; the completer's filter and `inferShape`'s pipe-op cases consult it. Adding a new op is one spec entry.
- **`inferShape` correctness fixes.** `flatten`/`sort`/`reverse`/`unique`/`filter_values`/`length` now widen to `SAny` when given a shape the runtime would reject, instead of returning the input unchanged. `--explain` on incompatible inputs reports the truth.
- **Consistency test matrix.** 162 cases × 27 ops pin every spec's acceptance predicate against the evaluator's actual runtime behavior. Drift between spec and evaluator fails loudly.
- **Completer replacement range.** `Completions` typedef gained `end`, so callers splice `[start, end)` preserving trailing whitespace.

One breaking change: the `Completions` typedef gained an `end` field (see CHANGELOG). All other additions are additive.

## 0.8.0 — next

Extend the shape story to sub-expressions and polish parser errors.

- **Inner-expression shape validation.** Today `.users | filter(.missing)` completes fine at the outer level, but `.missing` against the element shape is never flagged — the query ships a silently always-null predicate. With the shape machinery in place, the completer and `--explain` can report field access against a known-closed map shape as a definite miss, and inner-expression completion against parameterized ops can offer only fields that exist on the element shape. Same infra, more wiring.
- **Parser error recovery / multi-line diagnostics.** Rumil's `.recover()` already enables tolerant parsing for the REPL. One-shot CLI queries still get a single point-error. jq's multi-line traceback format (source line + caret + message) is a better experience; the deepest-error selection logic in `lib/lambe.dart` is close but needs better context and position tracking for nested contexts.

Both extend existing work. Natural bundle.

## 0.9.0 — direction, not commitment

The rule: sharpen Lambë within its scope. Don't widen. Any of the items below might land in 0.9.0, several, or none — this section describes the space, not a plan. Actual scope is decided by what users ask for and what proves worth the effort.

- **Schema-typed queries.** Users declare a schema for a CSV or JSON input once, and the shape tree carries that typing forever through the pipeline instead of re-inferring from sampled values. A `lam --schema file.schema query.lam data.csv` workflow that jq doesn't offer natively. Would compound on the 0.7.0 / 0.8.0 shape work.
- **Richer `--explain` output.** Per-stage warnings when inference loses precision, structured machine-readable mode for LLM tools, inline remediation hints.
- **ndjson at the CLI layer.** Line-delimited JSON: one document per line, evaluated independently, no shared state between lines. Covers the "tail a log" use case without requiring streaming in the core. Small CLI-layer feature (not a core change).

## Explicit non-goals

The tool is small *because* these are excluded.

- **Turing-completeness.** No `def`, no recursion, no lambdas. jq has these and regrets them — their presence is exactly what prevents static analysis, makes error messages vague, and turns "quick query" into "programming language to learn." Lambë's shape inference, `--explain`, and `as` bridging all work *because* Lambë is a bounded tree transformer. Staying bounded is a feature.
- **Streaming evaluation.** Two blockers: (1) the core is "AST over in-memory tree" — half the language (`sort`, `group_by`, `sum`, `unique`) cannot stream; building a parallel streaming pipeline would fork the semantics. (2) Rumil uses Warth seed-growth for left recursion, which requires the ability to re-parse a prefix as a seed grows. A streaming parser cannot rewind into a buffer it's already discarded. This is algorithmic, not a tuning knob. If streaming mattered enough, it would be a different project on a different parser.
- **jq feature parity.** Lambë was influenced by jq and borrows its pipeline aesthetic. It explicitly rejects jq's paths that undermine static analysis (programmability, implicit iteration, unbounded `def`). Migration friction from jq is acknowledged in `doc/jq-to-lambe.md`.
- **All things to all users.** If Lambë's shape is not enough to attract users for the task it's designed for, it becomes an example of how to implement such a tool plus something the author uses personally. That is an acceptable outcome.
