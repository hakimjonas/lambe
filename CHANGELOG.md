## 0.9.0

Closes the shape feedback loop. Declare a JSON Schema, check queries
against it, round-trip schemas with the ecosystem. Plus: richer
static analysis in `--explain`, line-delimited JSON input, an opt-in
CSV escape hatch for nested cells, an architectural pipe-op
consolidation, and a `rumil_tokens`-based REPL highlighter.

### Pipe-op AST consolidation

- The 27 per-op AST classes (`FilterOp`, `MapOp`, `SortOp`, …)
  collapse into a single `BuiltinPipeOp(name, args)`. The spec table
  in `pipe_ops.dart` is now the only place per-op behaviour lives:
  acceptance, shape inference, runtime evaluation, and parse arity
  all live on the same record. Adding or renaming a pipe op is a
  one-file change.
- `As(target)` keeps a dedicated AST class for its typed
  `OutputFormat` argument — it's the only custom-arity op.
- `pipeOpInfoFor(LamExpr)` recognises both `BuiltinPipeOp` and `As`.
- Source-breaking for external code that constructed pipe-op AST
  nodes directly. The pre-1.0 contract here was that AST classes
  were internals; we're taking that out properly. Tests that
  assembled `MapOp(.x)` etc. now write `BuiltinPipeOp('map', [.x])`.

### REPL syntax highlighter on `rumil_tokens`

- `lib/src/readline.dart`'s 100-line hand-rolled tokenizer is gone.
  The highlighter now consumes a `Token` stream from the
  `rumil_tokens` `LangGrammar` defined in
  `lib/src/highlight_grammar.dart`. The grammar lives in lambé (not
  in `rumil_tokens`' built-in five) because it's lambé-specific.
- New runtime dependency: `rumil_tokens ^0.1.0`.
- Visible behavioural change in the REPL: `.field` colours as two
  tokens (`.` punctuation + `field` identifier) rather than one
  cyan run; negative literals colour as `-` operator + number
  rather than one yellow run. The audit determined the new
  behaviour is more principled; the visual effect is subtle.

### Markdown text extraction

- **`text` pipe op.** Walks a markdown node (or list of nodes) and
  concatenates every prose-bearing leaf — `text`, `code`, `code_block`,
  and `image.alt` — in document order. Container nodes recurse through
  their `children`. `html_block` and `html_inline` are skipped (avoids
  the `Node.textContent` trap of dragging raw HTML, scripts, and styles
  into "give me the text"); `hard_break` and `soft_break` contribute
  the empty string. The previous recommendation,
  `.children[0].text`, is structurally wrong for non-trivial markdown
  (nested emphasis, inline code, links) and the existing pipe surface
  cannot fix that without recursion.
- **First op tuned to a specific input format's vocabulary.** This is
  the only pipe op whose `eval` switches on a value's `type` field.
  The behaviour is bounded to markdown's node-type vocabulary as
  defined in `lib/src/input.dart`'s `_nodeToNative`. It does NOT
  authorise content-level dispatch in any other op — the spec entry
  carries a load-bearing comment to that effect. Prior art (XPath
  `string(node)`, mdast-util-to-string) converges on the same shape:
  format-aware leaf primitive with hardcoded knowledge of which fields
  carry prose vs metadata. jq's `..` approach drags in `link.href`,
  `image.src`, and `code_block.language` — exactly the trap this op
  avoids.

### `queryNdjsonString` convenience

- New `queryNdjsonString(Iterable<String> lines, String expression)`
  parses the expression once and delegates to `queryNdjson`. Resolves
  the asymmetry where the existing `queryNdjson` took a pre-parsed
  AST while every other `query*` took a string.

### Performance

- `_normalize` short-circuits canonical inputs.
  `Map<String, Object?>` / `List<Object?>` / scalars round-trip
  through the public API without allocating a copy. Non-canonical
  inputs (e.g. `Map<dynamic, dynamic>` from some YAML decoders)
  still rebuild as before.
- End-to-end CLI is roughly **3.3× faster** than 0.8.0 on
  parse-bound workloads. Measured on a 50k-element JSON document
  (1.5 MB), AOT, on a Linux x86_64 workstation with the bench
  harness in `tool/bench/cli_bench.sh`:
  - `lam --print-shape big.json`: 2.4 s → 732 ms (3.28×).
  - `lam '.items | filter(.value > 50000) | length' big.json`:
    2.5 s → 742 ms (3.37×).
  Most of the win is inherited: rumil 0.7's FIRST-set Or dispatch,
  the `firstCharChoice` combinator, and the Pratt migration carried
  the bulk; rumil_parsers 0.8.0's JSON AST split, capture-based
  number/string parsing, HCL AST split, and `common.dart` capture
  rewrites carried the rest. Non-parse-bound paths benefit too —
  `group_by` on 1k records is ~15% faster (39 ms → 33 ms) because
  the JSON AST split removes a per-number `truncateToDouble` check
  in `jsonToNative`.
  See `tool/bench/cli_bench.sh` for the harness and reproduction.

### Documentation precision

- Six per-op behavioural details now have load-bearing docstrings:
  `//` is a null-fallback (not an error-handler), the empty-list
  policy (`first`/`last` return null; `min`/`max`/`avg` throw; `sum`
  returns 0), `unique` distinguishes int from double by canonical
  encoding, duplicate keys in `{a: x, a: y}` follow Dart map literal
  semantics (last wins), `from_entries` rejects non-map / non-string-
  key entries explicitly (was silent skip), `type` rejects non-JSON
  runtime values with a hint pointing at `parseInput` / `jsonDecode`.
- The `from_entries` change is the only behavioural one — non-map
  entries used to be dropped silently, now they throw `QueryError`.
  Hides a class of bugs where upstream pipelines emit the wrong
  shape.
- **`as(fmt)` bridges reference** in `doc/recipes.md`. Documents the
  four canonical bridges with runnable examples: `list<scalar> |
  as(toml/hcl)` wraps as `{items: ...}`; `scalar | as(toml/hcl)`
  wraps as `{value: ...}`; `map | as(csv/tsv)` derives via
  `to_entries`; `scalar | as(csv/tsv)` composes both.
- **`As` class doc** softened to be honest about which error paths
  users will and won't hit. The "ambiguous bridge" runtime branch is
  defensive against future curation errors but unreachable with the
  current curated table — the doc no longer claims otherwise. A new
  invariant test in `shape_synthesize_test` pins `≤ 1 bridge per
  (shape, format)` so the path becomes reachable only by a
  deliberate change.
- **`syntax.md` examples** revert from `echo … | lam '. | op'` to
  the cleaner `lam -n '… | op'` form now that `-n` exists. Several
  pre-A6 examples were also silently broken: lambé object
  construction uses bare identifiers (`{a: 1}`), not JSON-string
  keys (`{"a": 1}`), so `[{"key": "a"}] | from_entries` was never
  runnable. Fixed.
- **`-r` / `--raw` semantics** — man page entry now states the option
  only affects top-level string scalars and is a silent no-op on
  structured output (objects, arrays, numbers, booleans, null). The
  previous wording ("Output strings without quotes") read as a
  pretty-print toggle and surprised users on non-string values.
- **`doc/non-goals.md`** — new page enumerating the features lambé
  deliberately omits, with the lambé idiom that replaces each one.
  Cross-linked from `README.md` ("What lambé is not"),
  `jq-to-lambe.md`, and `AGENTS.md`. Covers Turing-completeness,
  recursive descent (`..`), `try`/`catch`, `select` outside `filter`,
  `paths`/`leaf_paths`/`getpath`/`setpath`, regex, `range`/`limit`/
  `nth`, `.[]` iteration, `def`/lambdas, `@base64`/`@uri`,
  streaming, `env`/`$__loc__`, HCL evaluation, and XML. Staying
  bounded is a feature; the page makes that legible.
- **`text` op precedent** — the new `text` pipe op (see Markdown text
  extraction) is the only op tuned to a specific input format's
  vocabulary. The spec entry carries a load-bearing dartdoc comment
  declaring this is bounded to markdown's node-type vocabulary as
  defined in `_nodeToNative`, and does NOT authorise content-level
  dispatch in any other op.

### Bug fixes

- **TSV input now honors header rows the same way CSV does.** Pre-0.9.0
  every TSV file returned `List<List<String>>` because the parser
  passed a static `defaultTsvConfig` and skipped dialect detection.
  Now `parseInput` runs `detectDialect` for TSV with the tab
  delimiter forced, so files where the first row looks like headers
  return `List<Map<String, Object?>>`. `--print-shape data.tsv` and
  `--print-shape data.csv` agree on logical content.
- **String single-char indexing.** `.name[0]` now returns a
  one-character substring instead of erroring with `Cannot index
  string`. Slicing (`.name[0:3]`) already worked; the asymmetry is
  gone. Out-of-range returns `null` (mirrors list indexing);
  non-int still throws.
- **`--explain` writability section is suppressed when a
  runtime-rejection warning fires.** When a pipe op's input shape is
  provably incompatible the post-stage shape widens to `SAny`, which
  used to make every output format pass `canWriteAs` — so the
  explain report listed every format for a pipeline that would throw
  before any writer ran. Both `Writable as:` and `Not writable as:`
  are now suppressed; the text renderer prints a one-line note in
  their place, and the JSON renderer sets both keys to `null`.
- **Heterogeneous list rendering hint.** `shapeOf([1, "two", true])`
  collapses the element type to `SAny`. The rendered JSON Schema now
  carries a `description: "sampled, may be heterogeneous"` so
  `--print-shape` users see that the schema reflects sampling, not
  a guarantee. The hint round-trips through `parseJsonSchema`
  (unknown keywords are ignored per JSON Schema's extensibility
  convention).
- **Empty piped stdin.** Empty stdin in evaluation mode now surfaces
  the standard "no input" error rather than a confusing JSON parse
  error on the empty string.
- **HCL block access is now uniform across N=1 and N≥2 cases.**
  Previously, querying `.variable` returned a single map for one
  `variable` block but a list for two or more — forcing defensive
  shape checks in queries. Now `.variable` is always a list, regardless
  of count. Common Terraform patterns (one `terraform`, one `provider`,
  single `variable`) no longer require N=1-vs-N≥2 branching. Fixed
  upstream in `rumil_parsers 0.8.0` (decoder uses the `HclBlock`
  discriminator already present in the AST instead of inferring shape
  from key collisions); lambé adopts it via a constraint bump from
  `^0.7.0` to `^0.8.0`.

### Dependencies

- **`rumil_parsers ^0.8.0`.** The JSON parser AST splits `JsonNumber`
  into a sealed `JsonInt | JsonDouble` sum. Lambé propagates the
  change through one schema-parser switch case — `JsonInt() ||
  JsonDouble() => 'number'` in `lib/src/schema/parser.dart`. No
  user-visible behavior change at the lambé surface; downstream
  consumers of lambé's library API see no shape difference because
  `parseInput`-flavored Map/List types remain canonical Dart types
  (the AST split is only visible when you reach into the JSON AST
  directly via the lambé schema layer). The HCL fix described above
  also rides this dependency bump (originally scoped as
  `rumil_parsers 0.7.1`; rolled into 0.8.0 alongside the AST split).
  See `rumil_parsers/BENCHMARKS.md` for the JSON parser perf wins on
  the 0.8.0 release; lambé queries operating on JSON inputs benefit
  transparently.
- **Object construction accepts JSON-string keys.** `{name: .x}` was
  the only spelling; `{"name": .x}` errored with a confusing
  "unexpected" message. Now both spellings produce the same map. Keys
  that are valid identifiers should still use the bare form (`name:`);
  keys that aren't (hyphenated, spaces, leading digits) use a
  JSON-string literal in key position — `{"x-axis": .a}`,
  `{"Content-Type": "application/json"}`, `{"my key": 1}`. Lambé's
  data model accepts any string as a key; the construction grammar
  now matches. Interpolation (`{"\(expr)": .y}`) is rejected with a
  clear message — key position is structurally not an expression
  position; build dynamic keys via `from_entries` on a list of
  `{key, value}` maps. Shorthand `{name}` continues to require a bare
  identifier (`{"name"}` alone is intentionally not supported).

### jq compatibility

- **`add` is now recognized as an alias for `sum`.** A jq idiom that
  matches Lambé's `sum` exactly. `_jqAliases` in `parser.dart` is the
  table; entries belong there only when the jq semantics are an
  exact match.
- **Idiom hints for column-1 jq keywords.** `_jqIdiomHint` and
  `_jqPipeOpHint` now recognise `try` / `try ... catch`, `recurse`,
  `walk`, `paths`, `leaf_paths`, `range`, `limit`, `nth`, `@csv`,
  `@tsv`, and `@base64`. Each produces a one-liner pointing at the
  lambé equivalent (or, for `@base64`, the explicit "not supported"
  signal) instead of the giant op-vocabulary dump. Folds into the
  pre-existing hints for `[]`, `?`, `..`, `select`, `empty`, and
  stranded `end`.

### Schemas as a first-class contract

- **`--schema <path>`** on the CLI. Threads a JSON Schema subset
  through both `--explain` inference and normal evaluation. With
  data, the schema validates at load time (structural disagreement
  exits 1 with a JSON path). Without data, the schema alone seeds
  shape inference for design-time planning.
- **Sibling auto-detect.** Data at `path/to/data.json` picks up
  `path/to/data.schema.json` implicitly. Same convention as ndjson
  auto-detect.
- **`--print-shape`** on the CLI. Emits `shapeOf(data)` as a JSON
  Schema subset document, round-trippable with `--schema` input. The
  same shape-to-JSON-Schema rendering powers
  `renderJsonSchema(shape)` on the library and the MCP
  `lambe_print_shape` tool.
- **`--print-shape EXPR` composes with the query.** When given an
  expression, `lam --print-shape '.users' data.json` now returns the
  schema of the result of evaluating `.users` rather than the schema
  of the whole document. Pre-0.9.0 the expression was silently
  ignored. Without data, falls back to inferring from `SAny` —
  matches the `--explain`-without-data flow.
- **REPL: `:schema [path]` and `:print-shape`.** `:schema <path>`
  loads a schema for the session and reports agreement/disagreement
  vs current data. `:schema` (no arg) prints the active schema.
  `:load` re-validates against an active schema and warns on
  disagreement.
- **MCP: `lambe_print_shape`, `lambe_check`, `lambe_explain`, plus
  a `schema` parameter on `lambe_query`.** Agents can print a
  shape, validate fixtures against a schema, trace a query
  structurally before running, or gate a query on schema
  conformance. `lambe_check` returns `{"ok": true}` /
  `{"ok": false, "error": "..."}`.
- **Library surface.** `parseJsonSchema`, `renderJsonSchema`,
  `loadSchemaFromFile`, `loadSchemaForData`, `mergeSchemaWithData`
  are all exported from `package:lambe/lambe.dart`.

### `SOptional` in the shape ADT

- New sealed variant `SOptional(Shape)`. Represents
  statically-known optionality — populated by JSON Schema's
  `required` semantics, propagated through field access and op
  inference, and surfaced by the explain trace. Nested optionality
  collapses at construction: `SOptional(SOptional(x))` is always
  `SOptional(x)`.
- Acceptance predicates unwrap `SOptional` for op inputs — `filter`
  on `SOptional<SList<T>>` is accepted, with the potential absence
  surfaced by a runtime-rejection warning rather than a silent
  accept or a false reject.
- Root-level requirements (TOML/HCL `MustBeMap`) do NOT unwrap: an
  absent root can't be serialized, so users must materialize a
  default first. This asymmetry is deliberate.
- `shapeToJson` emits `{"kind": "optional", "inner": ...}`.
  `renderJsonSchema` flattens `SOptional` inside `SMap` fields into
  missing `required` entries (standard JSON Schema idiom);
  non-field-position `SOptional` has no standard spelling in our
  subset and is flattened with a docstring caveat.

### Richer `--explain` output

Three new categories of static analysis, plus a structured output
mode:
- **Runtime-rejection warnings** (always on). Flags pipe ops whose
  input shape is provably incompatible. `.config | filter(.x)` on a
  known map produces `"filter rejects map<...>; this will throw at
  runtime"`. Uses the existing pipe-op acceptance predicates.
- **Trivial-result warnings** (opt-in via `--explain-trivial`).
  Flags `sort_by`, `group_by`, `map`, and `unique_by` whose
  argument references a field provably absent on the element shape.
  Opt-in because legitimate uses exist (stable no-op sort, explicit
  null projection).
- **Structured JSON output** (`--explain-json`). Emits the full
  explain report as JSON with snake_case keys (`stages`,
  `warnings`, `writable_as`, `not_writable_as`, `flatten_cells`).
  Warning kinds serialize as `empty_filter`, `runtime_rejection`,
  `trivial_result`. Shapes serialize as nested `{kind, ...}` trees
  (via `shapeToJson`) so agents can pattern-match shape structure
  without re-parsing. Also surfaces in the new `lambe_explain` MCP
  tool.
- Both `--explain-trivial` and `--explain-json` imply `--explain`.
- New `shapeToJson(Shape)`, `renderExplainJson(ExplainReport)`,
  `WarningKind` enum, and `ExplainWarning.kind` field on the
  library.

### `--ndjson` mode for line-delimited JSON input

- Each line is parsed as an independent JSON document; the query is
  evaluated per line with no shared state; one compact JSON result
  per line. Auto-enabled when the file extension is `.ndjson` or
  `.jsonl`. Stdin support streams: `tail -f app.log | lam --ndjson
  '.level'` emits each result as the line arrives.
- Fail-fast on the first malformed or unevaluable line; error
  carries the line number.
- New `queryNdjson(Iterable<String>, LamExpr)` library function
  (`Iterable<Object?>`, lazy).
- Cannot combine with `--interactive`, `--schema`, `--assert`, or
  `--explain`; output is restricted to JSON (`--to` other than
  `json` is refused).

### Null input

- **`-n` / `--null-input` flag.** Run a query against `null` context
  with no input file. Useful for value computations:
  `lam -n '[1,2,3] | unique'`. Without `-n`, the missing-input guard
  fires (typo'd filename or missing redirect is a common footgun);
  the flag puts the "I have no input" intent on the command line
  where it's visible in scripts and code review. The `--null-input`
  spelling matches jq exactly.
- Cannot combine with `--interactive`, `--ndjson`, `--schema`, or
  `--assert`. The TTY stdin guard is unchanged.

### `--flatten-cells` for CSV/TSV

- Opt-in escape hatch: non-scalar cells encoded as JSON strings
  inline. Accepts `refuse` (default, 0.8.0 behavior) or `json`.
  Under `json`, the shape check widens `MustBeFlatList` to
  `MustBeList` for csv/tsv. Round-tripping the resulting CSV back
  into Lambe does NOT recover structure; this is an output-side
  escape hatch, not a faithful encoding.
- Surfaced at the CLI (`--flatten-cells`), REPL
  (`:flatten-cells`), MCP (`flatten_cells` parameter), and as
  `CellPolicy flattenCells` on `formatOutput`, `canWriteAs`,
  `canWriteShapeAs`, `requirementFor`, and `explain`.

### Cross-surface hints

- **`NotWritable.hints`.** When a shape mismatch has an
  environmental resolution (a flag, a setting, a tool parameter),
  the report carries a structured `Hint` type with `label`,
  `cliFlag`, `replCommand`, `mcpParameter`, and `explanation`. CLI,
  REPL, and MCP each render the form that applies to them.
  Agent-facing JSON carries `parameter`/`value` pairs, not CLI
  syntax.
- The first shipping hint covers `--flatten-cells json`: when a
  CSV/TSV request rejects under `refuse` but a list root is
  already present.

### Breaking changes

- **`--schema` flag renamed to `--print-shape`.** 0.8.0's `--schema`
  printed a type-name JSON summary of the data. That function moved
  to `--print-shape`. The new `--schema` takes a JSON Schema file
  path. Users scripting `lam --schema data.json` must change to
  `lam --print-shape data.json`. ArgParser rejects the old form
  because `--schema` now requires a value.
- **`--print-shape` output format changed.** Emits a JSON Schema
  subset document (`{"type": "object", "properties": ..., "required":
  ...}`) instead of the type-name-string JSON format 0.8.0 emitted
  (`{"age": "number"}`). The new output round-trips with
  `--schema` input; the old format had no round-trip path.
- **MCP tool `lambe_schema` renamed to `lambe_print_shape`.** Output
  format also changed to JSON Schema, matching the CLI. Agents that
  hardcoded the old tool name get "tool not found" and a message
  pointing at `lambe_print_shape`.
- **`Shape` ADT gained `SOptional` variant.** Source-breaking for
  external code that pattern-matches `Shape` without a default case
  (probably just Lambe itself). Exhaustive switches now need a
  fifth branch.
- **`ExplainWarning` constructor gained required `kind` parameter.**
  External code constructing warnings directly must add a
  `WarningKind`. Uncommon; the existing pattern is consuming
  warnings, not producing them.

### Deprecated

- **`inferSchema(Object? value)`** library function. Emits
  type-name-string JSON (no round-trip). Use
  `renderJsonSchema(shapeOf(value))` for JSON Schema output, or
  `shapeOf(value)` for the `Shape` ADT. Scheduled for removal in
  1.0.

### Install ergonomics

- **`install.sh`** — one-line installer at the repo root.
  `curl -fsSL https://raw.githubusercontent.com/hakimjonas/lambe/main/install.sh | sh`
  downloads the latest `lam` and `lam-mcp` binaries for the current
  platform (Linux x64/arm64, macOS x64/arm64), verifies SHA256
  against a published `checksums.txt`, and installs to
  `~/.local/bin/`. No sudo, no shell rc edits. Respects
  `LAMBE_VERSION` and `LAMBE_PREFIX` env vars.
- **Release workflow generates `checksums.txt`.** `.github/workflows/release.yml`
  now publishes a combined SHA256 manifest for every release
  artifact as an asset. `install.sh` relies on this for integrity
  checking; downstream package managers (a future Homebrew tap,
  apt/rpm) can reuse it.

### Tooling

- **CHANGELOG self-validation.** `tool/lint_changelog.sh` uses lambé
  itself (via `--assert`) to validate this file's structural
  invariants on every CI run: at least one H2 release entry, no
  duplicate H2s, the first heading is H2, and the latest H2 matches
  `pubspec.yaml`'s version. The toolchain checks itself: rumil's
  Markdown parser handles the input, lambé's query model expresses
  the invariants. See `doc/recipes.md#querying-a-changelog` for the
  underlying queries.

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
