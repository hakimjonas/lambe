# Lambë Design Document

**Package**: `lambe` | **CLI**: `lam` | **Repo**: `github.com/hakimjonas/lambe`

A query language for structured data: JSON, YAML, TOML, HCL, XML, CSV, TSV. Built on Rumil parser combinators with left-recursive grammar support via Warth seed-growth.

---

## Design philosophy

### Data transformations, not filters

Lambë uses the vocabulary of SQL, Spark DataFrames, and functional programming rather than Unix pipes.

| Concept | SQL | Spark DataFrame | jq | Lambë |
|---------|-----|-----------------|-----|-------|
| Filter rows | `WHERE age > 30` | `.filter(col("age") > 30)` | `select(.age > 30)` | `filter(.age > 30)` |
| Project | `SELECT name` | `.select("name")` | `.name` | `map(.name)` |
| Sort | `ORDER BY age` | `.orderBy("age")` | `sort_by(.age)` | `sort_by(.age)` |
| Group | `GROUP BY type` | `.groupBy("type")` | `group_by(.type)` | `group_by(.type)` |
| Aggregate | `SUM(price)` | `.agg(sum("price"))` | `map(.price) \| add` | `map(.price) \| sum` |

### Differences from jq

| Area | jq | Lambë |
|------|-----|-------|
| Naming | Implicit (everything is a filter) | Explicit (`filter`, `map`, `sort_by`) |
| group_by result | `[[items], [items]]` (no keys) | `[{key, values}]` (self-describing) |
| Object shorthand | None (`{name: .name}`) | `{name}` expands to `{name: .name}` |
| Map filtering | 3 steps (`to_entries \| select \| from_entries`) | 1 step (`filter_values`) |
| Conditionals | `if ... end` | `if ... else ...` (no `end`) |
| Error messages | Terse | Source-positioned via Rumil |
| Formats | JSON only | JSON, YAML, TOML, HCL, XML, CSV, TSV |

### Absence propagates, type errors throw

Rumil's parser returns `Result`, never throws. Lambë's evaluator follows the same principle for null/absence.

**Navigation returns null.** You can always safely explore a data structure:
```
.a          on {}           -> null  (absent)
.a.b        on {}           -> null  (absent propagates)
.a.b.c      on {a: {}}     -> null  (absent propagates)
.users[-1]  on {users: []}  -> null  (empty, not error)
. | length  on null         -> null  (length of nothing is nothing)
. | filter  on null         -> null  (filter nothing is nothing)
```

**Computation throws.** Using a missing value in a calculation is a type error:
```
.a + .b     on {a: 1}      -> THROWS (+ on null is a type error)
.a > 5      on {}           -> THROWS (comparison on null)
if null ...                 -> THROWS (condition must be bool)
```

Absence is data (Maybe/Option semantics). Type mismatch is an error.

---

## Surfaces

| Surface | Persona | How |
|---------|---------|-----|
| **CLI binary** | Platform engineers, DevOps | `dart compile exe` -> standalone `lam` binary |
| **Dart library** | Flutter/Dart developers | `import 'package:lambe/lambe.dart'` |
| **MCP tool** | AI agents, LLM frameworks | `lambe_query`, `lambe_schema`, `lambe_assert` |

---

## Why Dart?

1. **Left recursion.** Dart's parser libraries don't support left recursion or stack-safe deep recursion. Rumil adds that capability, and Lambë exercises it.

2. **dart2wasm.** Compiles to both AOT native and WasmGC from the same codebase.

3. **Library integration.** Flutter and Dart developers can use Lambë as a package directly: `query('.users | filter(.active)', response.body)`.
