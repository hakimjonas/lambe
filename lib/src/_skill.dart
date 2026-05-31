// GENERATED FILE. DO NOT EDIT.
// Run `dart run tool/gen_skill.dart` to regenerate after editing
// .agents/skills/lambe/SKILL.md.

/// Embedded contents of `.agents/skills/lambe/SKILL.md`, captured at
/// build time. Surfaced via `lam --skill` so an agent harness can
/// install the skill regardless of how `lam` was acquired:
///   `lam --skill > .agents/skills/lambe/SKILL.md`
const lambeSkill = r'''---
name: lambe
description: Query, filter, transform, validate, and convert structured data files (JSON, YAML, TOML, HCL/Terraform, CSV, TSV, Markdown) using the `lam` CLI. Use when the user asks to extract a field, filter records, aggregate values, check structure, validate against a schema, or convert between formats. Works on config files, API responses, deployment manifests, data exports, and Markdown documents (parsed as a typed AST). Bounded — no recursion, no `def`, no regex; for those the user should reach for a real programming language.
license: MIT
metadata:
  homepage: https://pub.dev/packages/lambe
  repository: https://github.com/hakimjonas/lambe
---

# Lambé (`lam`) — structured data queries

Lambé is on the user's PATH after `dart pub global activate lambe`. You
invoke it via shell. The binary is named `lam`.

**Sandbox note for agent harnesses:** some agent shells do not inherit
the user's interactive PATH. If `lam: command not found` appears, fall
back to the absolute path `~/.pub-cache/bin/lam`, which is where `dart
pub global activate` installs it. This is a shell-environment behavior,
not a lambé issue.

## When to reach for `lam`

The user wants to do something with a **structured data file**:
- "Get the X field from this JSON"
- "Filter the Y where Z"
- "Sum / count / list / sort the items"
- "What's the structure of this file?"
- "Check that the deployment has at least 2 replicas"
- "Convert this YAML to TOML"
- "List all the headings in this README"

Don't reach for `lam` when:
- The data is binary, in a database, or a stream.
- The user explicitly asked for jq syntax (use jq).
- The query needs recursion, `try`/`catch`, regex, or accumulating state — write code instead.

## Core moves

```bash
# Extract — single value or path
lam '.database.host' config.toml

# Filter + project
lam '.users | filter(.age > 30) | map(.name)' data.json

# Aggregate
lam '.items | map(.price) | sum' data.json

# Inspect structure (returns JSON Schema)
lam --print-shape data.json

# Static query trace (no execution; surfaces shape per stage + warnings)
lam --explain '.config | flatten | as(toml)' data.json

# CI assertion (exit 0 on true, 1 on false)
lam --assert '.replicas >= 2' deployment.yaml

# Convert format
lam --to yaml '.config' data.json

# Run without input (literal-only queries)
lam -n '[1, 2, 2, 3] | unique'

# Markdown headings (use `text` op, not `.children[0].text`)
lam '.children | filter(.type == "heading") | map(text)' README.md
```

## Syntax in 30 seconds

**Property access**: `.field`, `.users[0]`, `.users[-1]`, `.tags[1:3]`,
`.["x-axis"]` (bracket form for non-identifier keys).

**Pipeline ops** chained with `|`:
`filter(p)`, `map(e)`, `sort`, `sort_by(k)`, `group_by(k)`, `unique`,
`unique_by(k)`, `flatten`, `reverse`, `length`, `first`, `last`,
`sum`, `avg`, `min`, `max`, `keys`, `values`, `has("k")`,
`to_entries`, `from_entries`, `to_number`, `type`,
`filter_values(p)`, `map_values(e)`, `filter_keys(p)`, `text` (markdown),
`as(fmt)` (cross-format bridge).

**Expressions**: arithmetic `+ - * / %`, comparison `< > <= >= == !=`,
boolean `&& || !`, null fallback `//`, conditional `if c then a else b`,
object construction `{name, total: .price * .qty}`, string interpolation
`"\(.name) is \(.age)"`, list literal `[1, 2, 3]`.

**Boolean keywords**: lambé's logic operators are `&&` `||` `!`. `and`
and `or` are accepted as keyword aliases (jq compatibility). `not` is
not aliased; use `!`.

## Markdown data model

Markdown parses to a CommonMark AST. Root is `{type: "document", children: [...]}`.
Every node has a `type`. Container nodes have `children`; leaves carry
content directly.

Common queries:

```bash
# Heading texts (use `text` op for prose extraction)
lam '.children | filter(.type == "heading") | map(text)' doc.md

# Headings with levels
lam '.children | filter(.type == "heading") | map({level, title: text})' doc.md

# Code blocks by language
lam '.children | filter(.type == "code_block") | map({language, code})' doc.md

# Whole document as plain text
lam '. | text' doc.md
```

The `text` op walks any node tree and concatenates prose recursively
(text + code + code_block + image alt). Use it instead of
`.children[0].text` — that pattern only sees the first immediate child
and misses nested emphasis, links, and inline code.

## Common gotchas

- **Output is pretty-printed JSON by default.** Pass `--no-pretty` for
  compact output, or `-r` for raw top-level strings (no quotes).
- **Lambé's null contract**: navigation returns null (`.missing` is null,
  doesn't throw); computation throws (`.missing + 5` errors). Use
  `.field == null` to test, or `.field // default` to substitute.
- **Empty-list policy**: `first`/`last` return null on empty;
  `min`/`max`/`avg` throw; `sum` returns 0.
- **Heterogeneous lists** widen to `any` in shape inference. Real-world
  markdown children, mixed JSON arrays. The shape system is honest about
  this; `--print-shape` shows the widening.
- **Output format errors give actionable hints.** If `lam --to toml ...`
  rejects the shape, the error names the `as(...)` bridge to apply.
- **`--explain` is your friend** when a query is unexpectedly empty or
  errors. It prints the shape at every stage statically, plus warnings
  for runtime-rejected ops and provably-empty filters.

## What lambé deliberately doesn't do

`..` recursive descent, `def` user functions, `try`/`catch`, regex,
`getpath`/`setpath`, in-place mutation, streaming. If you draft a
query needing any of these, lambé will tell you with an "unknown
pipe op" error or a `_jqIdiomHint`. See the non-goals reference for
the lambé idiom that replaces each omission.

## When you hit something this skill doesn't cover

Deeper reference lives in the lambé repo:

- `AGENTS.md` — broader reference: more examples, full pipeline op
  list, error pattern table, format auto-detect rules.
  <https://github.com/hakimjonas/lambe/blob/main/AGENTS.md>
- `doc/syntax.md` — language reference.
  <https://github.com/hakimjonas/lambe/blob/main/doc/syntax.md>
- `doc/recipes.md` — end-to-end examples.
  <https://github.com/hakimjonas/lambe/blob/main/doc/recipes.md>
- `doc/non-goals.md` — what lambé deliberately doesn't do, and the
  lambé idiom that replaces each omission.
  <https://github.com/hakimjonas/lambe/blob/main/doc/non-goals.md>

The MCP server `lam-mcp` is available for sandboxed agents that can't
shell out.
''';
