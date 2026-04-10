---
title: LAM
section: 1
source: Lambë 0.1.0
author: Hakim Jonas Ghoula
date: April 2026
---

# NAME

lam - query structured data files

# SYNOPSIS

**lam** [*OPTIONS*] *EXPRESSION* [*FILE*]

**lam** **-i** [*OPTIONS*] *FILE*

# DESCRIPTION

Query JSON, YAML, TOML, HCL, XML, CSV, and TSV files using a composable pipeline DSL. Format is auto-detected from file extension.

If no file is given, reads from standard input.

# OPTIONS

**-p**, **--pretty**
:   Pretty-print output. On by default.

**--no-pretty**
:   Disable pretty-printing.

**-r**, **--raw**
:   Output strings without quotes.

**-f**, **--format** *FMT*
:   Input format. One of: json, yaml, toml, hcl, xml, csv, tsv. Auto-detected from file extension if omitted.

**-t**, **--to** *FMT*
:   Output format. One of: json, yaml, toml, xml, csv, tsv, hcl. Default is json.

**--schema**
:   Show the data structure with type names instead of values.

**--assert**
:   Evaluate the expression and exit with code 0 if the result is true, 1 if false.

**-i**, **--interactive**
:   Start the interactive REPL. Requires a file argument.

**-h**, **--help**
:   Show usage information.

# QUERY LANGUAGE

Queries start with **.** (the current document) and chain operations with **|**.

## Field access

**.name** accesses a field. **.a.b.c** chains access. Missing fields return null.

## Indexing

**.[0]** indexes into a list. **.[**-1**]** indexes from the end. Out of bounds returns null.

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

**sum**, **avg**, **min**, **max**
:   Aggregate operations on numeric lists.

**has**(*key*)
:   Check if a map contains a key.

**to_entries**
:   Map to [{key, value}].

**from_entries**
:   [{key, value}] to map.

**filter_values**(*pred*)
:   Filter a map's values.

**map_values**(*expr*)
:   Transform a map's values.

**filter_keys**(*pred*)
:   Filter a map's keys.

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

Schema inspection:

    lam --schema deployment.yaml

CI validation:

    lam --assert '.version != "0.0.0"' package.json

Pipe from stdin:

    curl -s https://api.example.com/data | lam '.results | first'

Interactive exploration:

    lam -i data.json

# SEE ALSO

**jq**(1)

Project: https://github.com/hakimjonas/lambe

Documentation: https://pub.dev/packages/lambe
