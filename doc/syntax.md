# Syntax Reference

The complete Lambë query language. Every feature, with input and output examples.

All examples use this data unless stated otherwise:

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

## Data model

Lambë operates on JSON-compatible values: maps (objects), lists (arrays), strings, numbers, booleans, and null.

All input formats (YAML, TOML, HCL, XML, CSV) are converted to this model before querying. CSV rows with headers become a list of maps.

## Identity

`.` returns the current value unchanged.

```
.
-> (the entire document)
```

## Field access

`.field` accesses a named field on a map.

```
.version
-> "1.0.0"

.config.database.host
-> "localhost"
```

Accessing a field that doesn't exist returns `null`:

```
.missing
-> null

.missing.nested
-> null
```

## Indexing

`[n]` indexes into a list. Zero-based. Negative indices count from the end.

```
.users[0]
-> {"name": "Alice", "age": 25, "active": true}

.users[-1].name
-> "Carol"

.tags[1]
-> "v1"
```

Out-of-bounds returns `null`:

```
.users[99]
-> null
```

## Slicing

`[start:end]` extracts a sub-list. Start is inclusive, end is exclusive.

```
.tags[0:2]
-> ["api", "v1"]

.tags[:2]
-> ["api", "v1"]

.tags[1:]
-> ["v1", "stable"]

.tags[:-1]
-> ["api", "v1"]
```

Slicing works on strings too:

```
.version[0:1]
-> "1"
```

## Arithmetic

`+`, `-`, `*`, `/`, `%` on numbers.

```
.users[0].age + 10
-> 35

.users[0].age * 2
-> 50

.config.database.port % 100
-> 32
```

Using arithmetic on null throws an error:

```
.missing + 5
-> Error: +: expected number, got null
```

## Comparison

`<`, `>`, `<=`, `>=` compare numbers. `==`, `!=` compare any type with deep equality.

```
.users[0].age > 30
-> false

.version == "1.0.0"
-> true

.config.debug != true
-> true
```

Comparing null throws (except for `==` and `!=`):

```
.missing > 5
-> Error: >: expected number, got null

.missing == null
-> true
```

## Boolean logic

`&&`, `||`, `!` with short-circuit evaluation.

```
.users[0].active && .users[0].age < 30
-> true

!.config.debug
-> true
```

## String literals

Double-quoted. Supports `\"`, `\\`, `\n`, `\t`.

```
.users | filter(.name == "Alice") | length
-> 1
```

## String interpolation

`\(expr)` inside a string evaluates the expression and inserts the result.

```
.users | map("\(.name) is \(.age)")
-> ["Alice is 25", "Bob is 35", "Carol is 42"]
```

## Object construction

Build new maps from the current context. `{name}` expands to `{name: .name}`.

```
.users[0] | {name, age}
-> {"name": "Alice", "age": 25}

.users | map({name, senior: .age > 40})
-> [
     {"name": "Alice", "senior": false},
     {"name": "Bob", "senior": false},
     {"name": "Carol", "senior": true}
   ]
```

## Conditionals

`if condition then value else value`. The condition must evaluate to a boolean.

```
.users | map(if .age > 40 then "senior" else "junior")
-> ["junior", "junior", "senior"]
```

## Pipelines

`|` passes the left side's result into the right side's operation.

```
.users | filter(.active) | sort_by(.age) | map(.name)
-> ["Alice", "Carol"]
```

Pipelines bind tighter than binary operators:

```
.tags | length > 0
-> true
```

This parses as `(.tags | length) > 0`, not `.tags | (length > 0)`.

## Pipeline operations

### filter(predicate)

Keep elements where the predicate is true.

```
.users | filter(.age > 30)
-> [{"name": "Bob", ...}, {"name": "Carol", ...}]

.users | filter(.active && .age < 40)
-> [{"name": "Alice", "age": 25, "active": true}]
```

### map(expression)

Transform each element.

```
.users | map(.name)
-> ["Alice", "Bob", "Carol"]

.users | map(.age * 2)
-> [50, 70, 84]
```

### sort

Sort elements by natural order.

```
.tags | sort
-> ["api", "stable", "v1"]
```

### sort_by(key)

Sort elements by a key expression.

```
.users | sort_by(.age)
-> [Alice (25), Bob (35), Carol (42)]

.users | sort_by(.name) | map(.name)
-> ["Alice", "Bob", "Carol"]
```

### group_by(key)

Group elements by a key. Returns `[{key, values}]`.

```
.users | group_by(.active)
-> [
     {"key": true, "values": [Alice, Carol]},
     {"key": false, "values": [Bob]}
   ]
```

### unique

Remove duplicate values.

```
[1, 2, 2, 3, 1] | unique
-> [1, 2, 3]
```

### unique_by(key)

Remove duplicates by a key expression.

```
.users | unique_by(.active) | map(.name)
-> ["Alice", "Bob"]
```

### flatten

Flatten one level of nesting.

```
[[1, 2], [3, 4], [5]] | flatten
-> [1, 2, 3, 4, 5]
```

### reverse

Reverse the order.

```
.tags | reverse
-> ["stable", "v1", "api"]
```

### keys

Map keys or list indices.

```
.config | keys
-> ["database", "debug"]

.tags | keys
-> [0, 1, 2]
```

### values

Map values (identity for lists).

```
.config.database | values
-> ["localhost", 5432]
```

### length

Length of a list, map, or string.

```
.users | length
-> 3

.version | length
-> 5
```

### first, last

First or last element of a list.

```
.users | first | .name
-> "Alice"

.tags | last
-> "stable"
```

### sum, avg, min, max

Aggregate operations on numeric lists.

```
.users | map(.age) | sum
-> 102

.users | map(.age) | avg
-> 34.0

.users | map(.age) | min
-> 25

.users | map(.age) | max
-> 42
```

### has(key)

Check if a map contains a key.

```
.config | has("database")
-> true

.config | has("missing")
-> false
```

### to_entries, from_entries

Convert between maps and `[{key, value}]` lists.

```
.config.database | to_entries
-> [{"key": "host", "value": "localhost"}, {"key": "port", "value": 5432}]

[{"key": "a", "value": 1}] | from_entries
-> {"a": 1}
```

### filter_values(predicate)

Filter a map's values.

```
.config.database | filter_values(. == "localhost")
-> {"host": "localhost"}
```

### map_values(expression)

Transform a map's values.

```
{"a": 1, "b": 2} | map_values(. * 10)
-> {"a": 10, "b": 20}
```

### filter_keys(predicate)

Filter a map's keys.

```
.config | filter_keys(. != "debug")
-> {"database": {"host": "localhost", "port": 5432}}
```

## Null propagation

Navigation on null returns null. Computation on null throws.

**Returns null** (absence is data):

```
.missing              -> null
.missing.nested       -> null
.users[99]            -> null
null | length         -> null
null | filter(.x)     -> null
```

**Throws** (type mismatch is an error):

```
null + 5              -> Error: +: expected number, got null
null > 3              -> Error: >: expected number, got null
if null then 1 else 2 -> Error: if: expected bool, got null
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
