# Lambe schemas

Lambe supports a JSON Schema subset as the contract between a query and its data. Declare the shape once; let Lambe check that queries make sense against it, validate data conforms at runtime, and round-trip schemas with the rest of the ecosystem.

## Why use a schema?

Lambe's default inference samples the data at hand. That's robust for known inputs but has gaps:

- **Empty lists and maps.** `shapeOf([])` returns `list<any>`; the element type is lost.
- **Mixed sampling.** Lists with heterogeneity beyond the sampling window collapse to `list<any>`.
- **Queries without data.** CI planning, design documents, `--explain` without a file — no data to sample, no precision.

A schema fills those in. `--explain` shows a sharper trace, errors fire earlier, and you can validate data against the shape before running anything.

## Accepted JSON Schema subset

Four keywords. That's it.

| Keyword | Meaning |
|---|---|
| `type` | `"null"`, `"boolean"`, `"number"`, `"integer"`, `"string"`, `"array"`, `"object"` |
| `properties` | Map of field name → nested schema (for `object`) |
| `items` | Element schema (for `array`) |
| `required` | List of required property names (for `object`) |

The empty object `{}` means "any shape" — JSON Schema's convention, preserved through round-trip.

Unknown keywords are ignored (JSON Schema's extensibility rule), so `$schema`, `$id`, `title`, `description`, and other metadata flow through without complaint.

## Rejected keywords

Everything else is rejected with a per-keyword error and a JSON path:

- **Value-level constraints** (`minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `enum`, `const`, `format`, `multipleOf`, `minItems`, `maxItems`, `uniqueItems`, `minProperties`, `maxProperties`). Lambe is a shape system, not a value validator.
- **Structural combinators** (`allOf`, `oneOf`, `anyOf`, `not`). The shape ADT is union-free by design.
- **Conditionals** (`if`, `then`, `else`, `dependencies`, `dependentRequired`, `dependentSchemas`). Would require a constraint solver.
- **References** (`$ref`, `$defs`, `definitions`). Schemas are single-file in 0.9.
- **Object constraints** (`additionalProperties`, `patternProperties`, `propertyNames`).

If you have a richer schema, strip it down or run it through `ajv`/`check-jsonschema` for value validation separately.

## Example schemas

Simple:

```json
{"type": "string"}
```

List of strings:

```json
{"type": "array", "items": {"type": "string"}}
```

Object with required and optional fields:

```json
{
  "type": "object",
  "properties": {
    "name": {"type": "string"},
    "age": {"type": "number"},
    "email": {"type": "string"}
  },
  "required": ["name", "age"]
}
```

In Lambe's shape language, that last one is `map<name: string, age: number, email: optional<string>>`.

## How Lambe uses your schema

### CLI

```bash
# Thread schema into --explain: shape trace reflects declared optionality
lam --schema api.schema.json --explain '.users | map(.email)' response.json

# With data: schema validates at load time. Disagreement exits 1.
lam --schema api.schema.json '.users' response.json

# Without data: schema alone is the initial shape (design-time planning)
lam --schema api.schema.json --explain '.users | map(.email)'
```

### Sibling auto-detect

If you have `data.json` and `data.schema.json` side-by-side, `lam` picks up the schema implicitly:

```bash
lam '.users' data.json   # data.schema.json used automatically if present
```

Same convention as `.ndjson` auto-detect. An explicit `--schema <path>` overrides the sibling.

### REPL

```
lambe> :schema api.schema.json
Schema loaded (agrees with current data).
lambe> :schema
{...prints the loaded schema as JSON Schema...}
lambe> :load other-data.json
Warning: data disagrees with active schema: schema disagreement at $.users: ...
lambe> :print-shape
{...prints the inferred shape of currently loaded data...}
```

### MCP

Three tools cover the schema story for agents:

- `lambe_print_shape` — takes data, returns its JSON Schema.
- `lambe_check` — takes schema + data, returns `{"ok": true}` or `{"ok": false, "error": "..."}`.
- `lambe_query` — takes an optional `schema` parameter that validates data before running the query.
- `lambe_explain` — takes an optional `schema` parameter; the explain trace reflects it.

### Library

```dart
import 'package:lambe/lambe.dart';

// Parse a schema string
final schema = parseJsonSchema(schemaText);

// Load from a file (throws QueryError on missing/invalid)
final schema2 = loadSchemaFromFile('api.schema.json');

// Merge with observed data (throws on disagreement)
final merged = mergeSchemaWithData(schema, shapeOf(data));

// Emit a schema from a shape
final schemaText2 = renderJsonSchema(shape);
```

## Disagreement semantics

When schema and data are both present, Lambe merges them:

- **Both agree on a concrete type.** Use that type.
- **Schema has a field data doesn't.** Use the schema's shape for that field.
- **Data has a field schema doesn't.** Use data's shape.
- **Schema marks a field optional, data has it present.** Strip the `optional` wrapper for this run.
- **Concrete-type disagreement** (schema: `number`, data: `string`). Error at load time with a JSON path.

The error path is designed to be actionable:

```
Error: schema disagreement at $.users[*].age: schema says number, data is string
```

Merge is the heart of why schemas matter: `--explain` stays honest (what it says is what will happen, because data and schema agree), and validation falls out as a side effect of loading.

## Round-trip

```bash
lam --print-shape data.json > data.schema.json   # Shape -> JSON Schema
lam --schema data.schema.json '.' data.json      # JSON Schema -> Shape
```

Round-trip invariant: `parseJsonSchema(renderJsonSchema(shape))` equals `shape` for every shape reachable through `parseJsonSchema`. Pinned by 12 representative cases in `test/schema_renderer_test.dart`.

Lossy corner: `SOptional` inside a list's `items` or at the top level has no standard JSON Schema spelling in our subset. The renderer flattens those positions. `SOptional` inside an `SMap` field — the common case — round-trips faithfully via `required`.

## What schemas don't do

- **No value coercion.** Schema says `age: number`, data has `"30"`. Lambe does not parse the string at query time. The user still writes `.age | to_number`. A future release may add opt-in coercion.
- **No runtime constraints.** Schema saying `age` is `number` does not enforce `age >= 0` or `age <= 150` at query time. Value-level constraints are rejected from the schema at load time.
- **No schema composition.** `$ref` is rejected. For cross-file schemas, merge them yourself before pointing `--schema` at the result.
- **No runtime validation after load.** A CSV column with mixed strings and numbers won't surface at per-row granularity; we check the aggregate shape, not every value.

## `shapeOf` vs schema

Different tools for different jobs:

| | `shapeOf(data)` | Schema |
|---|---|---|
| Source of truth | This particular dataset | The contract |
| Sees empty lists as | `list<any>` | Declared element type |
| Handles mixed lists | Collapses to `list<any>` | Declared element type |
| Available when data is absent | No | Yes |
| Sees optionality | No | Via `required` |
| Validates | N/A | Yes (at load time) |

Use both when you can — `mergeSchemaWithData` is the merge function designed for this. Schema augments; data fills in extras; disagreement errors.
