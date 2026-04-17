## 0.3.0

### Added
- **Markdown support.** CommonMark Markdown (.md, .markdown) is now a queryable
  input format. Parsed into a typed AST with node types like heading, paragraph,
  link, code_block, list, image, emphasis, etc.
- `mdToNative` public API for converting `MdDocument` to queryable Dart types
- Markdown query examples in MCP server instructions, AI.md, and AGENTS.md

### Changed
- Bumped rumil, rumil_parsers, rumil_expressions to ^0.5.0
- Rewrote `tool/manpage.dart` to use `parseMarkdown` + `parseYaml` from
  rumil_parsers instead of handrolled parser
- 491 tests (was 465)

## 0.2.0

### Breaking
- **`|` is expression composition.** `PipeOp` sealed class removed. Pipeline operations
  are now `LamExpr` subtypes. Any expression can appear after `|`:
  `.users[0] | {name, age}`, `. | if .active then "yes" else "no"`.

### Improved
- Parser error messages show position pointers and contextual descriptions
- "Did you mean?" suggestions for misspelled pipeline operations
- MCP tool descriptions expanded with syntax reference and common patterns
- Expanded recipes: object projection, string interpolation, chaining patterns

### Added
- `doc/jq-to-lambe.md` migration guide
- `test/syntax_examples_test.dart` backing every example in `doc/syntax.md`
- 465 tests (was 369)

## 0.1.1

- Added `.mcp.json` for automatic MCP server discovery in AI coding assistants
- Documented MCP server setup in README
- Added query syntax guide, REPL guide, recipes, and man page to `doc/`

## 0.1.0

### Core
- Query AST: sealed `LamExpr` hierarchy (16 subtypes) + sealed `PipeOp` (24 subtypes)
- Left-recursive parser via Rumil's `rule()` + Warth seed-growth
- Operator precedence via layered `chainl1` calls
- Null propagation: navigation propagates null, computation throws on type errors
- Tolerant parsing via `.recover()` for REPL completion and multi-line detection

### Query Language
- Property access chains: `.users[0].address.city`
- Negative indexing: `.items[-1]`
- String key indexing: `.data["key"]`
- Slicing: `.[1:3]`, `.[:3]`, `.[2:]`, `.[:-1]`
- Arithmetic: `+`, `-`, `*`, `/`, `%`
- Comparison: `<`, `<=`, `>`, `>=`, `==`, `!=`
- Boolean logic: `&&`, `||`, `!`
- Object construction with shorthand: `{name, total: .price * .qty}`
- Conditionals: `if .age > 65 then "senior" else "active"`
- String interpolation: `"\(.name) is \(.age) years old"`

### Pipeline Operations (24)
- Filter and transform: `filter`, `map`
- Ordering: `sort`, `sort_by`, `reverse`
- Grouping: `group_by` (returns `{key, values}` structure)
- Deduplication: `unique`, `unique_by`
- Structure: `flatten`, `keys`, `values`, `length`, `first`, `last`
- Aggregation: `sum`, `avg`, `min`, `max`
- Map operations: `filter_values`, `map_values`, `filter_keys`
- Existence: `has`
- Entry conversion: `to_entries`, `from_entries`

### Multi-format I/O
- Input: JSON, YAML, TOML, HCL, XML, CSV, TSV with auto-detection
- Output: `--to json/yaml/toml/xml/csv` for format conversion
- `--schema` for data structure inference
- `--assert` for CI/CD validation (exit 0 if true, 1 if false)

### Interactive REPL (`lam -i`)
- Parser-driven tab completion on field names, pipeline operations, and inner fields
- Syntax highlighting and colorized JSON output
- Persistent history (`~/.lambe_history`) with Ctrl+R reverse search
- Multi-line input with `\` continuation and parser-driven bracket detection
- Ctrl+Left/Right word movement, Ctrl+A/E/K/U editing shortcuts
- REPL commands: `:schema`, `:to`, `:raw`, `:pretty`, `:load`, `:history`, `:help`, `:quit`

### API
- Library: `query()`, `queryJson()`, `queryString()`, `parse()`, `eval()`
- Output: `formatOutput()`, `inferSchema()`
- CLI: `lam '<expression>' [file]` with all flags
- MCP server: `lambe_query`, `lambe_schema`, `lambe_assert` tools

### Ecosystem
- `lambe_test` package with matchers: `lamWhere`, `lamEquals`, `lamMatches`, `lamHas`
- MCP server installable via `dart pub global activate lambe` → `lam-mcp`
