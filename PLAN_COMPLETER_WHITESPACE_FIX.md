# Completer whitespace bug — investigation plan

**Status:** open. No code changed.

## Summary

Tab completion in the Lambé REPL (and the WASM-embedded playground)
produces a corrupt replacement when the query has trailing whitespace
after a syntactically complete expression. Reported example:

```
Type:   .
Tab.    Pick ".dependencies".
Text:   ".dependencies"
Type a space. Text: ".dependencies ".
Tab.    Pick any candidate.
Result: "..dependencies" (or similar corruption).
```

The playground surfaces this because the textarea query field has
trailing whitespace more often than the terminal REPL. But the REPL
has the same underlying library behavior.

## Why it is a real bug, not an inconvenience

- `complete()` is a public Lambé library function.
- The CLI REPL calls it; it is not a playground-only path.
- The `start` offset it returns is a contract: callers replace
  `text[start, cursor)` with the chosen candidate. When `start` is
  wrong, every caller corrupts the line.
- The corruption is silent: no exception, no visible error, the
  replacement simply inserts extra characters into the query.

## Investigation questions

Each must be answered with code that reproduces or rules out the case.

### Reproduction

1. **REPL reproduction.** Start `lam -i <file>`. Keystroke sequence
   that produces corruption. Record exact input and output.
2. **Unit-test reproduction.** Minimal `complete(text, cursor, data)`
   call that returns a `start` inconsistent with the `.` position in
   `text`.

### Scope of the offset bug

For every combination below, determine: does the returned `start`
position the leading `.` of the replacement correctly?

3. Trailing single space after a field tail:
   - `". "` + Tab — identity-from-root with trailing space.
   - `".users "` + Tab — Field tail with trailing space.
   - `".config.database "` + Tab — Access tail with trailing space.
4. Trailing whitespace other than space:
   - `".users\t"` + Tab — tab character.
   - `".users\n"` + Tab — newline character (relevant for multi-line
     textarea input from the playground).
5. Multiple whitespace characters:
   - `".users   "` + Tab (three spaces).
   - `".users \t "` + Tab (mixed).
6. Inside parameterized op:
   - `".users | filter(.age )"` + Tab at cursor position 21 (right
     after the space).
   - `".users | map(.name )"` with the cursor after the space.
7. Pipe-op completion path:
   - `".users |"` + Tab, cursor after `|`.
   - `".users | "` + Tab, cursor after the space.
   - `".users | fil "` + Tab (trailing space after partial op).
8. Command path:
   - `":to yaml "` + Tab (completion inside a :command).

### Boundary cases not involving whitespace

9. Identity without dot: `""` + Tab — what does the completer return?
10. Only `.` at cursor 0 vs cursor 1 — sanity-check the well-known
    paths still work and the fix does not break them.

## Hypothesized locations

Reading `lib/src/completer.dart` at HEAD:

- Line 62: `parsePartial(before)`. Rumil-derived parser; `consumed`
  typically points past any skipped trailing whitespace because the
  lexer consumes `_ws` after each token.
- Lines 70–72: `remainder = before.substring(consumed)`. If `consumed`
  already includes trailing whitespace, `remainder` is empty and
  `trimmed` is also empty.
- Lines 74–85: `_pipeRx` path. Uses `trimOff + pipeMatch.end - partial.length`
  for the start. This looks correct: `trimOff` accounts for
  `trimLeft()`, and the regex is anchored at the end of `trimmed`.
- Lines 91–96: `_fieldTailRx` path. Uses `trimOff + fMatch.start`. If
  `trimmed` is empty (trailing whitespace case), the regex does not
  match and we fall through.
- Lines 98–100: `_completionContext(ast, before, rootShape)` — passes
  `before` (the whole typed text including trailing whitespace) and
  the tail case computes `before.length - name.length - 1`. This is
  the suspect arithmetic: if `before` has trailing whitespace, the
  subtraction lands past the `.`.

The one-line hypothesis: **in the fall-through to `_completionContext`,
`before.length` is the wrong offset to use for tail-based replacement
start. We need the position immediately after the AST's last
non-whitespace character.**

Status: hypothesis, not proven. The investigation must verify it for
every case above.

## Test matrix

Every case in "Scope" above becomes a test in a new group,
`Trailing whitespace regression`, in `test/completer_test.dart`.
Written **before** the fix; each failing test is a proof the bug
covers that case.

## Fix shape options

**A. Compute a separate `astEnd` offset.** Pass the position of the
end of the AST's last significant character through to
`_completeAstTail`. The offsets `before.length - name.length - 1`
become `astEnd - name.length - 1`, which is correct regardless of
trailing whitespace.

Cost: one new parameter threaded through two functions, one helper
that walks `before` backward over whitespace. No changes to callers.

**B. AST nodes carry source spans.** Overkill for this bug. Out of
scope.

**C. Retry without trailing whitespace.** Trim `before` before the
fallthrough and re-enter. Loses the original `cursor` intent;
candidates might be wrong for the trailing-whitespace-case's true
intent (the user is starting a new token after a space). Not a clean
fix.

A is the right shape once the scope is characterized.

## Release-gate checklist (once fix lands)

1. `dart format --set-exit-if-changed .`
2. `dart analyze --fatal-infos` clean.
3. `dart doc --dry-run` zero warnings.
4. `dart test` both root and `lambe_test/`.
5. `pana --no-warning` 160/160.
6. AOT bench: `dart compile exe tool/bench/completer_bench.dart -o tool/bench/completer_bench.aot`
   and `dart run tool/bench/run.dart --tag pre-0.6.1 --aot --runs 5`
   on the pre-fix HEAD, then again on the fixed HEAD. Compare medians;
   completer perf must stay within noise.
7. Bump `pubspec.yaml` version to `0.6.1`. Regenerate
   `lib/src/_version.dart` via `dart run tool/gen_version.dart`.
8. CHANGELOG: add `## 0.6.1` section describing the fix.
9. Commit, `git tag -a v0.6.1 -m "Lambe 0.6.1"`, push main, push tag.
10. Monitor the Release workflow; ensure all five matrix cells succeed.
11. `dart pub publish` manually.

## Handoff to arda-web

Only after 0.6.1 is live on pub.dev:

1. Bump arda-web's `pubspec.yaml`: `lambe: ^0.6.1`.
2. `dart pub get`.
3. `dart compile wasm wasm/lambe_demo.dart`.
4. Copy to `static/wasm/` and `build/wasm/`, docker cp.
5. Manually verify: load the Tab-completion bug reproduction in the
   browser, confirm it is resolved.
