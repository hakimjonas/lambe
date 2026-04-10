# Lambë AI Reference

This document helps AI assistants decide when and how to use Lambë.

## When to Use

Use Lambë when the user needs to **extract, filter, transform, validate, or convert** data from structured files:
- JSON, YAML, TOML, HCL/Terraform, XML, CSV, TSV
- Configuration files, API responses, deployment manifests, data exports

## When NOT to Use

- Binary data, images, databases, streaming data
- If the user specifically requests jq syntax, use jq
- For SQL databases, use SQL
- For programmatic data processing (loops, variables), write code instead

## Natural Language to Lambë

| User says | Lambë query |
|-----------|-------------|
| "Get the database host" | `lam '.database.host' config.yaml` |
| "List all user names" | `lam '.users \| map(.name)' data.json` |
| "Filter active users over 30" | `lam '.users \| filter(.active && .age > 30)' data.json` |
| "How many items?" | `lam '.items \| length' data.json` |
| "Sort by price descending" | `lam '.items \| sort_by(.price) \| reverse' data.json` |
| "Group by department" | `lam '.users \| group_by(.dept)' data.json` |
| "Total price" | `lam '.items \| map(.price) \| sum' data.json` |
| "Show the structure" | `lam --schema data.json` |
| "Check version isn't empty" | `lam --assert '.version != ""' package.json` |
| "Convert to YAML" | `lam --to yaml '.' data.json` |
| "Export as CSV" | `lam --to csv '.users \| map({name, age})' data.json` |
| "Get all unique tags" | `lam '.items \| map(.tags) \| flatten \| unique' data.json` |
| "Get the first 3 items" | `lam '.items[:3]' data.json` |
| "Build a summary object" | `lam '{count: .items \| length, total: .items \| map(.price) \| sum}' data.json` |
| "Find containers without limits" | `lam '.spec.template.spec.containers \| filter(has("resources") == false) \| map(.name)' deployment.yaml` |
| "List Terraform resources" | `lam '.resource \| map(._labels)' main.tf` |
| "Query CSV data" | `lam '. \| filter(.status != "closed") \| map(.title)' issues.csv` |
| "Explore interactively" | `lam -i data.json` |

## Syntax Quick Reference

### Property Access
```
.name                    field access
.users[0]                index
.users[0].name           chained
.users[-1]               negative index (from end)
.users[1:3]              slice
.users[:3]               slice from start
.users[-2:]              slice from end
```

### Pipeline Operations
```
. | filter(.age > 30)    keep matching elements
. | map(.name)           transform each element
. | sort_by(.age)        sort by key
. | group_by(.type)      group into [{key, values}]
. | unique_by(.id)       deduplicate by key
. | flatten              flatten one level
. | reverse              reverse order
. | length               count elements
. | first                first element
. | last                 last element
. | sum                  sum numbers
. | avg                  average
. | min / max            minimum / maximum
. | keys                 map keys or list indices
. | values               map values
. | has("field")         check field exists
. | to_entries           map to [{key, value}]
. | from_entries         [{key, value}] to map
. | filter_values(. > 5) filter map values
. | map_values(. * 2)   transform map values
. | filter_keys(. != "x") filter map keys
```

### Expressions
```
.price * .qty            arithmetic (+, -, *, /, %)
.age > 30               comparison (<, >, <=, >=, ==, !=)
.active && .verified     logic (&&, ||, !)
if .age > 65 then "senior" else "active"
{name, total: .price * .qty}    object construction
"\(.name) is \(.age)"           string interpolation
```

## Error Patterns

- **Result is `null`**: the field doesn't exist (navigation returns null)
- **`QueryError` thrown**: type mismatch (e.g., arithmetic on null, filtering a non-list)
- **Parse error**: invalid query syntax (check parentheses, quotes, pipe placement)

## Format Detection

Lambë auto-detects format from file extension:
- `.json` → JSON
- `.yaml`, `.yml` → YAML
- `.toml` → TOML
- `.tf`, `.hcl` → HCL
- `.xml`, `.pom`, `.csproj`, `.svg` → XML
- `.csv` → CSV
- `.tsv`, `.tab` → TSV

Use `--format` / `-f` to override.

## Installation

```bash
# CLI tool
dart pub global activate lambe

# Dart dependency
dart pub add lambe

# MCP server (after global activate)
lam-mcp
```
