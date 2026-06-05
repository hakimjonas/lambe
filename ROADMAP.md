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

## Distribution and install ergonomics

A separate axis from the language roadmap above: how people *get* `lam`, not what it does. The aim is to make the reflexive install command work on every platform a colleague reaches for. Sequenced easy-and-free first; the only deferred work is the part behind a paywall.

**Funding principle.** Lambë is unfunded FOSS. Anything with a recurring cost stays parked unless that changes. Free tiers cover the install paths that ~95% of users actually use, so the paid work is polish on the long tail, not a blocker.

### Tier 1 — trivial, free, ship immediately

- **macOS Gatekeeper note.** A one-line `xattr -d com.apple.quarantine ./lam` remedy in `doc/getting-started.md` for the browser-download path. Costs nothing, unblocks the only mac users who currently hit a wall.
- **`install.sh` messaging.** The script advertises Scoop (`install.sh`) before a Scoop manifest exists. Point users only at channels that are real until Tier 2 lands.

### Tier 2 — the mac/Windows ergonomics win (free, moderate effort)

- **Homebrew tap.** A `hakimjonas/homebrew-lambe` repo with `Formula/lambe.rb` that installs the prebuilt macOS binaries (no Dart toolchain needed), shell completions, and the man page; `release.yml` auto-bumps version + SHA256 on each tag from the checksums it already computes. Gets colleagues to `brew install hakimjonas/lambe/lambe`. **Highest-impact item for the stated mac goal** — and Homebrew strips the quarantine xattr, so it sidesteps Gatekeeper entirely.
- **Scoop manifest.** A `lambe.json` manifest (in-repo bucket or a small bucket repo), auto-bumped the same way. Gets Windows users to `scoop install lambe` and makes good on the `install.sh` promise.

### Tier 3 — provenance and discoverability (free)

- **Shell completions.** A `lam --completions {bash,zsh,fish}` subcommand, shipped as release assets and placed by the tap / `install.sh`. Completing the fixed-enum flags (`--to`, `--format`, `--flatten-cells`) teaches the format names without a docs trip.
- **Build-provenance attestations.** `actions/attest-build-provenance` in `release.yml` — a free, verifiable supply-chain belt (`gh attestation verify lam-macos-arm64 --repo hakimjonas/lambe`) that's stronger than detached PGP for CI-built binaries. Complements the existing `checksums.txt`. Note: this is *provenance*, not OS code signing — it does not silence Gatekeeper/SmartScreen.

### Tier 4 — parked behind the paywall (deferred, not scheduled)

OS-enforced code signing is the only thing that silences Gatekeeper / SmartScreen automatically, and it is the only work here with a recurring bill. Deferred while Lambë is unfunded.

- **macOS:** Apple Developer Program ($99/yr) + Developer ID signing + notarization, wrapped in a `.pkg`/`.dmg` (bare CLI binaries cannot be notarization-stapled).
- **Windows:** Authenticode signing — EV cert (~$300–700/yr) or Azure Trusted Signing (~$10/mo) for SmartScreen reputation.

Both buy only the *browser-download* path; Homebrew, the curl installer, and Scoop already strip the quarantine/mark-of-the-web friction for everyone else. Revisit only if funding appears (sponsorship) or if browser-download UX becomes a genuine, recurring complaint.

## Explicit non-goals

The tool is small *because* these are excluded.

- **Turing-completeness.** No `def`, no recursion, no lambdas. jq has these and regrets them — their presence is exactly what prevents static analysis, makes error messages vague, and turns "quick query" into "programming language to learn." Lambë's shape inference, `--explain`, and `as` bridging all work *because* Lambë is a bounded tree transformer. Staying bounded is a feature.
- **Streaming evaluation.** Two blockers: (1) the core is "AST over in-memory tree" — half the language (`sort`, `group_by`, `sum`, `unique`) cannot stream; building a parallel streaming pipeline would fork the semantics. (2) Rumil's format parsers are backtracking combinator parsers that need random access to the whole input — an alternative can fail deep in and rewind — so they read the full document into a buffer rather than consuming a forward-only stream. This is algorithmic, not a tuning knob. If streaming mattered enough, it would be a different project on a different parser.
- **jq feature parity.** Lambë was influenced by jq and borrows its pipeline aesthetic. It explicitly rejects jq's paths that undermine static analysis (programmability, implicit iteration, unbounded `def`). Migration friction from jq is acknowledged in `doc/jq-to-lambe.md`.
- **All things to all users.** If Lambë's shape is not enough to attract users for the task it's designed for, it becomes an example of how to implement such a tool plus something the author uses personally. That is an acceptable outcome.
