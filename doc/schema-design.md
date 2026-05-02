# Lambe 0.9.0 Track A: Schema-typed queries — design document

Status: **approved**, ready for implementation.

## Context

0.9.0 completes the shape feedback loop: declare a shape, check queries
against it, round-trip with JSON Schema tooling. Tracks B/C/D landed
the per-feature polish; track A ships the piece that lets Lambe's
shape system act as a contract between the tool and its users' data.

The positioning is *"a query language for structured data that shows
you what you're working with."* Schemas are how a user tells Lambe
what they're working with when the data alone doesn't say enough
(empty lists, optional fields, heterogeneous sampling) — and how
Lambe tells the user, statically, whether their query makes sense
against that contract.

## Non-goals

- **No value-level constraints.** `minimum`, `maximum`, `pattern`,
  `enum`, `format`, `minLength`, `maxLength` are rejected at
  schema-load time with a one-line per-keyword error. Lambe is a
  query tool that understands shape, not a constraint system. Users
  who want value validation reach for ajv, check-jsonschema, or CUE.
- **No conditional schemas** (`if`/`then`/`else`, `dependencies`,
  `allOf`/`oneOf`/`anyOf`/`not`). These introduce a constraint solver
  and break the bounded-tree-transformer promise.
- **No external `$ref` resolution.** Schemas are single-file.
- **No runtime coercion.** A schema saying `age: number` does not
  cause CSV's `"30"` string to be parsed as a number at query time.
  The user still writes `.age | to_number`.
- **No pure-validation CLI command** (`lam --validate`). A user who
  wants to validate data against a schema can write
  `lam --schema s.json '.' data.yaml`. If data violates the schema,
  the load fails with a structural error. That's enough.

## Design decisions

### 1. Schema format: JSON Schema subset

Accept JSON files that describe a shape using four JSON Schema
keywords: `type`, `properties`, `items`, `required`.

**Chosen over a custom Lambe DSL because:**

- Ecosystem leverage. JSON Schema is what users already have —
  OpenAPI specs, pub.dev metadata, IDE validators, CI linters all
  emit or consume it. Zero authoring cost for users with an existing
  schema.
- `rumil_parsers.parseJson` does the parse for free, with typed
  errors and line/column locations. The "walk `JsonValue` → build
  `Shape`" layer is ~50 lines of exhaustive switch.
- JSON Schema as the ecosystem's lingua franca for structural
  description is a fact. A Lambe-specific DSL would be one more
  thing to learn with no reciprocal win.

**Accepted keywords and their mapping:**

| JSON Schema | Maps to |
|-------------|---------|
| `{"type": "null"}`                    | `SNull` |
| `{"type": "boolean"}`                 | `SBool` |
| `{"type": "number"}` or `"integer"`   | `SNum` |
| `{"type": "string"}`                  | `SString` |
| `{"type": "array", "items": S}`       | `SList(parse(S))` |
| `{"type": "object", "properties": P}` | `SMap({...})` with each property recursively parsed |
| `"required": [names]` on an object    | Non-listed properties become `SOptional` in the `SMap` |

**Rejected keywords** produce a clear per-keyword error pointing at
the source location:

- `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`
- `multipleOf`
- `minLength`, `maxLength`, `pattern`, `format`
- `minItems`, `maxItems`, `uniqueItems`, tuple-form `items`
- `minProperties`, `maxProperties`, `additionalProperties`,
  `patternProperties`, `propertyNames`
- `const`, `enum`
- `allOf`, `oneOf`, `anyOf`, `not`
- `if`/`then`/`else`, `dependencies`
- `$ref`, `$defs`, `definitions`, `$schema`, `$id`

**Unknown keywords** are ignored (JSON Schema's extensibility
convention). A schema with `"description"` or `"title"` is fine —
those are metadata that don't affect shape.

### 2. `SOptional(Shape)` variant

Adding a new sealed variant to `Shape`:

```dart
/// A value that may be absent. Used for JSON Schema properties not
/// listed in `required`, and for other cases where optionality is
/// statically known.
final class SOptional extends Shape {
  final Shape inner;
  const SOptional(this.inner);
  // == / hashCode / toString
}
```

**What this gives us:**

- JSON Schema's `required` semantics correctly map to the shape
  system. Schemas ship honestly or not at all.
- `--explain` can point out "this field is optional; `.age + 5` may
  throw at runtime on rows without `age`."
- `SMap` field shapes can carry `SOptional(...)` to represent
  "declared but optional."

**What this costs:**

- Every exhaustive `switch` on `Shape` gets a new case. The Dart
  compiler finds them all. Expected sites: `pipe_ops.dart` predicates,
  `inferShape`, `renderShape`, `shapeToJson`, `canWriteAs`
  requirements, `check.dart` hints.
- Op acceptance semantics: for a list pipe op (like `filter`), an
  `SOptional<SList<...>>` input means "might be a list, might not be."
  The op accepts (treating as the inner `SList`), but a
  runtime-rejection warning fires: "this may be absent; guard with a
  null check."

**What this preserves:**

- **Termination.** `SOptional` lives in the shape ADT, not the query
  language. Query evaluation semantics unchanged.
- **The bounded-language contract.** No new query operators.
- **The "narrow on purpose" scope.** The analyzer gets richer; the
  language surface is unchanged.

### 3. Disagreement semantics: schema augments data

When `--schema` is provided AND data is present, the initial shape
for `inferShape` is `mergeSchemaWithData(schemaShape, shapeOf(data))`.

Merge rules:

- Both agree on a concrete type: use that type.
- Schema has a field, data doesn't: use schema's shape.
- Data has a field, schema doesn't: use data's shape.
- Schema marks a field optional, data has it: field is present;
  outer `SOptional` wrapper is stripped at the merged point.
- Schema and data disagree on a concrete type at any path: **error
  at load time** with a diagnostic showing the path, expected, and
  actual.
- Empty-list element shapes always take the schema's element if one
  is declared. `shapeOf([])` = `SList(SAny)`, schema
  `list<string>` → result is `SList<SString>`.

**Rationale:** the value proposition of `--explain` is "what it
says is what will happen." A schema-wins policy would make
`--explain` lie whenever schema and data diverge. Error-on-conflict
keeps `--explain` honest. The merge preserves the case where schema
adds information (optionality, empty-list elements) without
overriding data.

**This gives structural validation as a side effect.** A user
running `lam --schema api.json '.' response.json` whose response
doesn't match the schema gets a load-time error naming the path and
types. No separate `--validate` mode needed.

### 4. CLI surface

**Rename `--schema` to `--print-shape`.** The existing `--schema`
flag prints the inferred shape of data; its semantics are really
"print the shape you'd infer." Renaming aligns the flag names with
their verbs.

```bash
# 0.8.0 (old)
lam --schema data.json                # prints the inferred shape

# 0.9.0 (new)
lam --print-shape data.json           # prints the inferred shape (as JSON Schema)
lam --schema spec.json data.json      # uses spec.json as the input schema
lam --schema spec.json 'query'        # schema-only (no data)
lam --schema spec.json --explain 'q'  # trace a query against the schema
```

**Auto-detection:** if `--schema` is not passed and a file named
`<datafile>.schema.json` exists next to the data file, use it
implicitly. Consistent with the `.ndjson` auto-detection shipped in
track C.

**`--print-shape` output is JSON Schema.** Round-trips with
`--schema` input:

```bash
lam --print-shape data.json > data.schema.json
# edit data.schema.json as needed
lam --schema data.schema.json query.lam data.json
```

This replaces the current type-name-string JSON output. **Breaking
change**, documented in CHANGELOG.

**REPL additions:**

- `:schema <path>` — load a schema for this session.
- `:schema` — show the active schema (if any).
- `:print-shape` — print the inferred shape of the currently loaded
  data, in JSON Schema form.

**JSON-Schema-looking reject:** if `--schema` is passed a file with
no recognized content (empty, random text, HTML, etc.), error with
a clear message. If it contains unsupported JSON Schema features,
error per feature. If it's valid JSON but not a schema (a bare
number, a plain object without `type`/`properties`), error with
"schema root must declare a shape (use `{\"type\": ...}`)."

### 5. MCP integration

The `lambe_query` tool gains an optional `schema` parameter: a JSON
string containing the schema. Threaded through like `flatten_cells`.

The `lambe_schema` MCP tool is renamed to `lambe_print_shape` for
consistency. Returns the shape as JSON Schema. (Agents that were
calling `lambe_schema` get a clear deprecation: tool not found,
suggest `lambe_print_shape`.)

New MCP tool: `lambe_check` — takes `schema` and `data`, returns
`{ok: true}` or `{ok: false, errors: [...]}`. This is structural
validation on demand, using the same `mergeSchemaWithData` logic.
Useful for agents verifying they have the right fixtures before
running queries.

### 6. Library surface

New module: `lib/src/schema/parser.dart`

```dart
/// Parse a JSON Schema subset into a [Shape].
///
/// Accepts a subset of JSON Schema: `type`, `properties`, `items`,
/// `required`. Rejects value-level constraints and structural
/// combinators; see doc/schema-design.md for the full list.
///
/// Throws [QueryError] with a line-aware diagnostic on parse error.
Shape parseJsonSchema(String source);
```

New module: `lib/src/schema/loader.dart`

```dart
/// Load a schema from a file path, auto-detecting siblings if
/// [explicitPath] is null.
Shape? loadSchema({String? explicitPath, String? dataPath});

/// Merge a schema shape with an observed data shape per the rules
/// in doc/schema-design.md section 3. Throws [QueryError] on concrete-
/// type disagreement.
Shape mergeSchemaWithData(Shape schema, Shape dataShape);

/// Render a [Shape] as a JSON Schema document.
///
/// Round-trips with [parseJsonSchema] — parsing the output of
/// `renderJsonSchema(s)` yields a shape equal to `s`.
String renderJsonSchema(Shape shape);
```

Library barrel exports: `parseJsonSchema`, `loadSchema`,
`mergeSchemaWithData`, `renderJsonSchema`, `SOptional`.

Existing APIs (`explain`, `inferShape`, `canWriteShapeAs`,
`renderExplain`, `renderExplainJson`, `shapeToJson`) are unchanged
in signature. `SOptional` propagates through them naturally via the
exhaustive-switch update.

### 7. Interaction with existing 0.9.0 features

- **ndjson**: `lam --ndjson --schema line.schema.json query file.ndjson`
  threads the schema as each line's initial shape. No new design.
- **`--flatten-cells json`**: schema-aware. Nested-list cells still
  refuse by default; `--flatten-cells json` still widens writer
  acceptance. Schema provides richer element shape for CSV writers.
- **`--explain-trivial`**: a schema-provided optional field accessed
  without a null guard still triggers the runtime-rejection warning
  even under `--explain-trivial`. Trivial-result detection benefits
  from schema: `sort_by(.missing)` becomes provably missing when the
  schema doesn't declare it.
- **Hints**: `mergeSchemaWithData` errors populate `hints` where a
  CLI flag would resolve the conflict. For 0.9.0, no such flags
  exist, so `hints` stays empty on schema errors.

### 8. Grammar of the accepted JSON Schema subset

```
schema := object_schema
        | array_schema
        | scalar_schema

scalar_schema := {"type": "null"}
               | {"type": "boolean"}
               | {"type": "number"}
               | {"type": "integer"}     # same as number, per lambe
               | {"type": "string"}

array_schema := {"type": "array", "items": <schema>}

object_schema := {"type": "object",
                  "properties": {<name>: <schema>, ...},
                  "required": [<name>, ...]?}
```

Keywords outside this grammar (but not in the explicit reject list)
are ignored as metadata. Reject-list violations are errors.

## Implementation plan

~1 week. Order:

1. **`SOptional` variant.** Add to `shape.dart`. Run the analyzer;
   fix every exhaustive-switch compile error. Each fix is local:
   - `renderShape`: `optional<inner>`.
   - `shapeToJson`: `{"kind": "optional", "inner": ...}`.
   - `canWriteAs` requirements: optional unwraps to inner for
     writability purposes, except for TOML/HCL where "optional at
     root" is unwritable.
   - `inferShape`: field access on `SMap` with optional field yields
     `SOptional<inner>`. Subsequent ops propagate or strip as
     appropriate.
   - `pipe_ops.dart` predicates: optional is accepted wherever
     inner is, but a runtime-rejection warning is emitted.
2. **Parser** (`lib/src/schema/parser.dart`): walk `JsonValue`,
   recursive. Line-aware errors via `rumil_parsers.parseJson` error
   positions.
3. **Loader + merge** (`lib/src/schema/loader.dart`): file reader,
   sibling auto-detect, `mergeSchemaWithData` with diagnostic errors.
4. **Renderer** (`lib/src/schema/render.dart` or inline): shape →
   JSON Schema. Used by `--print-shape`.
5. **CLI** (`bin/lam.dart`): rename flag, add option, thread
   through explain and evaluation paths.
6. **REPL** (`lib/src/repl.dart`): `:schema`, `:print-shape`.
7. **MCP** (`bin/mcp_server.dart`): `schema` param, `lambe_check`
   tool, `lambe_schema` → `lambe_print_shape` rename.
8. **Tests**:
   - `test/schema_parser_test.dart`: every shape constructor,
     `required` semantics, unknown-keyword tolerance, rejected-
     keyword errors, round-trip with `renderJsonSchema`.
   - `test/schema_loader_test.dart`: sibling auto-detect, merge
     rules, disagreement errors, validation-as-side-effect.
   - Extend `test/cli_integration_test.dart`: `--schema`,
     `--print-shape`, rename rejection error.
   - Extend `test/shape_explain_test.dart`: schema-seeded explain
     reports.
9. **Docs**:
   - `doc/schema.md`: user-facing guide with examples.
   - `doc/lam.1.md`: `--schema`, `--print-shape`.
   - `CHANGELOG.md`: Added bullets + Breaking callout for rename.
   - `README.md`: reframe to the shape-feedback-loop pitch (held
     until all tracks land).

## Open decisions

- **MCP tool rename `lambe_schema` → `lambe_print_shape`.** Strictly
  speaking, backward-compatible would keep the old name. Renaming
  aligns with the CLI rename. Lean: rename. Any agent with the old
  name gets a clear "tool not found" and can update.

- **Auto-detect behavior when both `--schema <path>` and a sibling
  `.schema.json` exist.** Explicit wins.

These are resolved; calling them out for the record.
