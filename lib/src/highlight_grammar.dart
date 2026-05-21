/// Lexical grammar for the Lambé REPL syntax highlighter.
///
/// Lives in lambé rather than in rumil_tokens' built-in grammars
/// because the grammar is lambé-specific. The REPL's `_highlight`
/// builds a tokenizer from this grammar once at startup and re-runs
/// it on every keystroke, so the cost is amortized across a session.
library;

import 'package:rumil_tokens/rumil_tokens.dart';

/// Lambé query grammar for the REPL highlighter.
///
/// Keywords cover the conditional (`if/then/else`), the literals
/// (`true/false/null`), and the `and`/`or` aliases. Operator tables
/// match Lambé's actual operator set, including the right-associative
/// `//` alternative and the `&&`/`||` symbolic forms. No comments —
/// Lambé queries are one-liners typed at the REPL prompt.
const LangGrammar lambeGrammar = LangGrammar(
  name: 'lambe',
  keywords: ['if', 'then', 'else', 'true', 'false', 'null', 'and', 'or'],
  stringDelimiters: ['"'],
  punctuationChars: '(){}[],;:.',
  operatorChars: '+-*/%=!<>&|',
  multiCharOperators: ['==', '!=', '<=', '>=', '&&', '||', '//'],
);
