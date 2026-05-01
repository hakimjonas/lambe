# Handover: Lambë 0.8.0

Written at end of the 0.7.1 session. You are resuming on branch
`feature/0.8.0` (already created, local only, based on `main` at
commit `49b2ad4` — the merged 0.7.1).

## What 0.8.0 ships

Two work items, announced in `ROADMAP.md`, plus an incidental real
bug that falls out of the first item.

1. **Inner-expression shape validation** — extend the shape story
   from pipe-op granularity down into the inner expressions of
   parameterized ops (`filter(.x)`, `map(.y)`, `sort_by(.z)`, etc.)
   AND to element-level CSV/TSV writability.
2. **Parser error recovery / multi-line diagnostics** — upgrade
   one-shot CLI queries from a single point-error to jq-style
   multi-line tracebacks.

Item 2 can ship as a second commit inside 0.8.0; don't block on it.
Item 1 is the core.

---

## Concrete bug driving item 1

A real user-reported bug, reproducible today on published `lambe
0.7.1`. This is your smoke test for the element-level-shape fix.

### Fixture

Create `/tmp/data.yaml`:

```yaml
name: rumil
version: 0.6.0
description: Parser combinators for Dart

dependencies:
  rumil: ^0.6.0
  rumil_parsers: ^0.6.0
  rumil_expressions: ^0.6.0

dev_dependencies:
  test: ^1.31.0
  lints: ^6.0.0
```

### Reproduction

With `lam` installed (`~/.pub-cache/bin/lam` from `dart pub global
activate lambe`):

```
$ lam --to csv '.dependencies | as(csv) | as(toml) | as(csv)' /tmp/data.yaml
key,value
items,"[{key: rumil, value: ^0.6.0}, {key: rumil_parsers, value: ^0.6.0}, {key: rumil_expressions, value: ^0.6.0}]"
```

The single cell's value is Dart's default `List<Map>.toString()`
output — debug-format garbage written as a CSV cell.

### Trace at each stage

Use `lam --explain ...` and `lam --to json ...` to compare shape vs.
value at each pipe stage. Previously verified:

| Stage | Value (JSON) | Shape |
|---|---|---|
| `.dependencies` | `{rumil:"^0.6.0", ...}` | `SMap<rumil:string, ...>` |
| `\| as(csv)` | `[{key:"rumil", value:"^0.6.0"}, ...]` | `SList<SMap<key:string, value:string>>` |
| `\| as(toml)` | `{items: [...]}` | `SMap<items: SList<SMap<...>>>` |
| `\| as(csv)` | `[{key:"items", value: [...]}]` | `SList<SMap<key:string, value: SList<...>>>` |

Last stage is where garbage ships. `canWriteAs(csv)` returned
`Writable` because the value IS a list of maps — but CSV's real
constraint is "list of maps *with scalar cells*." The shape language
doesn't express "leaf-scalar-only," so the writer silently `toString`s
non-scalar cells.

### The three responsible layers

1. **`_toCsv` in `lib/src/output.dart`** (line 89): cell
   interpolation `'${map[h] ?? ''}'` has no guard against
   non-scalar values. Last line of defense.
2. **`MustBeList` in `lib/src/shape/check.dart`** (line 70):
   `accepts(Shape s) => s is SList || s is SAny` — too permissive
   for CSV. Needs element-level structure check.
3. **Shape language itself** in `lib/src/shape/shape.dart`: has no
   way to express "only scalar-leaf-cell maps." Needs extension —
   see "Design decision" below.

### Pre-existing, not 0.7.x regression

`_toCsv` hasn't been touched since 0.6.0 (`git log --oneline
lib/src/output.dart` shows `eff7c1d Lambe 0.6.0` as the last
change). 0.7.0/0.7.1 did not introduce this.

---

## Design decision for element-level constraints

Two routes — **pick one before writing code**.

### Option A: Richer `ShapeRequirement` subclasses

Keep the `Shape` hierarchy as-is. Make `MustBeList` stricter by
requiring a recursive predicate on element shapes. E.g. a new
`MustBeFlatList` or `MustBeScalarListOfMaps` that walks the element
shape to check for scalar leaves only.

**Pro:** Localized change. `Shape` stays simple.
**Con:** Every new format-specific constraint means a new
`ShapeRequirement` subclass.

### Option B: Extend shape algebra with scalar/structured marker

Add a notion of "scalar shape" to the `Shape` hierarchy (maybe via
a method `bool get isScalar` on `Shape` — `true` for
`SNull`/`SBool`/`SNum`/`SString`, `false` for `SList`/`SMap`,
`SAny` returns something ambiguous). Format requirements then ask
the shape questions like `shape.allCellsAreScalar()`.

**Pro:** Generalizes. Any format-writability question can query the
same predicate library.
**Con:** More invasive; touches every concrete shape class.

**Recommendation: Option A.** Lambë's scope is narrow (6 output
formats). The set of format-specific constraints is bounded. A
handful of `ShapeRequirement` subclasses is cleaner than generalizing
the shape algebra for one concrete case. If future-you adds a 7th
format with yet-another constraint, add another requirement class.

---

## Work items in dependency order

### 1. Write the driving test first (~1h)

`test/csv_as_round_trip_test.dart` (new). Tests that today **fail**
on the bug and **pass** after the fix:

- `.deps | as(csv) | as(toml) | as(csv)` on the fixture map
  should either (a) produce correct output OR (b) throw
  `OutputShapeError` with a remediation. Silently producing garbage
  cells is forbidden.
- Same chain with `tsv` instead of `csv`.
- Direct hit: construct `[{key:"a", value: [1,2,3]}]` manually and
  run `formatOutput(value, OutputFormat.csv)` — assert it throws,
  not silently renders `"[1, 2, 3]"`.

Baseline: run against unchanged `main`. Should fail. That's the
"bug reproduced" checkpoint.

### 2. Strengthen `MustBeList` for CSV/TSV (~2-3h)

Modify `lib/src/shape/check.dart`:

- Split `MustBeList` into `MustBeList` (generic) and
  `MustBeFlatList` (CSV/TSV — list whose elements are scalars OR
  maps with scalar-only values, OR lists of scalars).
- Update `requirementFor(OutputFormat.csv)` and
  `requirementFor(OutputFormat.tsv)` to return the stricter one.
- The new `accepts` predicate recursively checks element shape. For
  `SList<SMap<f1:X, f2:Y, ...>>`, ensure every `Xi` is scalar. For
  `SList<SList<X>>`, ensure the inner `X` is scalar. For
  `SList<Scalar>`, accept. For `SList<SAny>`, accept (can't prove
  incompatibility).
- `_suggestionsFor(SList<SMap<...non-scalar...>>, csv)` needs a new
  curated remediation. `to_entries` won't help (already in that
  shape). Probably: no remediation, just a clear
  `OutputShapeError`. Or a remediation that flattens to JSON cells
  (if you want to go that route — I wouldn't).

### 3. `_toCsv` defensive assertion (~30m)

Even with the shape check, `_toCsv` should still refuse to
stringify non-scalar cells. Belt and braces — the shape path
could be bypassed (e.g. JIT type-erasure, malformed input). Throw
`QueryError` with a clear message, not `OutputShapeError`, since
by the time we're in `_toCsv` the shape check has already passed —
this is "unreachable unless shape check was wrong."

### 4. Update tests & consistency matrix (~1h)

- `test/pipe_ops_consistency_test.dart` already pins evaluator vs.
  spec. Doesn't cover output-writability. Add a parallel matrix
  that pins `canWriteAs(shape, format)` vs. `formatOutput(value, fmt)`
  actually succeeding — the same "spec agrees with runtime" discipline.
- Update the bug-driving test from step 1 to assert the new expected
  behavior (either correct output from a new bridge, or a clean
  `OutputShapeError` with a sensible message).

### 5. Inner-expression shape validation for parameterized ops (~3-4h)

This is the bulk of item 1's roadmap description. Separate track
from the CSV fix, sharing the same shape infrastructure.

- `.users | filter(.missing)` where `.users: SList<SMap<{name, age, active}>>`:
  - Today: completer offers every field in `.users[0]` shape. `.missing`
    inside the predicate is never flagged.
  - Target: when typing `.users | filter(.` and Tab, offer only fields
    that exist on the element shape. Already works (`completer.dart`
    has this today via `_resolveTarget` for parameterized-op inner
    expressions). **Verify this is still correct post-0.7.1.**
  - For `.users | filter(.missing)` fully typed and submitted, `inferShape`
    currently returns `SList<SMap<{name, age, active}>>` (filter preserves
    input). But the predicate is always-null → always-false → empty list.
    **This is the stretch goal** — evaluate the predicate's shape-level
    result; if provably-false, emit a warning.

- `--explain '.users | filter(.missing)'`: today reports
  `list<map<name,age,active>>` at the filter stage. Target:
  include a warning like `predicate .missing resolves to null
  against element shape; filter will always produce []`.

### 6. Parser error recovery / multi-line diagnostics (~3-5h)

Separate from item 1, optional for 0.8.0. Current state:

- `lib/lambe.dart:_formatParseErrors` already picks the deepest
  error and emits `parse error at column N: <msg>`. Good
  foundation.
- Missing: source-line rendering with a caret under the offending
  column, jq-style:

  ```
  parse error at line 1, column 14:
    .users | filtre(.age > 30)
                 ^
    help: did you mean "filter"?
  ```

- Changes needed:
  - Track line offsets in the source (simple linear scan to find
    line starts).
  - For each ParseError, resolve its offset into (line, col) pair
    given the input.
  - Render a 3-line excerpt: line before (if any), offending line,
    caret line with the suggestion.
- Consider: multiple related errors (e.g. mismatched `(` at offset
  A + unterminated expression at offset B) — display both as a
  chained traceback?
- This is all in `lib/lambe.dart`, not the parser itself. Rumil's
  error positions are already accurate.

---

## Other notes from the 0.7.x cycle

### Uncommitted work in sibling repos

At end-of-session, two repos had uncommitted work that SHOULD have
been committed but wasn't (I punted to this handover):

1. **`/home/hakim/google/rem`** — validator rewrite.
   `lib/src/validate.dart` replaced entirely (new `validate(Node)`
   that walks the tree instead of parsing rendered HTML). Also 54
   `prefer_const_*` / `unnecessary_const` lints fixed via `dart
   fix --apply`. Tests pass (1048). On branch `main`, local only.
   **Commit message draft:**
   ```
   Rewrite validator to walk Node tree instead of parsing HTML

   validateHtml(String) → validate(Node). The old validator parsed
   rem's own output with rumil_parsers' XML parser, which doesn't
   understand HTML raw-text elements — CSS inside <style> or any
   markup-looking content inside <textarea> produced spurious
   errors. The new validator walks the sealed Node hierarchy
   directly (the same tree the renderer uses), so raw-text is
   naturally invisible.

   Checks: exactly-one-<h1>, heading-level skips, void-elements-
   with-children. Error paths point at 'html > body > main > h3'.

   Also: 54 preexisting lints cleaned up across 6 files.
   ```

2. **`/home/hakim/google/arda-web`** — multiple changes:
   - `pubspec.yaml`: bump `lambe: ^0.7.0 → ^0.7.1`
   - `pubspec_overrides.yaml`: drop lambe path override (now on pub.dev)
   - WASM rebuilt
   - `lib/templates/lambe_demo.dart`: `<h1>` for a11y, dynamic
     `v$lambeVersion` from lambe package, updated `_defaultData`
     fixture from `0.5.0 → 0.6.0`
   - `lib/templates/demo.dart`: `<h1>` for a11y
   - `bin/build.dart`: `validateHtml(html) → validate(entry.value)`
     for the new rem API
   - `lib/templates/man.dart`: one-line lint fix
   - `static/css/style.css`, `content/docs/lambe-man.md`, misc
     accumulated changes

   **On branch `master`, local only. Don't publish any of this
   until you've reviewed and decided what's commit-worthy.**

### Task #56: rumil_tokens 0.6.0 still pending

In-progress from before the 0.7.0 work started. Spans + grammar
correctness + `Operator`/`Variable` token additions designed but
not executed. Unblocks removing the last path override in
arda-web. Not a dependency of 0.8.0.

### Reminder from the 0.7.x session

User instructed: *"everything needs to be correct"* (no
pre-existing-lint free passes). Apply the same rule to 0.8.0:
before any 0.8.0 commit, `dart analyze --fatal-infos` must be
clean, `dart format --set-exit-if-changed` clean, `dart doc
--dry-run` zero warnings, `pana` 160/160.

User also instructed: *"multiple reviews catch real issues."* Did
three reviews on 0.7.1 and the third review caught substantive
problems. Plan for two or three review passes on 0.8.0 before
opening a PR.

---

## Starting state

- **Branch**: `feature/0.8.0` (already created, local only)
- **Base**: `main` at commit `49b2ad4` (0.7.1 merged)
- **pubspec.yaml**: version still `0.7.1` — bump when ready
- **ROADMAP.md**: 0.8.0 entry already describes the plan, no change needed until shipping

## Launch checklist for the next session

1. Read this file.
2. `cd /home/hakim/google/lambe && git branch --show-current` should say `feature/0.8.0`.
3. Reproduce the CSV round-trip bug from step "Reproduction" above. Confirm it's still broken.
4. Decide Option A vs. Option B (recommend A — see "Design decision").
5. Write the driving test (step 1 above) — commit as "Failing test for CSV/TSV element-level shape gap".
6. Implement the fix (steps 2-4).
7. Consider item 5 (inner-expression validation) and item 6 (parser diagnostics) as follow-on commits within the same 0.8.0 branch.
8. Final review pass (×3). Analyzer/format/test/doc/pana all green.
9. Version bump to 0.8.0, regenerate _version.dart, update CHANGELOG, update ROADMAP to mark 0.8.0 shipped + add 0.9.0 plan.
10. PR, review, merge, tag, publish.
