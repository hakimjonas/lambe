/// Lexical grammar for the Lambé REPL syntax highlighter.
///
/// Lives in lambé rather than in rumil_tokens' built-in grammars
/// because the grammar is lambé-specific. The REPL's `_highlight`
/// builds a tokenizer from this grammar once at startup and re-runs
/// it on every keystroke, so the cost is amortized across a session.
library;

import 'package:rumil_tokens/rumil_tokens.dart';

import 'shape/pipe_ops.dart' as shape_ops;

/// Lambé query grammar for the REPL highlighter.
///
/// Keywords cover the conditional (`if/then/else`), the literals
/// (`true/false/null`), and the `and`/`or` aliases. Pipe op names
/// (`filter`, `map`, `text`, etc.) are wired through `types` so the
/// highlighter can render them distinctly from plain identifiers; the
/// list is derived from `pipe_ops.dart`'s spec table so adding an op
/// to the table picks up colouring automatically. Operator tables
/// match Lambé's actual operator set, including the right-associative
/// `//` alternative and the `&&`/`||` symbolic forms. No comments —
/// Lambé queries are one-liners typed at the REPL prompt.
final LangGrammar lambeGrammar = LangGrammar(
  name: 'lambe',
  keywords: const ['if', 'then', 'else', 'true', 'false', 'null', 'and', 'or'],
  types: shape_ops.pipeOpNames,
  stringDelimiters: const ['"'],
  punctuationChars: '(){}[],;:.',
  operatorChars: '+-*/%=!<>&|',
  multiCharOperators: const ['==', '!=', '<=', '>=', '&&', '||', '//'],
);
