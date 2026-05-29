# Lambë

*A query language for structured data that shows you what you're working with.*

`lam` queries JSON, YAML, TOML, HCL, CSV, TSV, and Markdown. Unlike other query tools, it tells you what your query *does* before you run it — the shape at each pipe stage, which output formats can serialize the result, what would go wrong.

Use it when you don't already know the data: inspecting an unfamiliar API response, auditing a Helm chart, verifying a CI pipeline's assumptions, or asking an AI agent to extract something without guessing at the structure.

```
$ lam --to toml '.dependencies | keys' pubspec.yaml
Error: TOML output requires a map at the root, got list<string>.
Try appending one of:
  | as(toml)    # Wraps the list under a single-entry map (equivalent to `{items: .}`).

$ lam --to toml '.dependencies | keys | as(toml)' pubspec.yaml
items = ["rumil", "rumil_parsers", "rumil_expressions"]
```

Queries are bounded and always terminate. No recursion, no lambdas, no `def`. That's the tradeoff: Lambe doesn't try to be a programming language, so its shape inference, `--explain`, `--schema`, and error remediations all work.

*Lambë (pronounced "lam-beh") means "language" in Quenya (Tolkien's elvish). The package name is `lambe` for ASCII compatibility.*

## Installation

One-line installer (Linux and macOS, no `sudo`, verifies SHA256 checksums):

```bash
curl -fsSL https://raw.githubusercontent.com/hakimjonas/lambe/main/install.sh | sh
```

This downloads `lam` and `lam-mcp` from the latest GitHub release into `~/.local/bin/`. Environment variables `LAMBE_VERSION` (pin a version) and `LAMBE_PREFIX` (change install dir) are supported; see the script for details.

Other options:

```bash
# From pub.dev (Dart users)
dart pub global activate lambe

# Dart library
dart pub add lambe

# Build from source
git clone https://github.com/hakimjonas/lambe.git && cd lambe
dart compile exe bin/lam.dart -o lam
```

See [Getting started](doc/getting-started.md) for all installation options.

## Shape-aware output

Lambë checks the result of your query against the shape the target format can serialize. When they match, output is produced. When they don't, the error names the required shape and lists query fragments that would bridge it. In an interactive terminal, Lambë offers to apply the chosen fragment and retry in place.

```
$ lam --to toml '.name' pubspec.yaml
TOML output requires a map at the root, got string.
Try appending one of:
  | as(toml)    # Wraps the scalar under a single-entry map (equivalent to `{value: .}`).

Apply a bridge?
  [1] | as(toml)    # Wraps the scalar under a single-entry map (equivalent to `{value: .}`).
  [q] cancel
> 1
value = "rumil"
```

The same flow applies to CSV and TSV (which require a list of records at the root) and HCL (which requires a map).

Suggestions surface the intent-level `as(<format>)` form. The explanation names the raw fragment (`{value: .}`, `to_entries`, etc.) the bridge composes, so `--explain` and manual composition stay available to anyone who wants them.

### Non-scalar cells in CSV/TSV

By default, nested lists or maps in CSV/TSV cells are rejected — there is no faithful delimited rendering for them. When you need a quick export and lossy is acceptable, pass `--flatten-cells json` (CLI) or `:flatten-cells json` (REPL) to encode them as JSON strings inline. Round-tripping the resulting file back into Lambë does not recover the original structure; prefer reshaping the data query-side when fidelity matters.

### `as(fmt)` — bridging in the query language

When the shape of the target format is known up front, `as(fmt)` performs the bridge inside the query. The combinator is a no-op when the input already satisfies the target, applies a single curated bridge when one exists, and lists the candidates when more than one could apply.

```
$ lam --to toml '.dependencies | as(toml)' pubspec.yaml
rumil = "^0.6.0"
rumil_parsers = "^0.6.0"
rumil_expressions = "^0.6.0"

$ lam --to csv '.dependencies | as(csv)' pubspec.yaml
key,value
rumil,^0.6.0
rumil_parsers,^0.6.0
rumil_expressions,^0.6.0
```

`as` accepts `json`, `yaml`, `toml`, `csv`, `tsv`, and `hcl`.

### `--explain` — see the shape at every pipe stage

`--explain` walks the pipe backbone of a query and reports the shape at each stage, followed by the set of output formats the final shape can be serialized as. It performs static analysis only and does not evaluate the query; pass a data file to seed with real shape information, or omit it to trace against an unknown input.

```
$ lam --explain '.dependencies | keys' pubspec.yaml
.dependencies  : map<rumil: string, rumil_parsers: string, rumil_expressions: string>
| keys         : list<string>

Writable as: json, yaml, csv, tsv
Not writable as: toml, hcl
```

Explain flags provably-empty filters (`filter(.missing)` on a known shape) and runtime-rejection mismatches (`filter` on a non-list input) by default. Pass `--explain-trivial` to also flag `sort_by`/`group_by`/`map`/`unique_by` whose argument references a missing field (often a typo, sometimes intentional). For agent tooling and build pipelines, `--explain-json` emits the same information as a structured JSON document.

### `--schema` — declare a shape and let Lambe check your work

When you have a JSON Schema for your data — from an API contract, OpenAPI spec, or hand-written docs — point `--schema` at it:

```
$ lam --schema api.schema.json --explain '.users | map(.email)' response.json
.users         : list<map<id: string, name: string, email: optional<string>>>
| map(.email)  : list<optional<string>>

Writable as: json, yaml, csv, tsv
Not writable as: toml, hcl
```

The schema fills in information data alone can't express: optional fields (from JSON Schema's `required`), element shapes of empty lists, types `shapeOf` couldn't infer from sampling. `--explain` shows them; the evaluator trusts them.

With data present, Lambe also validates: a schema saying `age: number` against data with `age: "30"` exits 1 at load time with a JSON-path-annotated diagnostic. No silent drift, no running a query against data that doesn't match its contract.

A sibling `<datafile>.schema.json` is auto-detected, so a project convention of placing schemas next to data works without explicit flags.

The reverse direction is symmetrical: `lam --print-shape data.json` emits the inferred shape as a JSON Schema document. Round-trip:

```
lam --print-shape data.json > data.schema.json    # bootstrap a schema from data
lam --schema data.schema.json '.users' data.json  # use it back
```

Accepted JSON Schema keywords: `type`, `properties`, `items`, `required`. Value-level constraints (`minimum`, `pattern`, `enum`, etc.), structural combinators (`allOf`, `oneOf`), `$ref`, and conditional schemas are rejected with a per-keyword error. Lambe is a shape system, not a validation engine — for richer validation, reach for `ajv` or `check-jsonschema`.

## Query Syntax

Queries start with `.` (the current data) and chain operations with `|`:

```
.                              the whole document
.name                          access a field
.users[0]                      index into a list
.users[0].address.city         chain access
.users | filter(.age > 30)     pipe into an operation
.users | map(.name)            transform each element
```

Pipelines read left to right. Each `|` passes its result to the next operation:

```
.users | filter(.active) | sort_by(.name) | map(.name)
```

This takes `.users`, keeps active ones, sorts by name, and extracts names.

### Expressions

```
.price * .qty                  arithmetic (+, -, *, /, %)
.age > 30                      comparison (<, >, <=, >=, ==, !=)
.active && .verified           logic (&&, ||, !)
if .age > 65 then "senior" else "active"   conditional
{name, total: .price * .qty}   construct a new object
"\(.name) is \(.age)"          string interpolation
.[1:3]                         slice a list or string
```

### Operations

Operations follow `|` and transform the piped value:

```
. | filter(.age > 30)          keep matching elements
. | map(.name)                 transform each element
. | sort_by(.age)              sort by a key
. | group_by(.dept)            group into [{key, values}]
. | length                     count elements
. | first                      first element
. | sum                        sum numbers
. | keys                       map keys or list indices
. | has("field")               check if a field exists
. | unique                     remove duplicates
. | flatten                    flatten one level of nesting
. | to_entries                 map to [{key, value}] pairs
. | filter_values(. > 5)       filter a map's values
. | as(toml)                   bridge to an output format
```

See the full list in [Pipeline Operations](#pipeline-operations) below.

## CLI

```bash
# Extract values
lam '.database.host' config.toml
lam '.spec.containers[0].image' deployment.yaml

# Filter and transform
lam '.users | filter(.age > 30) | map(.name)' data.json

# Aggregate
lam '.items | map(.price) | sum' data.json

# Sort and pick
lam '.items | sort_by(.price) | first' data.json

# Object construction
lam '.users | map({name, senior: .age > 65})' data.json

# String interpolation
lam '.users | map("\(.name) is \(.age)")' data.json

# Shape trace
lam --explain '.users | map(.name)' data.json

# Shape inspection (JSON Schema output)
lam --print-shape data.json

# Schema-checked queries: validate data against a schema as it runs
lam --schema api.schema.json '.users | map(.email)' response.json

# CI validation
lam --assert '.version != "0.0.0"' package.json
lam --assert '.replicas >= 2' deployment.yaml

# Format conversion
lam --to yaml '.config' data.json
lam --to csv '.users | map({name, age})' data.json
lam --to toml '.config | as(toml)' data.json
lam --to csv --flatten-cells json '.users' data.json   # encode nested cells as JSON

# Line-delimited JSON (logs, event streams)
lam --ndjson '.user.id' events.ndjson
tail -f app.log | lam --ndjson '.level'

# Query any format (auto-detected from extension)
lam '. | filter(.status != "closed")' issues.csv
lam '.resource | map(._labels)' main.tf
lam '.children | filter(.type == "heading") | map(.children[0].text)' README.md

# Pipe from stdin
curl -s https://api.example.com/users | lam '.results | filter(.active)'
```

## Interactive REPL

```bash
lam -i data.json
```

```
lambe v0.9.0 - type :help for commands, :q to quit
Data loaded: {3 fields, 42 users}

lambe> .users | filter(.age > 30) | map(.name)
["Bob", "Carol"]

lambe> .users[0]
{name: "Alice", age: 25, active: true}

lambe> :schema
{users: [{name: "string", age: "number", active: "boolean"}]}

lambe> :to yaml
Output format: yaml
```

When a query produces a result the current output format cannot serialize, the REPL lists the available bridges inline; pressing the number of a suggestion applies it and prints the bridged output. Tab completion works on field names (`.us<TAB>`) and pipeline operations (`| fil<TAB>`). The REPL also supports syntax highlighting, persistent history (`~/.lambe_history`), Ctrl+R reverse search, and multi-line input with `\` continuation.

## Library

```dart
import 'package:lambe/lambe.dart';

// Query pre-parsed data
final name = query('.users[0].name', data);

// Query a JSON string
final version = queryJson('.version', '{"version": "1.0.0"}');

// Query any format
final host = queryString('.database.host', tomlString, format: Format.toml);

// Parse once, evaluate many times
final ast = parseAst('.users | filter(.active) | map(.name)');
final result1 = evaluateAst(ast, dataset1);
final result2 = evaluateAst(ast, dataset2);

// Format conversion
final yaml = formatOutput(data, OutputFormat.yaml);
final csv = formatOutput(users, OutputFormat.csv);

// Shape inference and JSON Schema output
final shape = shapeOf(data);                    // Shape ADT
final schemaJson = renderJsonSchema(shape);     // JSON Schema text

// Or parse a schema file and merge with observed data
final schema = parseJsonSchema(schemaSource);
final merged = mergeSchemaWithData(schema, shape);  // throws on disagreement
```

### Shape and bridging API

```dart
// Infer the structural shape of a value
final shape = shapeOf(data);
// e.g. SMap({'users': SList(SMap({'name': SString(), 'age': SNum()}))})

// Check whether a value can be written in a given format
final report = canWriteAs(result, OutputFormat.toml);
switch (report) {
  case Writable():
    stdout.writeln(formatOutput(result, OutputFormat.toml));
  case NotWritable(:final suggestions):
    for (final r in suggestions) {
      print('${r.label}: | ${r.display} — ${r.explanation}');
    }
}

// Compose a user query with a bridge fragment
final bridges = synthesize(shape, OutputFormat.csv);
if (bridges.isNotEmpty) {
  final composed = applyBridge(userAst, bridges.first);
  final bridged = evaluateAst(composed, data);
}

// Static shape trace
final trace = explain(parseAst('.users | map(.name)'), shapeOf(data));
for (final stage in trace.stages) {
  print('${stage.source}: ${renderShape(stage.shape)}');
}
```

## Supported Formats

| Format | Input | Output | Conformance |
|--------|:-----:|:------:|-------------|
| JSON | yes | yes | RFC 8259 (318/318) |
| YAML | yes | yes | YAML 1.2.2 (333/333) |
| TOML | yes | yes | TOML 1.1 (681/681) |
| HCL/Terraform | yes | yes | HashiCorp spec (2760/2760) |
| CSV | yes | yes | RFC 4180 + auto-dialect detection |
| TSV | yes | yes | Tab-separated variant of CSV |
| Markdown | yes | — | CommonMark 0.31.2 (652/652) |

Parsers from [rumil_parsers](https://pub.dev/packages/rumil_parsers), tested against official spec suites.

Markdown is input-only in this release. The Markdown AST is a presentation tree rather than a data structure, so there is no general-purpose mapping from arbitrary query results back to Markdown text. Projections of a Markdown document (lists of headings, counts, filtered sections) emit as JSON, YAML, CSV, or TSV through the usual `--to` flag.

## Pipeline Operations

| Operation | Example | Description |
|-----------|---------|-------------|
| `filter` | `.users \| filter(.active)` | Keep elements matching predicate |
| `map` | `.users \| map(.name)` | Transform each element |
| `sort` | `. \| sort` | Sort naturally |
| `sort_by` | `.users \| sort_by(.age)` | Sort by key |
| `group_by` | `.users \| group_by(.dept)` | Group into `{key, values}` |
| `unique` | `. \| unique` | Remove duplicates |
| `unique_by` | `.users \| unique_by(.id)` | Remove duplicates by key |
| `flatten` | `. \| flatten` | Flatten one level |
| `reverse` | `. \| reverse` | Reverse order |
| `keys` | `. \| keys` | Map keys or list indices |
| `values` | `. \| values` | Map values |
| `length` | `. \| length` | Length of list, map, or string |
| `first` | `. \| first` | First element |
| `last` | `. \| last` | Last element |
| `sum` | `. \| sum` | Sum numbers |
| `avg` | `. \| avg` | Average |
| `min` | `. \| min` | Minimum |
| `max` | `. \| max` | Maximum |
| `has` | `. \| has("name")` | Check field exists |
| `to_entries` | `. \| to_entries` | Map to `[{key, value}]` |
| `from_entries` | `. \| from_entries` | `[{key, value}]` to map |
| `to_number` | `.price \| to_number` | Parse a string as a number |
| `type` | `. \| type` | Runtime type as a string |
| `filter_values` | `. \| filter_values(. > 5)` | Filter map values |
| `map_values` | `. \| map_values(. * 2)` | Transform map values |
| `filter_keys` | `. \| filter_keys(. != "secret")` | Filter map keys |
| `as` | `. \| as(toml)` | Bridge to an output format's shape |

## AI Integration

Lambë ships as both an [Agent Skill](https://agentskills.io) (loaded
into an agent's session as expertise) and an MCP server (callable as a
runtime tool).

### Agent Skill

The skill folder lives at `.agents/skills/lambe/` in this repository,
following the cross-vendor [agent-skills specification](https://github.com/agentskills/agentskills)
that Claude Code, OpenAI Codex, GitHub Copilot, Cursor, and the
Microsoft Agent Framework all read.

To make Lambë available to an agent in another project, copy the
folder into the agent-conventional location:

```bash
# Personal (available across all your projects)
git clone https://github.com/hakimjonas/lambe /tmp/lambe-skill
mkdir -p ~/.agents/skills
cp -r /tmp/lambe-skill/.agents/skills/lambe ~/.agents/skills/

# Project-local
cp -r /tmp/lambe-skill/.agents/skills/lambe <your-project>/.agents/skills/
```

Agents that follow the spec auto-discover the skill at session start.

### MCP Server

Install, then add `.mcp.json` to your project:

```json
{
  "mcpServers": {
    "lambe": {
      "command": "lam-mcp",
      "args": []
    }
  }
}
```

This gives AI assistants five tools that cover the whole feedback loop:

- `lambe_query` — extract/filter/transform, with an optional `schema` parameter that validates data structurally before the query runs.
- `lambe_print_shape` — inspect unfamiliar data; returns a JSON Schema subset document.
- `lambe_check` — validate data against a JSON Schema. Returns `{"ok": true}` or `{"ok": false, "error": "..."}` naming the disagreement path.
- `lambe_explain` — trace a query statically (with or without data); returns a structured JSON report with shape-per-stage, warnings, and writability.
- `lambe_assert` — boolean assertion on a query result.

When `lambe_query` encounters a shape mismatch with the requested output format, the error response includes a structured `suggestions` array: each entry carries a `template_text`, an `apply_as` (the complete query formed by appending the template to the original expression), and a one-line `explanation`. Agents can call the tool again with an `apply_as` verbatim.

### For AI Coding Agents

Add [AGENTS.md](AGENTS.md) and `.mcp.json` to your project root. AI assistants that open the project will discover and use Lambë for data queries.

### In CI

```yaml
# Validate config in GitHub Actions
- run: |
    dart pub global activate lambe
    lam --assert '.version != "0.0.0"' pubspec.yaml
    lam --assert '.jobs | keys | length > 0' .github/workflows/ci.yml
```

## Test Matchers

The [lambe_test](lambe_test/) package provides test matchers for Dart:

```dart
import 'package:lambe_test/lambe_test.dart';

expect(response, lamWhere('.errors | length == 0'));
expect(config, lamEquals('.database.port', 5432));
expect(data, lamMatches('.name', startsWith('A')));
expect(data, lamHas('.users[0].address.city'));
```

## Documentation

- [Getting started](doc/getting-started.md) - install and first queries
- [Syntax reference](doc/syntax.md) - the full query language
- [REPL guide](doc/repl.md) - interactive mode, commands, keyboard shortcuts
- [Schema guide](doc/schema.md) - the JSON Schema subset, merge semantics, round-trip
- [Recipes](doc/recipes.md) - real-world patterns for Kubernetes, Terraform, CI, CSV
- [Man page](doc/lam.1.md) - Unix man page (`man -l doc/lam.1`)

## What lambé is not

Lambé is a bounded tree transformer over JSON-shaped data. It
deliberately omits Turing-completeness, user-defined functions,
recursive descent (`..`), `try`/`catch`, regex, streaming, and
in-place mutation. Staying bounded is what makes shape inference,
`--explain`, and `as(fmt)` bridging work.

See [doc/non-goals.md](doc/non-goals.md) for the full list and the
lambé idiom that replaces each omission.

## Design

See [DESIGN.md](DESIGN.md) for architecture and design decisions.

## Part of the Arda Ecosystem

Built on [Rumil](https://pub.dev/packages/rumil) parser combinators with left-recursive grammar support.

- [Rumil](https://pub.dev/packages/rumil) - parser combinators with left recursion
- [Rumil Parsers](https://pub.dev/packages/rumil_parsers) - format parsers for JSON, YAML, TOML, XML, CSV, HCL, Proto3, Markdown
- [Rumil Expressions](https://pub.dev/packages/rumil_expressions) - shared evaluation helpers
