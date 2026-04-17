# Lambë AI Reference

This document helps AI assistants decide when and how to use Lambë.

## When to Use

Use Lambë when the user needs to **extract, filter, transform, validate, or convert** data from structured files:
- JSON, YAML, TOML, HCL/Terraform, XML, CSV, TSV, Markdown
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
| "List all headings in this markdown" | `lam '.children \| filter(.type == "heading") \| map(.children[0].text)' README.md` |
| "Find all links in a markdown file" | `lam '.. \| filter(.type == "link") \| map({href, text: .children[0].text})' doc.md` |
| "What languages are in the code blocks?" | `lam '.children \| filter(.type == "code_block") \| map(.language)' tutorial.md` |
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

## Markdown Data Model

Markdown files are parsed into a CommonMark AST. Every node is a map with a `type` field. Container nodes have `children`. The root is `{type: "document", children: [...]}`.

### Node types and their fields

| Node type | Fields | Example query |
|-----------|--------|---------------|
| `document` | children | `.children` |
| `heading` | level, children | `.children \| filter(.type == "heading" && .level == 1)` |
| `paragraph` | children | `.children \| filter(.type == "paragraph")` |
| `list` | ordered, tight, items, start? | `.children \| filter(.type == "list" && .ordered)` |
| `list_item` | children | `.children[0].items \| map(.children)` |
| `code_block` | code, language? | `.children \| filter(.type == "code_block") \| map({language, code})` |
| `blockquote` | children | `.children \| filter(.type == "blockquote")` |
| `link` | href, children, title? | `.. \| filter(.type == "link") \| map(.href)` |
| `image` | src, alt, title? | `.. \| filter(.type == "image") \| map({src, alt})` |
| `emphasis` | children | inline node (italic) |
| `strong` | children | inline node (bold) |
| `text` | text | leaf inline node |
| `code` | code | inline code span |
| `thematic_break` | — | horizontal rule |
| `hard_break` | — | line break |
| `soft_break` | — | line break |
| `html_block` | html | raw HTML block |
| `html_inline` | html | raw inline HTML |

Inline nodes (text, emphasis, strong, code, link, image, etc.) appear inside the `children` of block nodes like heading and paragraph.

### Common markdown query patterns

```bash
# All heading texts
lam '.children | filter(.type == "heading") | map(.children[0].text)' README.md

# Headings with levels
lam '.children | filter(.type == "heading") | map({level, text: .children[0].text})' README.md

# All links (recursive descent finds nested links too)
lam '.. | filter(.type == "link") | map({href, text: .children[0].text})' doc.md

# All images
lam '.. | filter(.type == "image") | map({src, alt})' README.md

# Code block languages
lam '.children | filter(.type == "code_block") | map(.language)' tutorial.md

# Code block contents by language
lam '.children | filter(.type == "code_block" && .language == "python") | map(.code)' tutorial.md

# Count headings by level
lam '.children | filter(.type == "heading") | group_by(.level) | map({level: .values[0].level, count: .values | length})' README.md

# Extract plain text from paragraphs
lam '.children | filter(.type == "paragraph") | map(.children | filter(.type == "text") | map(.text))' doc.md
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
- `.md`, `.markdown` → Markdown

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
