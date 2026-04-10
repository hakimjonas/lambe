# Getting Started

Install Lambë, query data files from the command line, and explore data interactively in the REPL.

## Install

### From pub.dev (Dart users)

```bash
dart pub global activate lambe
```

This installs `lam` and `lam-mcp`. Make sure `~/.pub-cache/bin` is on your PATH.

### Pre-built binary (no Dart required)

Download from [GitHub Releases](https://github.com/hakimjonas/lambe/releases) and place on your PATH:

```bash
# Linux
curl -L https://github.com/hakimjonas/lambe/releases/latest/download/lam-linux-x64 -o lam
chmod +x lam
sudo mv lam /usr/local/bin/

# macOS
curl -L https://github.com/hakimjonas/lambe/releases/latest/download/lam-macos-x64 -o lam
chmod +x lam
sudo mv lam /usr/local/bin/
```

### Build from source

Requires Dart SDK 3.7+:

```bash
git clone https://github.com/hakimjonas/lambe.git
cd lambe
dart pub get
dart compile exe bin/lam.dart -o lam
dart compile exe bin/mcp_server.dart -o lam-mcp
sudo mv lam lam-mcp /usr/local/bin/
```

### Install man page

```bash
sudo cp doc/lam.1 /usr/share/man/man1/
```

## Your first query

Create a file called `data.json`:

```json
{
  "users": [
    {"name": "Alice", "age": 25, "active": true},
    {"name": "Bob", "age": 35, "active": false},
    {"name": "Carol", "age": 42, "active": true}
  ],
  "version": "1.0.0"
}
```

Extract a value:

```bash
$ lam '.version' data.json
"1.0.0"
```

The `.` refers to the whole document. `.version` accesses the `version` field.

## Access nested data

```bash
$ lam '.users[0].name' data.json
"Alice"
```

`[0]` indexes into a list. `.name` accesses a field. These chain left to right.

## Pipelines

The `|` operator passes a result into an operation:

```bash
$ lam '.users | map(.name)' data.json
["Alice", "Bob", "Carol"]
```

This takes `.users` (the list) and transforms each element with `map(.name)`.

Chain multiple operations:

```bash
$ lam '.users | filter(.active) | map(.name)' data.json
["Alice", "Carol"]
```

`filter(.active)` keeps elements where `.active` is true. Then `map(.name)` extracts names.

## Aggregate

```bash
$ lam '.users | map(.age) | sum' data.json
102

$ lam '.users | map(.age) | avg' data.json
34.0
```

## Build new objects

```bash
$ lam '.users | map({name, senior: .age > 40})' data.json
[
  {"name": "Alice", "senior": false},
  {"name": "Bob", "senior": false},
  {"name": "Carol", "senior": true}
]
```

`{name}` is shorthand for `{name: .name}`. Shorthand and explicit values mix freely.

## Query other formats

Lambë auto-detects the format from the file extension:

```bash
$ lam '.database.host' config.toml
"localhost"

$ lam '.spec.containers[0].image' deployment.yaml
"nginx:1.21"

$ lam '.resource | map(._labels)' main.tf
[["aws_instance", "web"], ["aws_s3_bucket", "logs"]]

$ lam '. | map(.name)' users.csv
["Alice", "Bob", "Carol"]
```

Supported: JSON, YAML, TOML, HCL/Terraform, XML, CSV, TSV.

## Convert between formats

```bash
$ lam --to yaml '.users[0]' data.json
name: Alice
age: 25
active: true

$ lam --to csv '.users | map({name, age})' data.json
name,age
Alice,25
Bob,35
Carol,42
```

## Inspect structure

When you don't know what's in a file:

```bash
$ lam --schema data.json
{
  "users": [
    {
      "name": "string",
      "age": "number",
      "active": "boolean"
    }
  ],
  "version": "string"
}
```

## Validate in CI

```bash
$ lam --assert '.version != "0.0.0"' data.json
$ echo $?
0
```

The exit code is 0 if the assertion passes, 1 if it fails.

## The REPL

For exploring unfamiliar data, use interactive mode:

```bash
$ lam -i data.json
lambe v0.1.0 - type :help for commands, :q to quit
Data loaded: {2 fields, 3 users}

lambe>
```

Type queries at the prompt. Press Tab to complete field names:

```
lambe> .us<TAB>
lambe> .users

lambe> .users | filter(.age > 30) | map(.name)
["Bob", "Carol"]
```

REPL commands start with `:` to distinguish them from queries:

```
lambe> :schema
{
  "users": [{"name": "string", "age": "number", "active": "boolean"}],
  "version": "string"
}

lambe> :to yaml
Output format: yaml

lambe> :help
Commands:
  :schema         Show data structure
  :to <format>    Set output format (json, yaml, toml, xml, csv, tsv, hcl)
  :raw            Toggle raw string output
  :pretty         Toggle pretty-printing
  :load <file>    Load a different data file
  :history        Show query history
  :help           Show this help
  :quit, :q       Exit

lambe> :q
```

## Use as a Dart library

```dart
import 'package:lambe/lambe.dart';

final name = query('.users[0].name', data);
final active = queryString('.users | filter(.active)', jsonString);
```

Add to your `pubspec.yaml`:

```yaml
dependencies:
  lambe: ^0.1.0
```

## Next steps

- [Syntax reference](syntax.md) for the full language
- [REPL guide](repl.md) for keyboard shortcuts and completion details
- [Recipes](recipes.md) for real-world patterns with Kubernetes, Terraform, CI, and CSV
