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

## 0.7.1 — shipped

UX polish on top of 0.7.0. Remediation suggestions now surface the intent-level `as(<format>)` form in every bridge-offering surface.

- **`as(<format>)` in error suggestions.** CLI errors, REPL prompts, MCP responses, and the playground now show `| as(csv)` / `| as(toml)` / etc. instead of `| to_entries` / `| {items: .}`. The explanation names the raw fragment underneath.
- **`Remediation.display` and `Remediation.template` decouple.** New `Remediation.withDisplay()` factory lets the display text differ from the runtime AST's source. Template still runs the raw fragment; `applyBridge()` consumers see no behavior change.
- **Curated template ASTs are parsed lazily on first use.** The four canonical sources are shared across format-parameterized factories instead of re-parsed on every shape error.

No breaking changes.

## 0.8.0 — shipped

Element-level shape checking for CSV/TSV output, static warnings for provably-empty filters, and line-aware parser diagnostics.

- **Element-level CSV/TSV shape via `MustBeFlatList`.** Non-scalar cells (list- or map-valued) are rejected with `OutputShapeError` instead of silently stringified through Dart's default `toString()`. Defensive `_scalarCell` guard in the writer catches cases where `SAny` lets the shape check pass (heterogeneous lists, sampling misses).
- **Union headers for heterogeneous list-of-maps.** `[{a:1}, {b:2}]` used to lose the `b` column silently. Writer now unions keys across all rows in first-seen order; missing keys render as empty cells. Matches pandas and Python's `csv.DictWriter` semantics.
- **Writer and shape-check consistency matrix.** 100 cases pin that `canWriteAs` and `formatOutput` agree on accept or reject. Structural complement to `pipe_ops_consistency_test.dart`; writer drift fails loudly.
- **`--explain` warnings for provably-empty filters.** `filter`, `filter_values`, and `filter_keys` all require `== true`. Two patterns make the op provably empty: a field path that doesn't exist on the element, value, or key shape, and a predicate whose inferred shape is any concrete non-boolean scalar. `SBool` and `SAny` never warn.
- **Line-aware parse diagnostics.** `line:column` header, source excerpt with line-number gutter, caret under the offending column, one line of context on either side for multi-line queries. Empty-expression produces a one-liner instead of a 30-token expected-list.

One breaking change: pipelines that relied on silent CSV garbage output now raise `OutputShapeError`. See CHANGELOG.

## 0.9.0 — direction, not commitment

The rule: sharpen Lambë within its scope. Don't widen. Any of the items below might land in 0.9.0, several, or none. Actual scope is decided by what users ask for and what proves worth the effort.

- **Schema-typed queries.** Users declare a schema for a CSV or JSON input once, and the shape tree carries that typing through the pipeline instead of re-inferring from sampled values. A `lam --schema file.schema query.lam data.csv` workflow that jq doesn't offer natively. Compounds on the 0.7.0 and 0.8.0 shape work.
- **Richer `--explain` output.** More warning categories beyond the single "provably-empty filter" class 0.8.0 ships: runtime-failure warnings (`filter` on a non-list input throws; flag statically), opt-in trivial-result warnings for `sort_by`, `group_by`, and `map` on missing fields (legitimate uses exist, so opt-in), and a structured machine-readable mode for tool integrations.
- **ndjson at the CLI layer.** Line-delimited JSON: one document per line, evaluated independently, no shared state between lines. Covers the "tail a log" use case without requiring streaming in the core. Small CLI-layer feature, not a core change.
- **CSV cell-flattening policy.** A `--flatten-cells json` flag that encodes nested structure as a JSON string in a CSV cell rather than refusing. Opt-in on the writer side; default behavior stays at 0.8.0's refuse-rather-than-garble.

## Explicit non-goals

The tool is small *because* these are excluded.

- **Turing-completeness.** No `def`, no recursion, no lambdas. jq has these and regrets them — their presence is exactly what prevents static analysis, makes error messages vague, and turns "quick query" into "programming language to learn." Lambë's shape inference, `--explain`, and `as` bridging all work *because* Lambë is a bounded tree transformer. Staying bounded is a feature.
- **Streaming evaluation.** Two blockers: (1) the core is "AST over in-memory tree" — half the language (`sort`, `group_by`, `sum`, `unique`) cannot stream; building a parallel streaming pipeline would fork the semantics. (2) Rumil uses Warth seed-growth for left recursion, which requires the ability to re-parse a prefix as a seed grows. A streaming parser cannot rewind into a buffer it's already discarded. This is algorithmic, not a tuning knob. If streaming mattered enough, it would be a different project on a different parser.
- **jq feature parity.** Lambë was influenced by jq and borrows its pipeline aesthetic. It explicitly rejects jq's paths that undermine static analysis (programmability, implicit iteration, unbounded `def`). Migration friction from jq is acknowledged in `doc/jq-to-lambe.md`.
- **All things to all users.** If Lambë's shape is not enough to attract users for the task it's designed for, it becomes an example of how to implement such a tool plus something the author uses personally. That is an acceptable outcome.
