# Lambë

Query JSON, YAML, TOML, HCL, XML, CSV, and Markdown with a composable pipeline DSL.

Built on [Rumil](https://pub.dev/packages/rumil) parser combinators with left-recursive grammar support.

*Lambë (pronounced "lam-beh") means "language" in Quenya (Tolkien's elvish). The package name is `lambe` for ASCII compatibility.*

## Installation

```bash
# Pre-built binary (no Dart required)
curl -L https://github.com/hakimjonas/lambe/releases/latest/download/lam-linux-x64 -o lam
chmod +x lam && sudo mv lam /usr/local/bin/

# From pub.dev (Dart users)
dart pub global activate lambe

# Dart library
dart pub add lambe

# Build from source
git clone https://github.com/hakimjonas/lambe.git && cd lambe
dart compile exe bin/lam.dart -o lam
```

See [Getting started](doc/getting-started.md) for all installation options.

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

# Schema inference
lam --schema data.json

# CI validation
lam --assert '.version != "0.0.0"' package.json
lam --assert '.replicas >= 2' deployment.yaml

# Format conversion
lam --to yaml '.config' data.json
lam --to csv '.users | map({name, age})' data.json
lam --to xml '.data' config.json

# Query any format (auto-detected from extension)
lam '.project.dependencies' pom.xml
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
lambe v0.1.0 - type :help for commands, :q to quit
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

Type queries at the `lambe>` prompt. REPL commands start with `:` to distinguish them from queries: `:schema`, `:to yaml`, `:load file.json`, `:history`, `:help`, `:quit`.

Tab completion works on field names (`.us<TAB>`) and pipeline operations (`| fil<TAB>`). Also supports syntax highlighting, persistent history (`~/.lambe_history`), Ctrl+R reverse search, and multi-line input with `\` continuation.

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
final ast = parse('.users | filter(.active) | map(.name)');
final result1 = eval(ast.valueOrNull!, dataset1);
final result2 = eval(ast.valueOrNull!, dataset2);

// Format conversion
final yaml = formatOutput(data, OutputFormat.yaml);
final csv = formatOutput(users, OutputFormat.csv);

// Schema inference
final schema = inferSchema(data);
```

## Supported Formats

| Format | Input | Output | Conformance |
|--------|:-----:|:------:|-------------|
| JSON | yes | yes | RFC 8259 (318/318) |
| YAML | yes | yes | YAML 1.2.2 (333/333) |
| TOML | yes | yes | TOML 1.1 (681/681) |
| HCL/Terraform | yes | yes | HashiCorp spec (2760/2760) |
| XML | yes | yes | W3C XML 1.0 (1506/1506) |
| CSV | yes | yes | RFC 4180 + auto-dialect detection |
| TSV | yes | yes | Tab-separated variant of CSV |
| Markdown | yes | — | CommonMark 0.31.2 (652/652) |

Parsers from [rumil_parsers](https://pub.dev/packages/rumil_parsers), tested against official spec suites.

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
| `filter_values` | `. \| filter_values(. > 5)` | Filter map values |
| `map_values` | `. \| map_values(. * 2)` | Transform map values |
| `filter_keys` | `. \| filter_keys(. != "secret")` | Filter map keys |

## AI Integration

Lambë includes an MCP server for use with AI coding assistants.

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

This gives AI assistants three tools: `lambe_query` (extract/filter/transform), `lambe_schema` (structure inspection), `lambe_assert` (validation).

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
- [Recipes](doc/recipes.md) - real-world patterns for Kubernetes, Terraform, CI, CSV, XML
- [Man page](doc/lam.1.md) - Unix man page (`man -l doc/lam.1`)

## Design

See [DESIGN.md](DESIGN.md) for architecture and design decisions.

## Part of the Arda Ecosystem

- [Rumil](https://pub.dev/packages/rumil) - parser combinators with left recursion
- [Rumil Parsers](https://pub.dev/packages/rumil_parsers) - format parsers for JSON, YAML, TOML, XML, CSV, HCL, Proto3
- [Rumil Expressions](https://pub.dev/packages/rumil_expressions) - shared evaluation helpers
