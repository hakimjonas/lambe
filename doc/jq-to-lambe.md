# jq to Lambe

A side-by-side mapping of common jq patterns to their Lambe equivalents.

Lambe and jq have overlapping but distinct scopes. jq is the established
standard for JSON processing on the command line, with a long history and
features Lambe does not have (e.g. streaming, recursive descent, regex
filters, user-defined functions). Lambe covers more input formats by default
(YAML, TOML, HCL, CSV, TSV, Markdown) and leans on explicit SQL-like verbs
(`filter`, `map`, `sort_by`) rather than jq's terser generic filter model.
If you already know jq, most of it translates directly.

See [non-goals.md](non-goals.md) for the full list of deliberate
omissions and the lambé idiom that replaces each one.

All examples use this data:

```json
{
  "users": [
    {"name": "Alice", "age": 25, "active": true},
    {"name": "Bob", "age": 35, "active": false}
  ],
  "config": {"host": "localhost", "port": 5432}
}
```

## Field access

| jq | Lambe |
|----|-------|
| `.name` | `.name` |
| `.config.host` | `.config.host` |
| `.users[0].name` | `.users[0].name` |
| `.users[-1]` | `.users[-1]` |

Identical syntax for simple field access and indexing.

## Pipe

| jq | Lambe |
|----|-------|
| `.users \| length` | `.users \| length` |
| `.users \| .[0]` | `.users[0]` or `.users \| first` |

In jq, `.[0]` is how you index after a pipe. In Lambe, indexing chains directly: `.users[0]`. Or use `first` / `last` for the common cases.

## Filtering

| jq | Lambe |
|----|-------|
| `.users[] \| select(.age > 30)` | `.users \| filter(.age > 30)` |
| `[.users[] \| select(.active)]` | `.users \| filter(.active)` |
| `map(select(.age > 30))` | `.users \| filter(.age > 30)` |

jq uses `select` inside an iteration (`[]`). Lambe uses `filter` directly on a list. No `[]` iterator needed.

## Mapping

| jq | Lambe |
|----|-------|
| `.users \| map(.name)` | `.users \| map(.name)` |
| `[.users[] \| .name]` | `.users \| map(.name)` |
| `.users \| map(.age * 2)` | `.users \| map(.age * 2)` |

Same syntax when using jq's `map`. The `[.[] | expr]` pattern in jq is just `map(expr)` in Lambe.

## Sorting

| jq | Lambe |
|----|-------|
| `.users \| sort_by(.age)` | `.users \| sort_by(.age)` |
| `.tags \| sort` | `.tags \| sort` |
| `.users \| sort_by(.name) \| reverse` | `.users \| sort_by(.name) \| reverse` |

Identical.

## Grouping

| jq | Lambe |
|----|-------|
| `.users \| group_by(.active)` | `.users \| group_by(.active)` |

jq returns `[[group1], [group2]]`. Lambe returns `[{key: true, values: [...]}, {key: false, values: [...]}]`. The key is preserved, so you don't need to re-extract it.

## Aggregation

| jq | Lambe |
|----|-------|
| `.users \| map(.age) \| add` | `.users \| map(.age) \| sum` |
| `.users \| map(.age) \| add / length` | `.users \| map(.age) \| avg` |
| `.users \| map(.age) \| min` | `.users \| map(.age) \| min` |
| `.users \| map(.age) \| max` | `.users \| map(.age) \| max` |
| `.users \| length` | `.users \| length` |

jq uses `add` for sum and `add / length` for average. Lambe has `sum` and `avg` directly.

`add` is also accepted as a jq-compatibility alias for `sum` — both
parse, both produce the same AST, and `--explain` canonicalises to
`sum`. Use `sum` in new lambé queries; `add` exists so jq habits
don't fail on the parser.

## Type coercion

| jq | Lambe |
|----|-------|
| `"42" \| tonumber` | `"42" \| to_number` (or jq alias `tonumber`) |
| `"3.14" \| tonumber` | `"3.14" \| to_number` (or jq alias `tonumber`) |

`to_number` is lambé's canonical name; `tonumber` is accepted as a
jq-compatibility alias. Both parse, both throw `to_number: cannot
parse "..."` on a non-numeric string, and `--explain` canonicalises
to `to_number`.

## Object construction

| jq | Lambe |
|----|-------|
| `.users[0] \| {name: .name, age: .age}` | `.users[0] \| {name, age}` |
| `.users \| map({name: .name})` | `.users \| map({name})` |
| `{name: .users[0].name, count: (.users \| length)}` | not yet supported at top level |

Lambe has shorthand: `{name}` expands to `{name: .name}`. No need to repeat field names.

## Conditionals

| jq | Lambe |
|----|-------|
| `if .age > 65 then "senior" else "active" end` | `if .age > 65 then "senior" else "active"` |

No `end` keyword in Lambe.

## String interpolation

| jq | Lambe |
|----|-------|
| `"\(.name) is \(.age)"` | `"\(.name) is \(.age)"` |

Identical syntax.

## Existence check

| jq | Lambe |
|----|-------|
| `.config \| has("host")` | `.config \| has("host")` |
| `.config.missing // "default"` | `.config.missing // "default"` |

`has` is identical. `//` is the null-fallback operator: `expr // alt`
returns `alt` when `expr` evaluates to `null`. It is not an
error-handler — computation errors still propagate. For "the field
might not exist," `// default` is the idiom; for "this might fail,"
use shape checks (`has(...)`, `--print-shape`) before the call site.

## Entry conversion

| jq | Lambe |
|----|-------|
| `.config \| to_entries` | `.config \| to_entries` |
| `.config \| to_entries \| from_entries` | `.config \| to_entries \| from_entries` |

Identical.

## Unique and flatten

| jq | Lambe |
|----|-------|
| `[1,2,2,3] \| unique` | `. \| unique` |
| `.users \| unique_by(.active)` | `.users \| unique_by(.active)` |
| `[[1,2],[3]] \| flatten` | `. \| flatten` |

Identical.

## Format conversion

| jq | Lambe |
|----|-------|
| N/A | `lam --to yaml '.' data.json` |
| N/A | `lam --to csv '.users' data.json` |
| `@csv` | `lam --to csv` |

jq reads and outputs JSON, with `@csv`/`@tsv` filters for flat-record CSV/TSV output. Lambe reads JSON, YAML, TOML, HCL, CSV, TSV, and Markdown, and converts between output formats via `--to`. Different scopes.

## Schema inspection

| jq | Lambe |
|----|-------|
| `[paths \| join(".")]` | `lam --schema data.json` |

Lambe has `--schema`, which shows data structure without values. jq does not have a direct equivalent (the `paths` function can produce a list of paths, shown above).

## CI validation

| jq | Lambe |
|----|-------|
| `jq -e '.version != "0.0.0"' \|\| exit 1` | `lam --assert '.version != "0.0.0"' data.json` |

jq uses `-e` (exit status from expression). Lambe has `--assert` which exits 0 on true, 1 on false.

## Key differences summary

| Concept | jq | Lambe |
|---------|-----|-------|
| Filter | `select` inside `[]` or `map` | `filter` on list |
| Sum | `add` | `sum` |
| Average | `add / length` | `avg` |
| Object shorthand | `{name: .name}` | `{name}` |
| Conditional end | `end` required | no `end` |
| Format output | JSON, `@csv`, `@tsv` | JSON, YAML, TOML, HCL, CSV, TSV |
| Schema | `paths` function | `--schema` flag |
| CI validation | `-e` flag | `--assert` flag |
| Null on missing | yes | yes |
| Input formats | JSON | JSON, YAML, TOML, HCL, CSV, TSV, Markdown |
