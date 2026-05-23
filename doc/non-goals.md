# Non-goals

Lambé is a bounded tree transformer over JSON-shaped data. The list
below is what lambé deliberately does not do, and the lambé idiom that
replaces each omission where one exists. The tool is small *because*
these are excluded; staying bounded is what makes shape inference,
`--explain`, and `as(fmt)` bridging work.

If you came from jq looking for a feature that's missing, this is the
short answer. The full migration guide is in
[jq-to-lambe.md](jq-to-lambe.md).

## Language scope

- **Turing-completeness** → no `def`, no recursion, no lambdas. jq has
  these and regrets them: their presence is exactly what prevents
  static analysis, makes error messages vague, and turns "quick query"
  into "programming language to learn." Lambé's shape inference,
  `--explain`, and `as(fmt)` bridging all work *because* lambé is a
  bounded tree transformer.
- **User-defined functions (`def`)** → not supported. The bounded tree
  transformer is the design.
- **Lambdas** → same.
- **Recursive descent (`..`)** → not supported. Compose with explicit
  paths plus `flatten` / `map`. For prose extraction from markdown,
  use the `text` op (the only op tuned to a specific input format's
  vocabulary). For paths into structured data, use `--print-shape` to
  see the structure first.
- **`.[]` iteration sugar** → list ops are list ops. Use
  `.users | map(.)` instead of `.users[]`. jq's `.[]` overloads on
  container type, which conflicts with lambé's shape-aware approach.
- **`try` / `catch`** → lambé's contract is "navigation returns null,
  computation throws." There is no exception model in user space. Use
  `// fallback` for null handling; let computation errors propagate to
  the CLI.
- **`select(p)` outside `filter(...)`** → `select` is only valid as the
  predicate of `filter`. `map(select(p))` is just `filter(p)`.

## Path manipulation

- **`paths` / `leaf_paths`** → use `--print-shape` (CLI),
  `lambe_print_shape` (MCP), or `renderJsonSchema(shapeOf(value))`
  (library). Structural exploration is a separate tool from query
  evaluation.
- **`getpath` / `setpath`** → read-only by design. lambé does not
  mutate input; it produces new values. There is no in-place update.

## Iteration & limits

- **`range`, `limit`, `nth`** → use slicing (`[:n]`, `[n:]`, `[a:b]`)
  and `first` / `last`. These cover the common cases without
  introducing iteration as a language primitive.

## Strings

- **Regex (`test`, `match`, `sub`, `gsub`)** → out of scope. Lambé
  treats strings as opaque values. For regex, pipe through `grep` or a
  regex tool before / after `lam`.
- **`@base64`, `@uri`** → not supported. Encoding is out of scope.
- **`@csv`, `@tsv`** → use `--to csv` / `--to tsv` on the CLI, or
  `as(csv)` / `as(tsv)` in the query, plus `formatOutput(value,
  OutputFormat.csv)` in the library. Output formatting belongs to the
  format layer, not the query language.

## Environment

- **`env`, `$__loc__`** → not supported. Queries are pure; environment
  access lives outside the query (set up via the shell).

## Streaming

- **Streaming evaluation** → out of scope. Two blockers: (1) half the
  language (`sort`, `group_by`, `sum`, `unique`) cannot stream;
  building a parallel streaming pipeline would fork the semantics.
  (2) Rumil's parser uses Warth seed-growth for left recursion, which
  requires re-parsing a prefix as a seed grows; a streaming parser
  cannot rewind buffers it has already discarded. This is algorithmic,
  not a tuning knob. For the "tail a log file" use case, `--ndjson`
  evaluates one document per line with no shared state.

## Format-specific

- **HCL evaluation** → lambé reads HCL syntax (parses Terraform `.tf`
  files, surfaces blocks and attributes), but does NOT evaluate
  Terraform expressions. Variable resolution, function calls,
  `for` expressions, splats, and conditionals serialise back to their
  source form. Use Terraform's own tooling for evaluation.
- **XML** → temporarily out of scope. The 0.4.0 release dropped XML
  because the projection was lossy; see CHANGELOG. A future release
  may reintroduce it once the array-preserved-siblings projection is
  designed.
