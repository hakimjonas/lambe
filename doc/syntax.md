# Syntax Reference

The complete Lambë query language. Every feature, with input and output examples.

All examples use this data unless stated otherwise. Save it as `data.json`:

```json
{
  "users": [
    {"name": "Alice", "age": 25, "active": true},
    {"name": "Bob", "age": 35, "active": false},
    {"name": "Carol", "age": 42, "active": true}
  ],
  "config": {
    "database": {"host": "localhost", "port": 5432},
    "debug": false
  },
  "version": "1.0.0",
  "tags": ["api", "v1", "stable"]
}
```

Examples that don't reference input data use `lam -n` (null input).

## Data model

Lambë operates on JSON-compatible values: maps (objects), lists (arrays), strings, numbers, booleans, and null.

All input formats (YAML, TOML, HCL, CSV, TSV, Markdown) are converted to this model before querying. CSV rows with headers become a list of maps.

## Identity

`.` returns the current value unchanged.

```bash
$ lam '.' data.json
# (the entire document, pretty-printed)
```

## Field access

`.field` accesses a named field on a map.

```bash
$ lam '.version' data.json
"1.0.0"

$ lam '.config.database.host' data.json
"localhost"
```

Accessing a field that doesn't exist returns `null`:

```bash
$ lam '.missing' data.json
null

$ lam '.missing.nested' data.json
null
```

## Indexing

`[n]` indexes into a list. Zero-based. Negative indices count from the end.

```bash
$ lam '.users[0]' data.json
{
  "name": "Alice",
  "age": 25,
  "active": true
}

$ lam '.users[-1].name' data.json
"Carol"

$ lam '.tags[1]' data.json
"v1"
```

Out-of-bounds returns `null`:

```bash
$ lam '.users[99]' data.json
null
```

## Slicing

`[start:end]` extracts a sub-list. Start is inclusive, end is exclusive.

```bash
$ lam '.tags[0:2]' data.json
[
  "api",
  "v1"
]

$ lam '.tags[:2]' data.json
[
  "api",
  "v1"
]

$ lam '.tags[1:]' data.json
[
  "v1",
  "stable"
]

$ lam '.tags[:-1]' data.json
[
  "api",
  "v1"
]
```

Slicing works on strings too:

```bash
$ lam '.version[0:1]' data.json
"1"
```

## Arithmetic

`+`, `-`, `*`, `/`, `%` on numbers.

```bash
$ lam '.users[0].age + 10' data.json
35

$ lam '.users[0].age * 2' data.json
50

$ lam '.config.database.port % 100' data.json
32.0
```

Using arithmetic on null throws an error:

```bash
$ lam '.missing + 5' data.json
Error: +: expected number, got null
```

## Comparison

`<`, `>`, `<=`, `>=` compare numbers. `==`, `!=` compare any type with deep equality.

```bash
$ lam '.users[0].age > 30' data.json
false

$ lam '.version == "1.0.0"' data.json
true

$ lam '.config.debug != true' data.json
true
```

Comparing null throws (except for `==` and `!=`):

```bash
$ lam '.missing > 5' data.json
Error: >: expected number, got null

$ lam '.missing == null' data.json
true
```

## Boolean logic

`&&`, `||`, `!` with short-circuit evaluation.

```bash
$ lam '.users[0].active && .users[0].age < 30' data.json
true

$ lam '!.config.debug' data.json
true
```

## String literals

Double-quoted. Supports `\"`, `\\`, `\n`, `\t`.

```bash
$ lam '.users | filter(.name == "Alice") | length' data.json
1
```

## String interpolation

`\(expr)` inside a string evaluates the expression and inserts the result.

```bash
$ lam '.users | map("\(.name) is \(.age)")' data.json
[
  "Alice is 25",
  "Bob is 35",
  "Carol is 42"
]
```

## Object construction

Build new maps from the current context. `{name}` expands to `{name: .name}`.

```bash
$ lam '.users[0] | {name, age}' data.json
{
  "name": "Alice",
  "age": 25
}

$ lam '.users | map({name, senior: .age > 40})' data.json
[
  {
    "name": "Alice",
    "senior": false
  },
  {
    "name": "Bob",
    "senior": false
  },
  {
    "name": "Carol",
    "senior": true
  }
]
```

Keys that are valid identifiers use the bare form (`name:`); keys that
are not (hyphenated, spaces, leading digits) use a JSON-string literal
in key position. Both spellings produce identical maps.

```bash
$ lam '{"x-axis": .config.database.port, "y-axis": .users[0].age}' data.json
{
  "x-axis": 5432,
  "y-axis": 25
}

$ lam '{name: .users[0].name, "Content-Type": "application/json"}' data.json
{
  "name": "Alice",
  "Content-Type": "application/json"
}
```

Interpolation (`"\(expr)"`) is not allowed in key position — build
dynamic keys via `from_entries` on a list of `{key, value}` maps. The
shorthand form `{name}` only applies to bare identifiers; `{"name"}`
on its own is not supported.

## Conditionals

`if condition then value else value`. The condition must evaluate to a boolean.

```bash
$ lam '.users | map(if .age > 40 then "senior" else "junior")' data.json
[
  "junior",
  "junior",
  "senior"
]
```

## Pipelines

`|` passes the left side's result into the right side's operation.

```bash
$ lam '.users | filter(.active) | sort_by(.age) | map(.name)' data.json
[
  "Alice",
  "Carol"
]
```

Pipelines bind tighter than binary operators:

```bash
$ lam '.tags | length > 0' data.json
true
```

This parses as `(.tags | length) > 0`, not `.tags | (length > 0)`.

## Pipeline operations

### filter(predicate)

Keep elements where the predicate is true.

```bash
$ lam '.users | filter(.age > 30)' data.json
[
  {
    "name": "Bob",
    "age": 35,
    "active": false
  },
  {
    "name": "Carol",
    "age": 42,
    "active": true
  }
]

$ lam '.users | filter(.active && .age < 40)' data.json
[
  {
    "name": "Alice",
    "age": 25,
    "active": true
  }
]
```

### map(expression)

Transform each element.

```bash
$ lam '.users | map(.name)' data.json
[
  "Alice",
  "Bob",
  "Carol"
]

$ lam '.users | map(.age * 2)' data.json
[
  50,
  70,
  84
]
```

### sort

Sort elements by natural order.

```bash
$ lam '.tags | sort' data.json
[
  "api",
  "stable",
  "v1"
]
```

### sort_by(key)

Sort elements by a key expression.

```bash
$ lam '.users | sort_by(.age) | map(.name)' data.json
[
  "Alice",
  "Bob",
  "Carol"
]
```

### group_by(key)

Group elements by a key. Returns `[{key, values}]`.

```bash
$ lam '.users | group_by(.active)' data.json
[
  {
    "key": true,
    "values": [
      {
        "name": "Alice",
        "age": 25,
        "active": true
      },
      {
        "name": "Carol",
        "age": 42,
        "active": true
      }
    ]
  },
  {
    "key": false,
    "values": [
      {
        "name": "Bob",
        "age": 35,
        "active": false
      }
    ]
  }
]
```

### unique

Remove duplicate values.

```bash
$ lam -n '[1, 2, 2, 3, 1] | unique'
[
  1,
  2,
  3
]
```

### unique_by(key)

Remove duplicates by a key expression.

```bash
$ lam '.users | unique_by(.active) | map(.name)' data.json
[
  "Alice",
  "Bob"
]
```

### flatten

Flatten one level of nesting.

```bash
$ lam -n '[[1, 2], [3, 4], [5]] | flatten'
[
  1,
  2,
  3,
  4,
  5
]
```

### reverse

Reverse the order.

```bash
$ lam '.tags | reverse' data.json
[
  "stable",
  "v1",
  "api"
]
```

### keys

Map keys or list indices.

```bash
$ lam '.config | keys' data.json
[
  "database",
  "debug"
]

$ lam '.tags | keys' data.json
[
  0,
  1,
  2
]
```

### values

Map values (identity for lists).

```bash
$ lam '.config.database | values' data.json
[
  "localhost",
  5432
]
```

### length

Length of a list, map, or string.

```bash
$ lam '.users | length' data.json
3

$ lam '.version | length' data.json
5
```

### first, last

First or last element of a list.

```bash
$ lam '.users | first | .name' data.json
"Alice"

$ lam '.tags | last' data.json
"stable"
```

### sum, avg, min, max

Aggregate operations on numeric lists. `add` is accepted as a
jq-compatibility alias for `sum`; `--explain` canonicalises to `sum`.

```bash
$ lam '.users | map(.age) | sum' data.json
102

$ lam '.users | map(.age) | avg' data.json
34.0

$ lam '.users | map(.age) | min' data.json
25

$ lam '.users | map(.age) | max' data.json
42
```

### has(key)

Check if a map contains a key.

```bash
$ lam '.config | has("database")' data.json
true

$ lam '.config | has("missing")' data.json
false
```

### to_entries, from_entries

Convert between maps and `[{key, value}]` lists.

```bash
$ lam '.config.database | to_entries' data.json
[
  {
    "key": "host",
    "value": "localhost"
  },
  {
    "key": "port",
    "value": 5432
  }
]

$ lam -n '[{key: "a", value: 1}] | from_entries'
{
  "a": 1
}
```

### to_number

Parse a string as a number. Pass-through for existing numbers.

CSV and TSV cells are strings by default; use `to_number` to coerce them
before arithmetic.

`tonumber` is accepted as a jq-compatibility alias — both names parse
identically and `--explain` canonicalises to `to_number`. Use
`to_number` in new lambé queries.

```bash
$ lam -n '"42" | to_number'
42

$ lam -n '"3.14" | to_number'
3.14

$ lam -n '100 | to_number'
100

$ echo '{"price": "29.99"}' | lam '.price | to_number'
29.99
```

Throws on strings that do not parse, and on inputs that are not strings
or numbers.

### type

Return the runtime type of the input as a string.

Possible return values: `"null"`, `"boolean"`, `"number"`, `"string"`,
`"array"`, `"object"`.

```bash
$ lam -n '42 | type'
"number"

$ lam -n '"hello" | type'
"string"

$ lam -n 'null | type'
"null"

$ lam -n '[1, 2] | type'
"array"

$ lam -n '{a: 1} | type'
"object"

$ lam -n '[1, "two", 3] | filter((. | type) == "number")'
[
  1,
  3
]
```

### filter_values(predicate)

Filter a map's values.

```bash
$ lam '.config.database | filter_values(. == "localhost")' data.json
{
  "host": "localhost"
}
```

### map_values(expression)

Transform a map's values.

```bash
$ lam -n '{a: 1, b: 2} | map_values(. * 10)'
{
  "a": 10,
  "b": 20
}
```

### filter_keys(predicate)

Filter a map's keys.

```bash
$ lam '.config | filter_keys(. != "debug")' data.json
{
  "database": {
    "host": "localhost",
    "port": 5432
  }
}
```

### text

Markdown-only. Walks a node or list of nodes and concatenates every
prose-bearing leaf — `text`, `code`, `code_block`, and `image.alt` — in
document order. Container nodes recurse through their `children`.
`html_block` and `html_inline` are skipped (a deliberate divergence
from mdast: raw HTML in "give me the text" is the same trap that drags
`<script>` content into `Node.textContent`). `hard_break` and
`soft_break` contribute the empty string. Maps without a recognised
`type` yield the empty string; non-map non-list inputs throw.

The only pipe op tuned to a specific input format. It exists because
`.children[0].text` is structurally wrong for non-trivial markdown
(nested emphasis, links, code) and "compose with explicit paths" cannot
fix that without recursion.

```bash
$ echo '# Hello' | lam -f markdown '.children[0] | text'
"Hello"

$ echo -e '# First\n\n# Second' | lam -f markdown '.children | filter(.type == "heading") | map(text)'
[
  "First",
  "Second"
]
```

## Null propagation

Navigation on null returns null. Computation on null throws.

**Returns null** (absence is data):

```bash
$ lam '.missing' data.json
null

$ lam '.missing.nested' data.json
null

$ lam '.users[99]' data.json
null

$ lam -n 'null | length'
null

$ lam -n 'null | filter(.x)'
null
```

**Throws** (type mismatch is an error):

```bash
$ lam -n 'null + 5'
Error: +: expected number, got null

$ lam -n 'null > 3'
Error: >: expected number, got null

$ lam -n 'if null then 1 else 2'
Error: if: expected boolean, got null
```

## Operator precedence

From lowest to highest:

1. `||`
2. `&&`
3. `==`, `!=`
4. `<`, `>`, `<=`, `>=`
5. `+`, `-`
6. `*`, `/`, `%`
7. Unary `-`, `!`
8. Postfix: `| op`, `.field`, `[index]`

Parentheses override precedence: `(.age + 1) * 2`.

## Next steps

- [Getting started](getting-started.md) if you haven't installed yet
- [REPL guide](repl.md) for interactive exploration
- [Recipes](recipes.md) for real-world patterns
