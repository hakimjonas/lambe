# AGENTS.md

## Structured Data Queries

This project uses [Lambë](https://pub.dev/packages/lambe) (`lam`) for querying structured data files.

### CLI

```bash
# Extract values
lam '.database.host' config.toml
lam '.spec.containers[0].image' deployment.yaml

# Filter and transform
lam '.users | filter(.age > 30) | map(.name)' data.json

# Aggregate
lam '.items | map(.price) | sum' data.json

# Schema inspection
lam --schema data.json

# CI validation
lam --assert '.replicas >= 2' deployment.yaml

# Format conversion
lam --to yaml '.config' data.json
lam --to csv '.users | map({name, age})' data.json

# Query CSV/TSV
lam '. | filter(.status != "closed") | map(.title)' issues.csv

# Query XML
lam '.project.dependencies' pom.xml

# Query Terraform
lam '.resource | filter(._labels[0] == "aws_instance") | map(._labels[1])' main.tf

# Interactive REPL
lam -i data.json
```

### Supported Formats

Input: JSON, YAML, TOML, HCL/Terraform, XML, CSV, TSV (auto-detected from file extension).
Output: JSON (default), YAML, TOML, XML, CSV.

### As MCP Tool

The `lambe_query` MCP tool is available for querying structured data. Connect with:

```bash
lam-mcp  # stdio transport
```

Tools: `lambe_query` (extract/filter/transform), `lambe_schema` (structure inspection), `lambe_assert` (validation).

### In Dart Code

```dart
import 'package:lambe/lambe.dart';

final name = query('.users[0].name', data);
final active = queryString('.users | filter(.active)', jsonString);
```

### In Dart Tests

```dart
import 'package:lambe_test/lambe_test.dart';

expect(response, lamWhere('.errors | length == 0'));
expect(config, lamEquals('.database.port', 5432));
```

### Pipeline Operations

filter, map, sort, sort_by, group_by, unique, unique_by, flatten, reverse,
keys, values, length, first, last, sum, avg, min, max, has, to_entries,
from_entries, filter_values, map_values, filter_keys.
