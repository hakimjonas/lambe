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

## XML (Maven, .NET)

List dependencies from pom.xml:

```bash
$ lam '.dependencies.dependency | map(.artifactId)' pom.xml
```

Get a specific dependency version:

```bash
$ lam '.dependencies.dependency | filter(.groupId == "org.springframework") | map({artifactId, version})' pom.xml
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

## Next steps

- [Getting started](getting-started.md) for installation
- [Syntax reference](syntax.md) for the full language
- [REPL guide](repl.md) for interactive exploration
