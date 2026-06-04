---
title: LAM
section: 1
source: Lambë 0.12.0
author: Hakim Jonas Ghoula
date: June 2026
---

# NAME

lam - query structured data files

# SYNOPSIS

**lam** [*OPTIONS*] *EXPRESSION* [*FILE*]

**lam** **-i** [*OPTIONS*] *FILE*

# DESCRIPTION

Query JSON, YAML, TOML, HCL, CSV, TSV, and Markdown files using a composable pipeline DSL. Format is auto-detected from file extension.

Lambë infers the structural shape of query results and reports incompatibilities with target output formats. Use **--explain** to trace the shape at each pipeline stage, or the **as**(*fmt*) combinator inside a query to bridge common mismatches.

If no file is given, reads from standard input.

# OPTIONS

**-p**, **--pretty**
:   Pretty-print output. On by default.

**--no-pretty**
:   Disable pretty-printing.

**-r**, **--raw**
:   Output top-level string scalars without quotes. No effect on structured output (objects, arrays, numbers, booleans, null) — those still serialize through the active output format.

**-f**, **--format** *FMT*
:   Input format. One of: json, yaml, toml, hcl, csv, tsv, markdown. Auto-detected from file extension if omitted.

**-t**, **--to** *FMT*
:   Output format. One of: json, yaml, toml, csv, tsv, hcl. Default is json.

**--flatten-cells** *POLICY*
:   CSV/TSV policy for non-scalar cells. **refuse** (default) rejects list- or map-valued cells with a shape error. **json** encodes them as JSON strings inline; the shape check correspondingly widens to accept any list at the root. Ignored for other output formats.

**--schema** *PATH*
:   Path to a JSON Schema subset file. Threads the declared shape through inference and **--explain**, validates data against the schema at load time (errors on concrete-type disagreement), and fills in shape details the sampled data doesn't cover (empty-list elements, optional fields). Auto-detected as a sibling **<datafile>.schema.json** if omitted. Accepts **type**, **properties**, **items**, and **required**; rejects structural combinators (allOf/oneOf/$ref) and value-level constraints (minimum/pattern/enum/etc) with a per-keyword error.

**--print-shape**
:   Print the inferred shape of the data as a JSON Schema subset document. Replaces the 0.8.0 **--schema** flag with the same meaning, renamed because **--schema** now takes a path value.

**--explain**
:   Trace the shape of values flowing through each pipeline stage. Static analysis only; does not execute the query. Reports which output formats the final shape can be serialized as. Flags provably-empty filters and runtime-rejection mismatches.

**--explain-trivial**
:   Include trivial-result warnings in the explain report. Flags parameterised ops (**sort_by**, **group_by**, **map**, **unique_by**) whose argument references a field provably absent on the element shape. Implies **--explain**.

**--explain-json**
:   Emit the explain report as a JSON document instead of the text table. Useful for agent tooling or build-pipeline integration. Implies **--explain**.

**--assert**
:   Evaluate the expression and exit with code 0 if the result is true, 1 if false.

**-i**, **--interactive**
:   Start the interactive REPL. Requires a file argument.

**--ndjson**
:   Treat input as ndjson or jsonl: one JSON document per line, evaluated independently with no state shared between lines. Emits one compact JSON result per line on stdout. Auto-enabled when the file extension is **.ndjson** or **.jsonl**. Cannot combine with **--interactive**, **--schema**, **--print-shape**, **--assert**, or **--explain**. Output must be JSON (**--to json** or default); other **--to** values are refused.

**-n**, **--null-input**
:   Run the query against **null** context with no input. Useful for value computations like `lam -n '[1,2,3] | unique'`. Without **-n**, the missing-input guard fires (a typo'd filename or missing redirect is a common footgun); the flag makes the "I have no input" intent explicit. Cannot combine with **--interactive**, **--ndjson**, **--schema**, or **--assert**.

**--skill**
:   Print the embedded agent SKILL.md to stdout and exit. Lets agent harnesses install the skill regardless of how `lam` was acquired: `lam --skill > .agents/skills/lambe/SKILL.md`. The content is captured at compile time from `.agents/skills/lambe/SKILL.md` in the lambë source.

**--completions** *SHELL*
:   Print a shell completion script for *SHELL* (**bash**, **zsh**, or **fish**) to stdout and exit. The script completes flag names, their fixed enum values (`--to`, `--format`, `--flatten-cells`, `--completions`), and file paths. It is static — no document is parsed and `lam` is not invoked at completion time. Install per your shell, e.g. `lam --completions zsh > "${fpath[1]}/_lam"`.

**--version**
:   Print the Lambë version (`lam <version>`) and exit.

**-h**, **--help**
:   Show usage information.

# QUERY LANGUAGE

Queries start with **.** (the current document) and chain operations with **|**.

## Field access

**.name** accesses a field. **.a.b.c** chains access. Missing fields return null.

## Indexing

**.[0]** indexes into a list. **.[-1]** indexes from the end. Out of bounds returns null.

## Slicing

**.[1:3]** extracts elements 1 and 2. **.[:3]** from the start. **.[2:]** to the end. **.[:-1]** all except the last.

## Arithmetic

+, -, *, /, % on numbers.

## Comparison

<, >, <=, >= on numbers. ==, != on any type.

## Boolean logic

&&, ||, ! with short-circuit evaluation.

## String interpolation

**"\\(.name) is \\(.age)"** evaluates expressions inside strings.

## Object construction

{name, total: .price * .qty} constructs a new object. {name} expands to {name: .name}.

## Conditionals

**if** *cond* **then** *a* **else** *b*

## Pipelines

**|** passes the left result into the right operation. Pipelines bind tighter than binary operators.

# PIPELINE OPERATIONS

**filter**(*pred*)
:   Keep elements where *pred* is true.

**map**(*expr*)
:   Transform each element.

**sort**
:   Sort by natural order.

**sort_by**(*key*)
:   Sort by a key expression.

**group_by**(*key*)
:   Group into [{key, values}].

**unique**
:   Remove duplicates.

**unique_by**(*key*)
:   Remove duplicates by key.

**flatten**
:   Flatten one level.

**reverse**
:   Reverse order.

**keys**
:   Map keys or list indices.

**values**
:   Map values.

**length**
:   Length of list, map, or string.

**first**, **last**
:   First or last element.

**sum** (jq alias: **add**), **avg**, **min**, **max**
:   Aggregate operations on numeric lists. `add` is accepted for jq-compatibility; `--explain` canonicalises to `sum`.

**has**(*key*)
:   Check if a map contains a key.

**to_entries**
:   Map to [{key, value}].

**from_entries**
:   [{key, value}] to map.

**to_number** (jq alias: **tonumber**)
:   Parse a string as a number. Pass-through for existing numbers. Both names parse identically; `--explain` canonicalises to `to_number`.

**type**
:   Runtime type of the value as a string: "null", "boolean", "number", "string", "array", or "object".

**filter_values**(*pred*)
:   Filter a map's values.

**map_values**(*expr*)
:   Transform a map's values.

**filter_keys**(*pred*)
:   Filter a map's keys.

**as**(*fmt*)
:   Shape-directed bridge to an output format. No-op when the current shape already satisfies *fmt*. Applies a single curated bridge when one exists. Errors with a list of candidates when more than one could apply. Valid *fmt*: json, yaml, toml, csv, tsv, hcl.

# NULL PROPAGATION

Navigation on null returns null: **.missing** returns null, **.missing.nested** returns null.

Computation on null throws: **null + 5** and **null > 3** are errors.

# INTERACTIVE MODE

**lam -i** *file* starts the REPL. Type queries at the **lambe>** prompt. REPL commands start with **:** to distinguish them from queries.

**:schema**
:   Show data structure.

**:to** *fmt*
:   Set output format.

**:raw**
:   Toggle unquoted string output.

**:pretty**
:   Toggle pretty-printing.

**:flatten-cells** *POLICY*
:   Set CSV/TSV cell policy for this session. One of: refuse, json.

**:load** *file*
:   Load a different data file.

**:history**
:   Show query history.

**:help**
:   Show available commands.

**:quit**, **:q**
:   Exit.

Tab completes field names and pipeline operations. Up/Down navigates history. Ctrl+R searches history.

# EXIT STATUS

**0**
:   Success, or **--assert** passed.

**1**
:   Error, or **--assert** failed.

# FILES

**~/.lambe_history**
:   REPL command history, persisted between sessions.

# EXAMPLES

Extract a value:

    lam '.database.host' config.toml

Filter and project:

    lam '.users | filter(.age > 30) | map(.name)' data.json

Aggregate:

    lam '.items | map(.price) | sum' data.json

Format conversion:

    lam --to yaml '.config' data.json

Shape inspection:

    lam --print-shape deployment.yaml

Schema-checked query (validates data against the schema before running):

    lam --schema api.schema.json '.users | map(.email)' response.json

Shape trace, schema-seeded (no data needed):

    lam --schema api.schema.json --explain '.users | map(.email)'

Shape trace for a pipeline:

    lam --explain '.users | filter(.age > 30) | map(.name)' data.json

Bridge to an output format inside the query:

    lam --to toml '.dependencies | as(toml)' pubspec.yaml

CI validation:

    lam --assert '.version != "0.0.0"' package.json

Pipe from stdin:

    curl -s https://api.example.com/data | lam '.results | first'

Interactive exploration:

    lam -i data.json

Line-delimited JSON (logs, event streams):

    lam --ndjson '.level' events.ndjson
    tail -f app.log | lam --ndjson '.user.id'

# SEE ALSO

**jq**(1) — the established JSON query tool. Lambë shares its pipeline aesthetic and extends to multi-format input with shape-aware output.

# BUGS

Report issues at <https://github.com/hakimjonas/lambe/issues>.

# HOMEPAGE

<https://ardaproject.org/lambe>
