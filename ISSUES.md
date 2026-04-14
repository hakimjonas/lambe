# Open issues

## 1. MCP tool descriptions lack syntax examples

The `lambe_query` tool description has 3 examples, all simple. No indexing, no
object construction, no chaining patterns. An AI model using the MCP tools gets
the tool description as its only syntax reference. Adding 5-6 patterns covering
field access, indexing, filter, object construction, and chaining would reduce
misuse and retry loops.

Affected: `bin/mcp_server.dart` (tool descriptions)

## 2. Parser error messages are not actionable

"Expected end of input at 1:9 (offset 49)" tells neither a human nor an AI what
went wrong. The offset is relative to the input string but the message gives no
hint about what the parser expected or what token it found. Suggestions like
"unexpected `{` after `|`, expected pipeline operation" would make errors
diagnosable without reading the parser source.

Affected: `lib/src/parser.dart`, rumil error reporting

## 3. No jq-to-lambe migration guide

Every AI model has trained heavily on jq syntax. When a model uses lambe, it
falls back to jq patterns (e.g. `--jq` flags, `select()` instead of `filter()`,
`@csv` instead of `--to csv`). A side-by-side cheatsheet mapping common jq
idioms to lambe equivalents would reduce this friction for both humans and AI.

Proposed: `doc/jq-to-lambe.md`

## 4. Recipes need more real patterns

`doc/recipes.md` serves as both user documentation and AI training data. More
patterns covering common workflows (k8s manifest queries, Terraform inspection,
CI validation, package.json extraction) would increase the likelihood that a
model has seen lambe syntax in pre-training.

Affected: `doc/recipes.md`

## 5. Syntax doc examples need test coverage

The syntax reference (`doc/syntax.md`) documents expressions like
`.users[0] | {name, age}` that had no corresponding test. This allowed a parser
bug (pipe not accepting expressions) to ship in 0.1.0 and 0.1.1 without being
caught. Every example in the syntax doc should have a matching test to prevent
documentation from drifting from implementation.

Proposed: `test/syntax_examples_test.dart` that systematically tests every
example in `doc/syntax.md`
