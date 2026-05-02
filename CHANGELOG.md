## 0.9.0-dev

In progress.

### Added

- **Richer `--explain` output.** Three new categories of static
  analysis, plus a structured output mode:
  - **Runtime-rejection warnings** (always on): flags pipe ops whose
    input shape is provably incompatible. `.config | filter(.x)` on a
    known map produces "filter rejects map<...>; this will throw at
    runtime." The existing pipe-op acceptance predicates in
    `pipe_ops.dart` supply the check; `explain` surfaces it.
  - **Trivial-result warnings** (opt-in via `--explain-trivial`):
    flags `sort_by`, `group_by`, `map`, and `unique_by` whose
    argument references a field provably absent on the element shape.
    Often a typo but legitimate uses exist (stable no-op sort,
    explicit null projection), hence opt-in.
  - **Structured JSON output** (`--explain-json`): emits the full
    explain report as JSON with snake_case keys
    (`stages`, `warnings`, `writable_as`, `not_writable_as`,
    `flatten_cells`). Warning kinds serialize as `empty_filter`,
    `runtime_rejection`, `trivial_result`. For agent tooling and
    build-pipeline integration.
- **`ExplainWarning.kind`** (new field, [`WarningKind`] enum).
  Classifier for filtering: CLI, JSON consumers, and future tooling
  can select warning categories without parsing message strings. The
  existing `emptyFilter` case carries the kind it always had.
- **`renderExplainJson`** library function: produces the JSON report.
- Both `--explain-trivial` and `--explain-json` imply `--explain`,
  following the pattern of `--ndjson` being a non-combinable mode.
- **`--ndjson` mode for line-delimited JSON input.** Each line of the
  source is parsed as an independent JSON document, the query is
  evaluated per line with no shared state, and one compact JSON
  result is emitted per line. Auto-enabled when the file extension is
  `.ndjson` or `.jsonl`. Fail-fast on the first malformed or
  unevaluable line; the line number is carried in the error. Covers
  the "tail a log" use case without touching the core "AST over
  in-memory tree" model. Available as a new top-level `queryNdjson`
  function on the library (`Iterable<String> -> Iterable<Object?>`).
  Cannot combine with `--interactive`, `--schema`, `--assert`, or
  `--explain`; output is restricted to JSON.
- **`--flatten-cells` option for CSV/TSV output.** Accepts `refuse`
  (default, 0.8.0 behavior) or `json`. Under `json`, non-scalar cells
  are encoded as JSON strings inline; the shape check widens
  `MustBeFlatList` to `MustBeList` for csv/tsv. Available in the CLI
  (`--flatten-cells`), the REPL (`:flatten-cells`), the MCP server
  (`flatten_cells` parameter), and as a `CellPolicy flattenCells`
  named parameter on `formatOutput`, `canWriteAs`, `canWriteShapeAs`,
  `requirementFor`, and `explain`. Round-tripping the resulting CSV
  back into Lambë does not recover the original structure; this is
  an output-side escape hatch, not a faithful encoding.
- **`NotWritable.hints`.** A list of strings surfacing environmental
  guidance (flags, settings) relevant to the mismatch. The first such
  hint covers the `--flatten-cells json` escape hatch: when a
  CSV/TSV request rejects under `refuse` but a list root is already
  present, the hint points at the equivalent CLI flag, REPL command,
  and MCP parameter. Uniform channel across CLI, REPL, and MCP so
  tools don't re-derive the condition.
- **`ExplainReport.flattenCells`.** The cell policy the report was
  generated under. `renderExplain` prints `Cell policy: json` as a
  footer when non-default; default output is byte-for-byte unchanged.

## 0.8.0

Adds element-level shape checking for CSV/TSV output, union headers
across heterogeneous-keyed rows, static warnings for provably-empty
filters in `--explain`, and line-aware parser diagnostics.

### Added

- **Element-level CSV/TSV shape check via `MustBeFlatList`.** The
  new requirement class walks the element shape of the outer list
  and accepts three forms: `SList<scalar>`, `SList<SList<scalar>>`,
  and `SList<SMap<k:scalar, ...>>`. A list of maps with list- or
  map-valued cells now raises `OutputShapeError` instead of being
  serialized through Dart's default `toString()`. `MustBeList` is
  retained as the generic list-root requirement for future format
  additions whose serialization tolerates any element shape.
  Exported from `package:lambe/lambe.dart`.
- **Defensive cell guard in the CSV/TSV writer.** For cases where
  shape inference loses precision (heterogeneous list elements
  collapse to `SList<SAny>`, which the shape check cannot prove
  incompatible), a non-scalar cell that reaches the serializer
  throws `QueryError` with a descriptive type name rather than
  silently stringifying.
- **Union headers across heterogeneous-keyed rows.** The writer
  previously took headers from the first row only, so
  `[{a:1}, {b:2}]` produced `"a\n1\n"` and the `b` column was
  silently dropped. Headers are now the union of keys across all
  rows in first-seen order; rows missing a key render as an empty
  cell. Matches pandas and Python's `csv.DictWriter` semantics.
- **Writer and shape-check consistency matrix.**
  `test/shape_output_consistency_test.dart` pins the invariant
  across 100 cases: `canWriteAs(v, fmt) == Writable` implies
  `formatOutput` does not raise `OutputShapeError`; `NotWritable`
  always raises it. Structural complement to
  `pipe_ops_consistency_test.dart`; writer drift fails loudly.
- **`--explain` warnings for provably-empty filters.** `filter`,
  `filter_values`, and `filter_keys` reject elements whose predicate
  is not `== true`. Two patterns make the op provably empty: a
  predicate whose field path doesn't exist on the element, value,
  or key shape; and a predicate whose inferred shape is any
  concrete non-boolean scalar. The explain report now carries a
  `warnings` list and `renderExplain` prints it between stages and
  writability. `SBool` and `SAny` predicates never warn: either
  might be true. New `ExplainWarning` type exported from
  `package:lambe/lambe.dart`.

### Changed

- **Parser errors are line-aware with source context.** Error
  messages lead with `line:column` instead of just `column`, show
  the offending line in a gutter-prefixed excerpt with a caret
  under the bad column, and include one line of context on either
  side for multi-line queries. The "did you mean" hint for
  mistyped pipe ops is preserved. `Location.line` was always
  available on Rumil's `ParseError`; the previous renderer assumed
  single-line input and rendered the caret against the full
  expression, which put it on the wrong visual line for any
  multi-line query.
- **Empty-expression parse error is actionable.** Running
  `lam '' file.json` previously dumped the parser's full list of
  expected tokens (around 30 items) and buried the actual problem.
  It now returns a single line: `parse error: expression is empty`.
  Same treatment for whitespace-only and newline-only input.
- **`--explain` CLI path uses the line-aware diagnostic.**
  Previously it printed `Error: failed to parse query` and skipped
  the excerpt that `--to` had access to. Both paths now go through
  `parseAst`.
- **`requirementFor(OutputFormat.csv)` and
  `requirementFor(OutputFormat.tsv)` return `MustBeFlatList`
  instead of `MustBeList`.** Downstream code that pattern-matches
  `is MustBeList` on `NotWritable.required` will flip
  `true` to `false`.
- **MCP server `Error: $e` callsites rewritten to `e.message`.**
  Three sites in `bin/mcp_server.dart` previously produced
  `Error: QueryError: parse error at line ...`; the `QueryError:`
  prefix doubled the CLI's `Error:` prefix.
- **`ExplainReport` constructor gains an optional `warnings`
  parameter.** Defaults to `const []`, so existing callers that
  pass `stages`, `writableAs`, and `notWritableAs` compile and
  behave unchanged.

### Breaking

- **Queries that relied on the silent CSV/TSV garbage output now
  raise `OutputShapeError`.** Pipelines like
  `.deps | as(csv) | as(toml) | as(csv)` used to emit a CSV cell
  like `"[{key: rumil, value: ^0.6.0}, ...]"` (Dart's default
  `List<Map>.toString()`). They now raise `OutputShapeError` with
  the shape that failed the check. Convert the shape before the
  final `as(csv)` (for example project inner lists to strings), or
  use a different output format.
- **Writer output for heterogeneous-keyed list-of-maps changes.**
  `[{a:1}, {b:2}]` now serializes to `"a,b\n1,\n,2\n"` instead of
  `"a\n1\n"`. Row 1 renders an empty cell for `b`, row 2 renders
  an empty cell for `a`. Code that produced correct output on
  homogeneous-keyed input is unaffected.

## 0.7.1

Polish release on top of 0.7.0. Error-message remediation
suggestions now surface the intent-level `as(<format>)` form,
aligning every bridge-offering surface (CLI, REPL, MCP, playground)
with the 0.6.0 shape story. The template that runs is unchanged,
so the composed `$expression | as(csv)` query produces the same
result as before.

### Changed

- **Error suggestions use `as(<format>)` as the display form.** The
  suggestion shown in CLI errors, REPL prompts, MCP responses, and
  the playground is now `| as(csv)` / `| as(toml)` / etc. instead
  of the raw `| to_entries` / `| {items: .}` fragment. The
  explanation names the underlying mechanism for transparency —
  e.g. "Wraps each map entry as a {key, value} row (equivalent to
  `to_entries`)".
- **`Remediation.display` and `Remediation.template` can now
  differ.** The `Remediation()` constructor still sets
  `display = source`. A new `Remediation.withDisplay()` factory
  decouples them, used internally to surface `as(<format>)` while
  the runtime AST stays as the raw fragment. Callers that only
  read `Remediation.template` (e.g. through `applyBridge()`) see
  no behavior change.
- **Curated template ASTs are parsed lazily on first use.** The
  four canonical sources (`{items: .}`, `{value: .}`, `to_entries`,
  `{value: .} | to_entries`) are parsed once per isolate and
  shared across format-parameterized factories, instead of
  re-parsing on every shape error.

## 0.7.0

Shape-gated tab completion, single-source-of-truth pipe-op metadata,
and `inferShape` correctness fixes. Builds on the 0.6.0 shape work:
the completer now uses the same shape machinery that powers
`--explain` and `as(fmt)` to hide candidates that would throw at
runtime.

### Added

- **Shape-gated pipe-op completion.** `.x | <TAB>` filters the
  candidate list by the inferred input shape. A map input hides
  list-only ops (`flatten`, `sort`, `sum`, `first`); a list input
  hides map-only ops (`filter_keys`, `has`, `map_values`,
  `to_entries`). Ops that accept any input (`as`, `type`) are
  offered everywhere. When the shape inference is `SAny`, every op
  is offered — rejection only happens when the op can be proven
  incompatible.
- **Single source of truth for pipe-op metadata.**
  `lib/src/shape/pipe_ops.dart` owns, for each of the 27 pipe ops:
  canonical name, input-shape acceptance predicate, output-shape
  inference rule, and parse metadata. The parser builds its
  `zeroArg` and `oneArg` alternatives from this table (`custom`
  grammar like `as(fmt)` is still hand-written); the completer
  consults it for candidate filtering; `inferShape` dispatches
  pipe-op cases through it. Adding a new op with standard grammar
  is a single spec entry plus an AST case (compile-enforced via
  sealed `LamExpr`) plus an evaluator case (compile-enforced).
- **`PipeOpInfo`, `PipeOpParseKind`, `pipeOpSpecs`,
  `pipeOpInfoFor`, `pipeOpInfoForName`, `acceptsInputShape`,
  `inferPipeOpShape`.** Exported from `package:lambe/lambe.dart` so
  tools can reason about op metadata without parsing a query.
  `pipeOpSpecs` is the iteration-friendly view,
  `pipeOpInfoFor(astNode)` resolves by AST type,
  `pipeOpInfoForName(str)` resolves by name. The `PipeOpInfo`
  record shape may gain additional fields in future minor releases
  as the shape machinery evolves (e.g. richer element-level
  predicates, documentation strings). Callers that only need
  stable access should prefer the helper functions
  (`acceptsInputShape`, `inferPipeOpShape`, `pipeOpInfoForName`)
  over destructuring `PipeOpInfo` records directly.
- **Consistency test matrix.** `test/pipe_ops_consistency_test.dart`
  runs every pipe op against a representative value of every
  concrete shape kind and cross-checks the spec's `accepts`
  predicate with the evaluator's actual runtime behavior. Drift
  between spec and evaluator fails loudly instead of silently.

### Fixed

- **`inferShape` no longer lies on structurally incompatible input.**
  `flatten`, `sort`, `reverse`, `unique`, `filter_values`, `length`
  previously returned the input shape unchanged when given something
  the runtime evaluator would reject (e.g. `flatten` on a map).
  They now widen to `SAny`, so `--explain` reports the truth and
  downstream inference doesn't propagate impossible shapes.
- **Re-assertion filter.** Candidates whose text exactly matches
  what's already typed in `[start, end)` are filtered out before
  returning. Accepting such a candidate is a no-op on the text but
  moves the cursor backward, which users read as "Tab erased what
  I typed." Tab on fully-typed tokens is now a silent no-op.

### Changed

- **Parser pipe-op rules generated from the spec table.**
  `lib/src/parser.dart`'s `_pipeOp` is built by iterating
  `pipeOpSpecs` longest-name-first and dispatching on
  `PipeOpParseKind`. The hand-written alternation for the 26
  non-custom ops is gone. `as(fmt)` remains hand-written because
  its grammar takes a closed keyword set.
- **`pipeOpNames` re-exported from `shape/pipe_ops.dart`.** The
  parser, the completer, and the misspelling-suggestion logic all
  read from the same derived list.

### Breaking

- **`Completions` typedef now carries an `end` field.** Callers
  that destructured as `(:start, :candidates)` must destructure as
  `(:start, :end, :candidates)` and splice with
  `text.replaceRange(start, end, candidate)` instead of
  `text.replaceRange(start, cursor, candidate)`. The new field
  lets callers splice `[start, end)` and preserve any trailing
  whitespace the user typed after a complete token, which the
  previous `start..cursor` splice consumed.

### Docs

- **`ROADMAP.md`.** Publishes the 0.7.0 / 0.8.0 / 0.9.0 plan plus
  explicit non-goals (no Turing-completeness, no streaming, no jq
  feature parity).
- Removed `PLAN_COMPLETER_WHITESPACE_FIX.md` (shipped) and
  `ISSUES.md` (items resolved or tracked on GitHub).

## 0.6.1

Tab completion fix: trailing whitespace in the REPL query no longer
corrupts the replacement offset. Typing `.dependencies`, a space, then
Tab now completes against `.dependencies` instead of producing
`..dependencies`.

### Fixed

- Completer: the replacement `start` offset is now correct when the
  query has trailing whitespace (space, tab, CR, LF, or any mixture).
  Previously `.users ` + Tab returned `start: 1` instead of `start: 0`,
  which caused the REPL and the arda-web playground to splice the
  candidate in the wrong position.
- Completer: `??`, `?.`, and `??=` were previously split across
  multiple tokens in the unparsed-remainder classifier. They now match
  as single operators before falling through.

### Changed

- Completer: unparsed-remainder classification no longer uses regex.
  Two small Rumil parsers (`_pipeCtx`, `_fieldTailCtx`) handle
  pipe-op and field-tail contexts, with `position()` for offset
  tracking. Whitespace handling is uniform across space, tab, CR,
  and LF.
- Dependencies: `rumil`, `rumil_parsers`, `rumil_expressions` bumped
  to `^0.6.0`. Rumil 0.6.0 adds the `position()` primitive used by
  the completer fix.

## 0.6.0

Shape-aware output with interactive bridging. Lambe now infers the
structural shape of query results, reports incompatibilities with
target output formats as structured errors, and can bridge common
mismatches through a new language combinator or through interactive
prompts.

### Added
- **`Shape` ADT.** A sealed hierarchy (`SAny`, `SNull`, `SBool`,
  `SNum`, `SString`, `SList`, `SMap`) describing the structural kind
  of a value. `shapeOf(value)` infers the shape of any JSON-shaped
  value in time proportional to structure depth, using bounded
  sampling on lists. `renderShape(shape)` produces the canonical
  human-readable form (`list<map<a: number, b: string>>`).
- **`canWriteAs(value, format)` and `canWriteShapeAs(shape, format)`.**
  Return a `ShapeReport` (`Writable` or `NotWritable`). The
  `NotWritable` case carries the mismatched shape, the format's
  requirement, and a list of `Remediation` records describing
  curated query-fragments that bridge the mismatch.
- **`inferShape(ast, inputShape)`.** A structural interpreter over
  `LamExpr`. Given the shape of the value `.` refers to, returns the
  shape the query would produce. Every pipeline operator has a rule;
  the interpreter falls back to `SAny` where output cannot be
  determined without runtime values.
- **`synthesize(from, target)` and `synthesizeWithLabels(from, target)`.**
  Produce AST fragments (or full `Remediation` records) that bridge
  `from` to `target`'s shape requirement. `applyBridge(user, bridge)`
  composes a user query with a bridge fragment into a single AST via
  `Pipe`, avoiding string manipulation.
- **`as(format)` combinator.** A new pipeline operator written
  directly in the query language:
  `.users | as(toml)` produces a TOML-compatible value if exactly one
  curated bridge applies, and throws with the candidate list
  otherwise. Accepts `json`, `yaml`, `toml`, `csv`, `tsv`, `hcl`.
- **`--explain` CLI flag.** Prints the inferred shape at each pipe
  stage of a query, plus the set of output formats the final shape
  can be serialized as. Performs static analysis only; does not
  execute the query. Works with or without input data.
- **Interactive suggestion prompts.** When `lam --to <fmt>` would
  produce an `OutputShapeError` on an interactive terminal, the CLI
  now lists the available remediations and applies the chosen one.
  The REPL shows the same prompt inline and retries the query with
  the selected bridge.
- **Structured MCP error payload.** The `lambe_query` MCP tool now
  returns shape-mismatch errors as a JSON object with `error`,
  `message`, `format`, `got_shape`, `original_expression`, and a
  `suggestions` array (each entry with `id`, `label`,
  `template_text`, `apply_as`, `explanation`). Agents can respond by
  calling the tool again with an `apply_as` query verbatim.
- **`parseAst(expression)` and `evaluateAst(ast, data)` library
  entry points.** The existing `query(expression, data)` is now
  defined as `evaluateAst(parseAst(expression), data)`. Callers that
  parse once and evaluate against multiple inputs, or that compose a
  parsed AST with a remediation via `applyBridge`, should use these
  directly.
- **`OutputShapeError` subclass of `QueryError`.** Carries the
  structured `NotWritable` report with getters for `format`, `got`,
  `required`, and `suggestions`. Existing `catch (QueryError)`
  handlers continue to work; the new subclass is available for code
  that wants to render suggestions programmatically.

### Changed
- **Completer migrated to shape-based inference.** The REPL's tab
  completer now walks the parsed AST over a single inferred `Shape`
  tree rather than over a reduced value. Behaviour is unchanged (the
  same candidates are returned for every case). Benchmark medians
  are within run-to-run noise of the previous release.
- **CLI error messages for unwritable output.** `lam --to <fmt>` now
  reports shape mismatches with a short teaching message and a list
  of candidate bridges appended with `|`, rather than a raw runtime
  exception.

### Fixed
- **AOT benchmark harness.** `tool/bench/run.dart` gained `--aot` and
  `--runs N` flags. The AOT path removes JIT warmup from the
  measurement; the multi-run median of medians suppresses
  per-process noise so smaller regressions are visible.

## 0.5.0

### Added
- **`to_number` pipeline op.** Parses a string as a number; pass-through for
  existing numbers. Matches CSV and TSV cells, which are strings by default:
  `. | map(.price | to_number) | sum`. Throws `QueryError` on strings that
  do not parse.
- **`type` pipeline op.** Returns the runtime type of the input as a string:
  `"null"`, `"boolean"`, `"number"`, `"string"`, `"array"`, or `"object"`.
  Example: `. | filter((. | type) == "number")`.
- **`query()` and `eval()` normalize input data.** Maps and lists with
  non-canonical static types (e.g. `Map<dynamic, dynamic>` from some
  third-party decoders, or typed literals like `<int>[1, 2, 3]`) are
  recursively rebuilt as `Map<String, Object?>` and `List<Object?>` before
  evaluation. Previously these caused cryptic type-cast errors inside the
  evaluator. `queryString` skips this step since `parseInput` already
  produces canonical trees. Maps with non-string keys throw `QueryError`
  with a clear message.

### Performance
- **REPL tab completion is now independent of dataset size.** The completer
  reduces the data to a shape representative (one sample per list, all map
  keys preserved) before walking the partial AST, so operations like
  `sort_by`, `group_by`, and `unique` no longer execute against the full
  data. Median completion latency at 1M records drops from ~380ms–1.2s
  (depending on pipeline ops) to ~1–2ms. Peak resident set during a
  completion drops from hundreds of MB to the cost of the shape tree.
  Completion semantics are unchanged: the candidate lists are identical.
  Benchmark harness under `tool/bench/`.

### Fixed
- **`unique`, `unique_by`, and `group_by` now use structural equality on
  collection-valued keys.** Previously these operations relied on Dart's
  native `==` for `List` and `Map`, which is reference equality, so
  `[{"a":1}, {"a":1}] | unique` returned both entries instead of one.
  The evaluator now canonicalizes keys via JSON with sorted map keys before
  insertion into the hash set/map. Scalar keys (`num`, `bool`, `String`,
  `null`) still deduplicate by value as before. Key order in maps no
  longer affects equality: `{"a":1, "b":2}` and `{"b":2, "a":1}` are
  treated as equal.
- **`EvalException` from `rumil_expressions` is now wrapped as `QueryError`**
  at the public API boundary (`query()` and `eval()`). Previously, type errors
  in the evaluator (e.g., `.x > 5` where `.x` is a string, or `null + 1`)
  would leak the underlying `EvalException` with a full Dart stack trace,
  crashing `bin/lam.dart` with exit code 255 instead of reporting a clean
  error with exit code 1. The REPL was not affected because it already had a
  catch-all handler. The docstring for `query()` already advertised
  `QueryError` as the evaluation error type; this brings the implementation
  in line with the contract.
- **REPL banner now uses the actual `lambeVersion`** from `_version.dart`
  instead of a hardcoded `v0.1.0` string.

### Docs
- Tagline in the library doc comment and MCP server instructions changed from
  "universal" to "multi-format" — accurate given the specific format set
  (JSON, YAML, TOML, HCL, CSV, TSV, Markdown).
- `AGENTS.md` no longer references the unimplemented `..` (recursive descent)
  operator in Markdown query examples. The 0.4.0 changelog noted this was
  removed from `AI.md` but `AGENTS.md` was missed.
- `AI.md` and `AGENTS.md` pipeline operation lists now include `to_number`
  and `type`.

### Release infrastructure
- Release matrix now builds Linux ARM64 and macOS ARM64 (Apple Silicon) in
  addition to x64 and Windows. The MCP registry manifest covers all five
  platforms.
- GitHub Actions bumped: `upload-artifact` v4→v7, `download-artifact` v4→v8,
  `action-gh-release` v2→v3.

## 0.4.0

### Added
- **Pipeline ops are now valid bare expressions with implicit `.` input.**
  `has("k")`, `length`, `keys`, `sum`, `filter(...)`, `map(...)` and every
  other pipe op can appear as standalone expressions — `has("k")` parses as
  sugar for `. | has("k")`. This also unblocks common shapes like
  `map(has("email"))`, `filter(has("k"))`, and `filter(length > 0)`. Bare
  ops are only consulted after the other `_atom` alternatives fail, so
  existing forms like `{length}` object shorthand, `.length` field access,
  and `"\(length)"` string interpolation keep their prior meaning.

### Breaking
- **XML input/output support removed.** `Format.xml`, `OutputFormat.xml`, and
  XML extension detection (`.xml`, `.pom`, `.csproj`, `.svg`) are gone. The
  XML→native projection was lossy in ways that silently produced wrong query
  results (repeated sibling elements collapsed under last-wins map semantics;
  attributes were dropped entirely). Rather than ship a footgun, XML is
  dropped for now. The underlying XML parser in `rumil_parsers` is unchanged
  and remains spec-compliant; a future lambe release may reintroduce XML with
  a proper projection (array-preserved siblings, attribute preservation) once
  the design is settled.

### MCP surface
- **`output_format` parameter on the `lambe_query` MCP tool.** AI agents can
  now request yaml/toml/csv/tsv/hcl output directly, matching the CLI's
  `--to` flag. Defaults to json.
- **CSV and TSV exposed through the MCP surface.** The library always
  supported them; the MCP `format` enum was missing them.
- **MCP tool descriptions now document common pitfalls:** `&&`/`||` for
  boolean logic (not `and`/`or`), bracket syntax for hyphenated keys,
  `has()` and other pipeline ops requiring a leading `|`, and the
  `[{key, values}]` shape of `group_by` output.
- **Build-time version generation.** `tool/gen_version.dart` reads
  `pubspec.yaml` and writes `lib/src/_version.dart`, which the MCP server
  uses to report its version. Run after bumping the pubspec; the release
  workflow also runs it automatically.
- **`test/doc_examples_test.dart` — AI-doc and MCP-instruction examples are
  now test-gated.** Every `lam '...'` in AI.md and every embedded query in
  the MCP server's tool descriptions/instructions is parsed and evaluated
  against a fixture. Prevents future phantom-feature drift (e.g., LLM-drafted
  examples that advertise syntax the parser doesn't implement).

### Fixed
- **MCP server now reports its actual version.** `bin/mcp_server.dart` had
  hardcoded `0.1.0` since that release and was never bumped.
- **Removed phantom `..` (recursive descent) references from docs.** The
  operator was advertised in `AI.md` and the MCP server instructions as a
  Markdown query pattern but was never implemented. Callers who saw it would
  have hit parse errors.
- **Fixed broken example in `AI.md`**: `filter(has("resources") == false)` →
  `filter((. | has("resources")) == false)`. `has` is a pipeline op and
  cannot appear as a bare expression.

## 0.3.0

### Added
- **Markdown support.** CommonMark Markdown (.md, .markdown) is now a queryable
  input format. Parsed into a typed AST with node types like heading, paragraph,
  link, code_block, list, image, emphasis, etc.
- `mdToNative` public API for converting `MdDocument` to queryable Dart types
- Markdown query examples in MCP server instructions, AI.md, and AGENTS.md

### Changed
- Bumped rumil, rumil_parsers, rumil_expressions to ^0.5.0
- Rewrote `tool/manpage.dart` to use `parseMarkdown` + `parseYaml` from
  rumil_parsers instead of handrolled parser
- 491 tests (was 465)

## 0.2.0

### Breaking
- **`|` is expression composition.** `PipeOp` sealed class removed. Pipeline operations
  are now `LamExpr` subtypes. Any expression can appear after `|`:
  `.users[0] | {name, age}`, `. | if .active then "yes" else "no"`.

### Improved
- Parser error messages show position pointers and contextual descriptions
- "Did you mean?" suggestions for misspelled pipeline operations
- MCP tool descriptions expanded with syntax reference and common patterns
- Expanded recipes: object projection, string interpolation, chaining patterns

### Added
- `doc/jq-to-lambe.md` migration guide
- `test/syntax_examples_test.dart` backing every example in `doc/syntax.md`
- 465 tests (was 369)

## 0.1.1

- Added `.mcp.json` for automatic MCP server discovery in AI coding assistants
- Documented MCP server setup in README
- Added query syntax guide, REPL guide, recipes, and man page to `doc/`

## 0.1.0

### Core
- Query AST: sealed `LamExpr` hierarchy (16 subtypes) + sealed `PipeOp` (24 subtypes)
- Left-recursive parser via Rumil's `rule()` + Warth seed-growth
- Operator precedence via layered `chainl1` calls
- Null propagation: navigation propagates null, computation throws on type errors
- Tolerant parsing via `.recover()` for REPL completion and multi-line detection

### Query Language
- Property access chains: `.users[0].address.city`
- Negative indexing: `.items[-1]`
- String key indexing: `.data["key"]`
- Slicing: `.[1:3]`, `.[:3]`, `.[2:]`, `.[:-1]`
- Arithmetic: `+`, `-`, `*`, `/`, `%`
- Comparison: `<`, `<=`, `>`, `>=`, `==`, `!=`
- Boolean logic: `&&`, `||`, `!`
- Object construction with shorthand: `{name, total: .price * .qty}`
- Conditionals: `if .age > 65 then "senior" else "active"`
- String interpolation: `"\(.name) is \(.age) years old"`

### Pipeline Operations (24)
- Filter and transform: `filter`, `map`
- Ordering: `sort`, `sort_by`, `reverse`
- Grouping: `group_by` (returns `{key, values}` structure)
- Deduplication: `unique`, `unique_by`
- Structure: `flatten`, `keys`, `values`, `length`, `first`, `last`
- Aggregation: `sum`, `avg`, `min`, `max`
- Map operations: `filter_values`, `map_values`, `filter_keys`
- Existence: `has`
- Entry conversion: `to_entries`, `from_entries`

### Multi-format I/O
- Input: JSON, YAML, TOML, HCL, XML, CSV, TSV with auto-detection
- Output: `--to json/yaml/toml/xml/csv` for format conversion
- `--schema` for data structure inference
- `--assert` for CI/CD validation (exit 0 if true, 1 if false)

### Interactive REPL (`lam -i`)
- Parser-driven tab completion on field names, pipeline operations, and inner fields
- Syntax highlighting and colorized JSON output
- Persistent history (`~/.lambe_history`) with Ctrl+R reverse search
- Multi-line input with `\` continuation and parser-driven bracket detection
- Ctrl+Left/Right word movement, Ctrl+A/E/K/U editing shortcuts
- REPL commands: `:schema`, `:to`, `:raw`, `:pretty`, `:load`, `:history`, `:help`, `:quit`

### API
- Library: `query()`, `queryJson()`, `queryString()`, `parse()`, `eval()`
- Output: `formatOutput()`, `inferSchema()`
- CLI: `lam '<expression>' [file]` with all flags
- MCP server: `lambe_query`, `lambe_schema`, `lambe_assert` tools

### Ecosystem
- `lambe_test` package with matchers: `lamWhere`, `lamEquals`, `lamMatches`, `lamHas`
- MCP server installable via `dart pub global activate lambe` → `lam-mcp`
