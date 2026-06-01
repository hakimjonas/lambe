# Recipes

Real-world query patterns organized by domain.

## JSON API responses

Extract a nested value:

```bash
$ curl -s https://api.example.com/user/1 | lam '.data.profile.email'
```

Filter a list and project fields:

```bash
$ lam '.results | filter(.status == "active") | map({id, name})' response.json
```

Build a summary:

```bash
$ lam '{
  total: .items | length,
  active: .items | filter(.active) | length,
  revenue: .items | map(.price) | sum
}' data.json
```

Count by group:

```bash
$ lam '.users | group_by(.role) | map({role: .key, count: .values | length})' data.json
```

## Kubernetes (YAML)

Get container images from a deployment:

```bash
$ lam '.spec.template.spec.containers | map(.image)' deployment.yaml
```

Find containers without resource limits:

```bash
$ lam '.spec.template.spec.containers | filter(has("resources") == false) | map(.name)' deployment.yaml
```

Check replica count:

```bash
$ lam --assert '.spec.replicas >= 2' deployment.yaml
```

List all labels:

```bash
$ lam '.metadata.labels' deployment.yaml
```

Get all container ports:

```bash
$ lam '.spec.template.spec.containers | map(.ports) | flatten | map(.containerPort)' deployment.yaml
```

## Terraform (HCL)

List all resources:

```bash
$ lam '.resource | map(._labels)' main.tf
```

Filter by resource type:

```bash
$ lam '.resource | filter(._labels[0] == "aws_instance") | map(._labels[1])' main.tf
```

Get all variable defaults:

```bash
$ lam '.variable | map({name: ._labels[0], default})' variables.tf
```

Check all S3 buckets have tags:

```bash
$ lam --assert '.resource | filter(._labels[0] == "aws_s3_bucket") | filter(has("tags") == false) | length == 0' main.tf
```

## CSV and TSV

Filter rows:

```bash
$ lam '. | filter(.status != "closed") | map(.title)' issues.csv
```

Extract columns:

```bash
$ lam '. | map({name, email})' contacts.csv
```

Convert JSON to CSV for a spreadsheet:

```bash
$ lam --to csv '.users | map({name, age, email})' data.json > users.csv
```

Convert CSV to JSON:

```bash
$ lam '.' data.csv > data.json
```

Aggregate a numeric column. CSV cells are always strings, so coerce with
`to_number` before arithmetic:

```bash
$ lam '. | map(.price | to_number) | sum' orders.csv
1247.50

$ lam '. | map(.count | to_number) | max' inventory.csv
942
```

## Markdown

Extract heading text (`text` walks the node tree, so it handles
emphasis, inline code, links, and nested formatting):

```bash
$ lam '.children | filter(.type == "heading") | map(text)' README.md
```

Headings paired with their level:

```bash
$ lam '.children | filter(.type == "heading") | map({level, text: text})' README.md
```

Plain text from each paragraph:

```bash
$ lam '.children | filter(.type == "paragraph") | map(text)' doc.md
```

Code-block contents by language:

```bash
$ lam '.children | filter(.type == "code_block" && .language == "python") | map(.code)' tutorial.md
```

Full document prose, no markup:

```bash
$ lam '. | text' README.md
```

### Querying a CHANGELOG

A release notes file follows a recurring shape: H2 per release, H3 per
subsection. The same `text` op recovers the release names regardless of
inline formatting.

Every release version:

```bash
$ lam '.children | filter(.type == "heading" and .level == 2) | map(text)' CHANGELOG.md
[
  "0.9.0",
  "0.8.0",
  "0.7.1"
]
```

Latest release name:

```bash
$ lam '.children | filter(.type == "heading" and .level == 2) | map(text) | first' CHANGELOG.md
"0.9.0"
```

Every subsection title (informational; structure under each release):

```bash
$ lam '.children | filter(.type == "heading" and .level == 3) | map(text)' CHANGELOG.md
```

Check for duplicate release entries (returns `true` when none):

```bash
$ lam '.children | filter(.type == "heading" and .level == 2) | map(text) | length == (.children | filter(.type == "heading" and .level == 2) | map(text) | unique | length)' CHANGELOG.md
true
```

These same queries are gated by `--assert` in `tool/lint_changelog.sh`,
which CI runs on every push: lambë itself validates lambë's release
notes, parsed by lambë's own Markdown parser. Real-world example of the
pattern.

## TOML (Rust, Python config)

Get a dependency version from Cargo.toml:

```bash
$ lam '.dependencies.serde.version' Cargo.toml
```

List all dependencies:

```bash
$ lam '.dependencies | keys' Cargo.toml
```

## GitHub Actions (YAML)

List all jobs:

```bash
$ lam '.jobs | keys' .github/workflows/ci.yml
```

Find jobs without timeout:

```bash
$ lam '.jobs | to_entries | filter(.value | has("timeout-minutes") == false) | map(.key)' ci.yml
```

List all actions used (security audit):

```bash
$ lam '.jobs | values | map(.steps) | flatten | filter(has("uses")) | map(.uses) | unique' ci.yml
```

Validate required fields:

```bash
$ lam --assert '.on != null' .github/workflows/ci.yml
$ lam --assert '.jobs | keys | length > 0' .github/workflows/ci.yml
```

## Format conversion

JSON to YAML:

```bash
$ lam --to yaml '.' data.json
```

JSON to CSV:

```bash
$ lam --to csv '.users | map({name, age})' data.json
```

YAML to TOML:

```bash
$ lam --to toml '.' config.yaml
```

TOML to JSON:

```bash
$ lam --to json '.' config.toml
```

## CI validation patterns

Version is set:

```bash
$ lam --assert '.version != "0.0.0"' package.json
```

List is non-empty:

```bash
$ lam --assert '.users | length > 0' data.json
```

Field exists:

```bash
$ lam --assert '. | has("required_field")' config.json
```

All items pass a check:

```bash
$ lam --assert '.items | filter(.price <= 0) | length == 0' data.json
```

No duplicates:

```bash
$ lam --assert '.users | map(.email) | unique | length == (.users | length)' data.json
```

## package.json / pubspec.yaml

Get the package name and version:

```bash
$ lam '{name, version}' package.json
$ lam '{name, version}' pubspec.yaml
```

List all dependencies:

```bash
$ lam '.dependencies | keys' package.json
$ lam '.dependencies | keys' pubspec.yaml
```

Find a specific dependency version:

```bash
$ lam '.dependencies.react' package.json
$ lam '.dependencies.rumil' pubspec.yaml
```

Check for outdated version:

```bash
$ lam --assert '.version != "0.0.0"' package.json
```

## Object projection after pipe

Select specific fields from a result:

```bash
$ lam '.users[0] | {name, age}' data.json
```

Project fields in a map pipeline:

```bash
$ lam '.users | filter(.active) | map(. | {name, email})' data.json
```

Add computed fields:

```bash
$ lam '.items | map({name, total: .price * .qty, expensive: .price > 100})' data.json
```

Conditional labels:

```bash
$ lam '.users | map({name, status: if .active then "active" else "inactive"})' data.json
```

## String interpolation in pipelines

Generate labels:

```bash
$ lam '.users | map("\(.name) (\(.age))")' data.json
```

Build key-value strings:

```bash
$ lam '.config | to_entries | map("\(.key)=\(.value)")' config.json
```

## Chaining multiple operations

Sort, filter, then aggregate:

```bash
$ lam '.orders | filter(.status == "complete") | map(.total) | sum' orders.json
```

Group, then summarize each group:

```bash
$ lam '.users | group_by(.role) | map({role: .key, count: .values | length, avg_age: .values | map(.age) | avg})' data.json
```

Flatten nested lists, then deduplicate:

```bash
$ lam '.users | map(.tags) | flatten | unique | sort' data.json
```

## Schema exploration

Start with `--schema` to understand unfamiliar data:

```bash
$ lam --schema data.json
{
  "users": [{"name": "string", "age": "number", "active": "boolean"}],
  "config": {"database": {"host": "string", "port": "number"}},
  "version": "string"
}
```

Then drill in:

```bash
$ lam --schema deployment.yaml
$ lam '.spec.template.spec' deployment.yaml
$ lam -i deployment.yaml
```

## Bridging shapes to output formats with `as(fmt)`

Some output formats restrict the root shape: TOML and HCL want a map
at the top level; CSV and TSV want a list of records. When the
pipeline produces something else, `as(fmt)` applies a curated bridge
so the value fits.

There are four canonical bridges. All four are reachable via `as(...)`
or via the CLI's `--to` flag with `--flatten-cells refuse` (the
default).

### `list<scalar> | as(toml)` and `as(hcl)`

Wrap a list under a single `items` key.

```
$ lam -n --to toml '["a", "b", "c"] | as(toml)'
items = ["a", "b", "c"]


$ lam -n --to hcl '["a", "b"] | as(hcl)'
items = ["a", "b"]
```

### `scalar | as(toml)` and `as(hcl)`

Wrap a scalar under a single `value` key.

```
$ lam -n --to toml '"hello" | as(toml)'
value = "hello"


$ lam -n --to hcl '"hello" | as(hcl)'
value = "hello"
```

### `map | as(csv)` and `as(tsv)`

Convert a map to a two-column key/value list of records via
`to_entries`.

```
$ lam -n --to csv '{a: 1, b: 2} | as(csv)'
key,value
a,1
b,2
```

### `scalar | as(csv)` and `as(tsv)`

Compose: wrap the scalar under `value`, then `to_entries`. The
result is a one-row CSV with a `key`/`value` header.

```
$ lam -n --to csv '42 | as(csv)'
key,value
value,42
```

### When `as(fmt)` does nothing

A shape that already satisfies the format's requirement passes
through unchanged: `map | as(toml)` is identity, as is `list<map> |
as(csv)`. The bridge fires only when there's a real mismatch.

## Next steps

- [Getting started](getting-started.md) for installation
- [Syntax reference](syntax.md) for the full language
- [REPL guide](repl.md) for interactive exploration
