# REPL Guide

Explore data interactively with tab completion, syntax highlighting, and history.

## Starting

```bash
lam -i data.json
lam -i config.toml
lam -i deployment.yaml
```

The format is auto-detected from the file extension. Override with `-f`:

```bash
lam -i -f yaml config.txt
```

## Querying

Type a query at the `lambe>` prompt and press Enter:

```
lambe> .users[0]
{
  "name": "Alice",
  "age": 25,
  "active": true
}
```

Results are pretty-printed JSON with colors: keys in cyan, strings in green, numbers in yellow, booleans in magenta, null in red.

Errors show inline without crashing the session:

```
lambe> .missing + 5
Error: +: expected number, got null

lambe> _
```

Null is shown explicitly:

```
lambe> .missing
null
```

Large results (more than 10 items) are truncated:

```
lambe> .items
[first 10 items shown]
... and 490 more
```

Queries slower than 100ms show timing:

```
lambe> .data | sort_by(.timestamp)
[42ms] [...]
```

## Tab completion

Press Tab at any point to complete field names or operations.

### Fields

```
lambe> .us<TAB>
lambe> .users

lambe> .users[0].<TAB>
.active    .age    .name

lambe> .config.data<TAB>
lambe> .config.database
```

### Pipeline operations

After `|`, Tab completes operation names:

```
lambe> .users | <TAB>
avg    filter    filter_keys    filter_values    first    flatten ...

lambe> .users | fil<TAB>
lambe> .users | filter
```

### Fields inside operations

Inside `filter(`, `map(`, `sort_by(`, etc., Tab completes element fields:

```
lambe> .users | filter(.<TAB>
.active    .age    .name

lambe> .users | filter(.address.<TAB>
.city    .zip
```

### Format completion

```
lambe> :to <TAB>
csv    hcl    json    toml    tsv    xml    yaml
```

## Commands

Commands start with `:` to distinguish them from queries.

| Command | Description |
|---------|-------------|
| `:schema` | Show data structure (types without values) |
| `:to fmt` | Set output format: json, yaml, toml, xml, csv, tsv, hcl |
| `:raw` | Toggle unquoted string output |
| `:pretty` | Toggle pretty-printing |
| `:load file` | Load a different data file |
| `:history` | Show query history |
| `:help` | Show available commands |
| `:quit`, `:q` | Exit |

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| Tab | Complete field name or operation |
| Up / Down | Navigate history |
| Ctrl+R | Reverse search through history |
| Ctrl+A | Move to start of line |
| Ctrl+E | Move to end of line |
| Ctrl+K | Delete to end of line |
| Ctrl+U | Delete to start of line |
| Ctrl+Left | Move back one word |
| Ctrl+Right | Move forward one word |
| Ctrl+C | Cancel current line |
| Ctrl+D | Exit (on empty line) |

## Multi-line input

End a line with `\` to continue on the next line:

```
lambe> .users \
...>   | filter(.age > 30) \
...>   | sort_by(.name) \
...>   | map({name, age})
[{"name": "Bob", "age": 35}, {"name": "Carol", "age": 42}]
```

Unclosed brackets continue automatically:

```
lambe> .users | map({
...>   name,
...>   total: .price * .qty
...> })
```

Unclosed strings also continue:

```
lambe> .users | map("name:
...> ")
```

Press Enter on an empty continuation line or Ctrl+C to cancel.

## History

Query history is saved to `~/.lambe_history` between sessions. Multi-line queries are stored as single entries. Consecutive duplicate queries are not repeated.

Browse history with Up/Down arrows. Search history with Ctrl+R:

```
(reverse-i-search)`filt': .users | filter(.age > 30) | map(.name)
```

Type characters to narrow the search. Press Enter to accept, Escape to cancel.

## Next steps

- [Syntax reference](syntax.md) for the full language
- [Recipes](recipes.md) for real-world patterns
- [Getting started](getting-started.md) if you skipped it
