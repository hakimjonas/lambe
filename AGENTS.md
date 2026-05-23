# AGENTS.md — using Lambë

Lambë (`lam`) is a query language for structured data. It extracts,
filters, transforms, validates, and converts JSON, YAML, TOML, HCL,
CSV, TSV, and Markdown — auto-detecting format from file extension.

This file teaches you (the agent) **when to reach for `lam` and how to
write queries that work**. The `lam` binary is on the user's PATH after
`dart pub global activate lambe`; you can invoke it from a shell tool.

## When to use it

Reach for `lam` when the user wants to:

- **Extract** values from a structured file (one field, an array, a nested path).
- **Filter** records by a predicate.
- **Transform** records into a different shape.
- **Aggregate** numbers (sum, avg, min, max, count).
- **Validate** structure or values (`--assert`, `--schema`, `--explain`).
- **Convert** between formats (`--to yaml`, `--to csv`, etc.).
- **Inspect** unfamiliar data (`--print-shape` returns JSON Schema).

Lambë is a **bounded tree transformer** — every query terminates, no
recursion, no `def`/lambdas. Don't reach for it when the user wants:

- Binary data, images, databases, streaming.
- jq syntax specifically (use jq).
- SQL queries (use SQL).
- Programmatic processing with loops or accumulating state (write code instead).
- Recursive descent (`..`), `try`/`catch`, regex, `getpath`/`setpath`,
  in-place mutation. See [doc/non-goals.md](doc/non-goals.md) for the
  full list and the lambë idiom that replaces each omission. If you
  hit "unknown pipe op" or a `_jqIdiomHint` message, that page is the
  canonical reference.

## Natural language → `lam` query

| User says | Query |
|---|---|
| "Get the database host" | `lam '.database.host' config.yaml` |
| "List all user names" | `lam '.users \| map(.name)' data.json` |
| "Filter active users over 30" | `lam '.users \| filter(.active && .age > 30)' data.json` |
| "How many items?" | `lam '.items \| length' data.json` |
| "Sort by price descending" | `lam '.items \| sort_by(.price) \| reverse' data.json` |
| "Group by department" | `lam '.users \| group_by(.dept)' data.json` |
| "Total price" | `lam '.items \| map(.price) \| sum' data.json` |
| "Show the structure" | `lam --print-shape data.json` |
| "Check version isn't empty" | `lam --assert '.version != ""' package.json` |
| "Convert to YAML" | `lam --to yaml '.' data.json` |
| "Export as CSV" | `lam --to csv '.users \| map({name, age})' data.json` |
| "Get all unique tags" | `lam '.items \| map(.tags) \| flatten \| unique' data.json` |
| "Get the first 3 items" | `lam '.items[:3]' data.json` |
| "Build a summary object" | `lam '{count: .items \| length, total: .items \| map(.price) \| sum}' data.json` |
| "Find containers without limits" | `lam '.spec.template.spec.containers \| filter(has("resources") == false) \| map(.name)' deployment.yaml` |
| "List Terraform resources" | `lam '.resource \| map(._labels)' main.tf` |
| "Query CSV data" | `lam '. \| filter(.status != "closed") \| map(.title)' issues.csv` |
| "Sum a CSV numeric column" | `lam '. \| map(.price \| to_number) \| sum' orders.csv` |
| "Inspect a value's type" | `lam '.config \| type' data.yaml` |
| "List all headings in this markdown" | `lam '.children \| filter(.type == "heading") \| map(text)' README.md` |
| "What languages are in the code blocks?" | `lam '.children \| filter(.type == "code_block") \| map(.language)' tutorial.md` |
| "Run a query without input" | `lam -n '[1, 2, 2, 3] \| unique'` |
| "Explore interactively" | `lam -i data.json` |

## Syntax reference

### Property access

```
.name                    field access
.users[0]                index
.users[0].name           chained
.users[-1]               negative index (from end)
.users[1:3]              slice
.users[:3]               slice from start
.users[-2:]              slice from end
.["x-axis"]              bracket form for keys with hyphens / spaces / dots
```

### Pipeline operations

```
. | filter(.age > 30)    keep matching elements
. | map(.name)           transform each element
. | sort                 natural-order sort
. | sort_by(.age)        sort by key expression
. | group_by(.type)      group into [{key, values}]
. | unique               deduplicate
. | unique_by(.id)       deduplicate by key
. | flatten              flatten one level
. | reverse              reverse order
. | length               count elements (list / map / string)
. | first                first element
. | last                 last element
. | sum                  sum numbers
. | avg                  average
. | min / max            minimum / maximum
. | keys                 map keys or list indices
. | values               map values
. | has("field")         check field exists (returns bool)
. | to_entries           map to [{key, value}]
. | from_entries         [{key, value}] to map
. | to_number            parse a string as a number (use on CSV numeric columns)
. | type                 runtime type: null, boolean, number, string, array, object
. | filter_values(. > 5) filter a map's values
. | map_values(. * 2)    transform a map's values
. | filter_keys(. != "x") filter a map's keys
. | text                 markdown-only — concatenate prose from a node tree
. | as(yaml)             cross-format bridge (also as(toml), as(csv), as(hcl))
```

### Expressions

```
.price * .qty                       arithmetic (+, -, *, /, %)
.age > 30                           comparison (<, >, <=, >=, ==, !=)
.active && .verified                logic (&&, ||, !)
.config // "default"                null fallback (// is null-fallback, not error-handler)
if .age > 65 then "senior" else "active"
{name, total: .price * .qty}        object construction
"\(.name) is \(.age)"               string interpolation
[1, 2, 3]                           list literal
```

## CLI flags worth knowing

```
-n, --null-input        Run without input ("lam -n '[1,2,3] | unique'")
-i, --interactive       REPL mode (loads data, then prompts for queries)
-f, --format FMT        Override input format detection
--to FMT                Output format (json default; yaml, toml, csv, tsv, hcl)
--no-pretty             Compact (single-line) output
-r, --raw               Output top-level string scalars without quotes
                        (no effect on structured output)
--print-shape           Emit a JSON Schema describing the data's shape
--schema FILE           Validate input against a JSON Schema before querying
--explain               Static shape trace per pipeline stage (no execution)
--explain-json          Same as --explain but emits structured JSON
--explain-trivial       Surface trivially-empty / shape-rejected ops as warnings
--assert                Exit 0 if the query returns true, exit 1 otherwise
--ndjson                Each line of input is a JSON document (line-delimited)
--flatten-cells json    For CSV/TSV output: encode non-scalar cells as JSON strings
```

## Markdown data model

Markdown files are parsed into a CommonMark AST. Every node is a map
with a `type` field. Container nodes have `children`. The root is
`{type: "document", children: [...]}`.

| Node type | Fields | Notes |
|---|---|---|
| `document` | `children` | root |
| `heading` | `level`, `children` | block |
| `paragraph` | `children` | block |
| `list` | `ordered`, `tight`, `items`, `start?` | block |
| `list_item` | `children` | block |
| `code_block` | `code`, `language?` | leaf-ish |
| `blockquote` | `children` | block |
| `link` | `href`, `children`, `title?` | inline |
| `image` | `src`, `alt`, `title?` | inline |
| `emphasis` | `children` | inline (italic) |
| `strong` | `children` | inline (bold) |
| `text` | `text` | leaf |
| `code` | `code` | leaf (inline code) |
| `thematic_break` | — | horizontal rule |
| `hard_break` | — | explicit line break |
| `soft_break` | — | source line wrap |
| `html_block` | `html` | raw HTML block |
| `html_inline` | `html` | raw inline HTML |

**Use the `text` pipe op for prose extraction**, not `.children[0].text`.
The `text` op walks any node tree and concatenates text/code/code_block
content + image alt text in document order, recursing into nested
emphasis, strong, links, and inline code. `.children[0].text` only
sees the first immediate child and misses nested formatting.

```bash
# All heading texts
lam '.children | filter(.type == "heading") | map(text)' README.md

# Headings with their levels
lam '.children | filter(.type == "heading") | map({level, title: text})' README.md

# Every code block by language
lam '.children | filter(.type == "code_block") | map({language, code})' tutorial.md

# Python code blocks only
lam '.children | filter(.type == "code_block" && .language == "python") | map(.code)' tutorial.md

# Whole document as plain prose
lam '. | text' README.md
```

## Error patterns

| Behaviour | What's happening |
|---|---|
| Result is `null` | Field doesn't exist; navigation returns null. Lambë's null-propagation contract: navigation is null-safe, computation throws. |
| `QueryError: ... expected number, got null` | Arithmetic / comparison on a missing value. Use `.field == null` to check, or `.field // default` to substitute, or filter upstream. |
| `QueryError: ... rejects map<...>` | Op needs a list but got a map (or vice versa). Use `--explain` to see the shape at each stage. |
| Parse error with caret | Invalid query syntax. Check parentheses, quotes, pipe placement. The error message names the column and offers a "did you mean" hint for typos. |
| `OutputShapeError` | The chosen output format needs a different shape (e.g., TOML needs a map root). Lambë's error message names the bridge `as(...)` to apply. |

## Format auto-detection

| Extension | Format |
|---|---|
| `.json` | JSON |
| `.yaml`, `.yml` | YAML |
| `.toml` | TOML |
| `.tf`, `.hcl` | HCL |
| `.csv` | CSV |
| `.tsv`, `.tab` | TSV |
| `.md`, `.markdown` | Markdown |

Stdin sniffs from content. Override with `-f`/`--format`.

## In Dart code

```dart
import 'package:lambe/lambe.dart';

final name = query('.users[0].name', data);
final active = queryString('.users | filter(.active)', jsonString);
final config = queryString(
  '.database.host', tomlString, format: Format.toml,
);
```

In tests:

```dart
import 'package:lambe_test/lambe_test.dart';

expect(response, lamWhere('.errors | length == 0'));
expect(config, lamEquals('.database.port', 5432));
```

## MCP server (sandboxed agents)

`lam-mcp` exposes the same query surface via the Model Context Protocol
for agents that can't shell out. Tools: `lambe_query`,
`lambe_print_shape`, `lambe_check`, `lambe_explain`, `lambe_assert`. Most
agents should prefer running `lam` from the shell directly — it's
cheaper per turn and the same capabilities. Reach for the MCP server
when shell access isn't available.
