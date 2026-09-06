/// Query parser. Operator precedence via the `pratt` combinator; the
/// left-recursive postfix chain as an atom-then-suffix fold (LR-free).
///
/// Grammar structure:
///   _expr      = _operators           (top-level)
///   _operators = pratt(_postfix, [
///                  // prefix unary at bp 70
///                  Prefix('-', 70), Prefix('!', 70),
///                  // multiplicative (left-assoc) bp 60
///                  *, /, %
///                  // additive (left-assoc) bp 50
///                  +, -
///                  // comparison (left-assoc) bp 40
///                  <=, >=, <, >
///                  // equality (left-assoc) bp 30
///                  ==, !=
///                  // logic and (left-assoc) bp 20
///                  &&, and
///                  // logic or (left-assoc) bp 10
///                  ||, or
///                  // alternative (right-assoc) bp 5
///                  //
///                ])
///   _postfix   = _atom (SUFFIX)*       (left fold of postfix suffixes)
///   SUFFIX     = '|' pipe_op | '.' ident | '[' index ']' | '[' slice ']'
///   _atom      = number | string | bool | null | '(' _expr ')' | dotField
///                | objConstruct | listConstruct | conditional | pipe_op
library;

import 'package:rumil/rumil.dart';

import 'ast.dart';
import 'output_format.dart';
import 'shape/pipe_ops.dart' as shape_ops;

/// Parse a query expression string into a [LamExpr] AST.
Result<ParseError, LamExpr> parseQuery(String input) =>
    _ws.skipThen(_expr).thenSkip(_ws).thenSkip(eof()).run(input);

/// Parse without requiring end-of-input - for REPL partial parsing.
///
/// Returns the AST of whatever was successfully parsed. [Success.consumed]
/// tells you how far the parser got.
Result<ParseError, LamExpr> parsePartial(String input) =>
    _ws.skipThen(_expr).thenSkip(_ws).run(input);

/// All pipeline operation names, sorted alphabetically.
///
/// Re-exported from `shape/pipe_ops.dart`, which is the single source
/// of truth for pipe-op metadata (name, input-shape acceptance,
/// output-shape rule). Reading `pipeOpNames` derives from that table;
/// adding a new op means editing the spec table only.
final List<String> pipeOpNames = shape_ops.pipeOpNames;

final Parser<ParseError, void> _ws = satisfy(
  (c) => c == ' ' || c == '\t' || c == '\r' || c == '\n',
  'whitespace',
).many.as<void>(null);

Parser<ParseError, A> _lex<A>(Parser<ParseError, A> p) => p.thenSkip(_ws);

Parser<ParseError, String> _sym(String s) => _lex(string(s));

/// Match a keyword followed by a word boundary (not followed by `[a-zA-Z0-9_]`).
///
/// Used for no-arg pipe ops so `sort` does not greedily match in `sort_by`.
Parser<ParseError, String> _kw(String keyword) =>
    _lex(string(keyword).thenSkip((alphaNum() | char('_')).notFollowedBy));

final Parser<ParseError, String> _identNoWs = (letter() | char('_'))
    .zip((alphaNum() | char('_')).many)
    .map((pair) => pair.$1 + pair.$2.join());

final Parser<ParseError, LamExpr> _number = _lex(
  digit().many1.flatMap(
    (whole) => char('.').skipThen(digit().many1).optional.map((frac) {
      final str =
          frac != null ? '${whole.join()}.${frac.join()}' : whole.join();
      return NumLit(num.parse(str)) as LamExpr;
    }),
  ),
).named('number');

/// Tolerant closing paren without trailing whitespace consumption.
///
/// Used inside string interpolation where whitespace after `)` is literal
/// string content, not syntax whitespace.
final Parser<ParseError, String> _closeParenRaw = char(
  ')',
).recover(succeed(''));

/// Tolerant closing double-quote.
final Parser<ParseError, String> _closeQuote = char('"').recover(succeed(''));

/// A single part inside a double-quoted string.
final Parser<ParseError, LamExpr> _stringPart =
    string(r'\(').skipThen(_innerExpr).thenSkip(_closeParenRaw) |
    string(r'\\').as<LamExpr>(const StrLit(r'\')) |
    string(r'\"').as<LamExpr>(const StrLit('"')) |
    string(r'\n').as<LamExpr>(const StrLit('\n')) |
    string(r'\t').as<LamExpr>(const StrLit('\t')) |
    satisfy(
      (c) => c != '"' && c != r'\' && c != '\n',
      'string char',
    ).many1.map((cs) => StrLit(cs.join()) as LamExpr);

/// String literal: `"hello"`, `"age: \(.age)"`, `"line1\nline2"`.
///
/// Plain strings produce [StrLit]. Strings with `\(expr)` interpolation
/// produce [StringInterp]. Adjacent literal parts are collapsed.
/// Tolerant closing quote for REPL completion.
final Parser<ParseError, LamExpr> _stringLit = _lex(
  char('"')
      .skipThen(_stringPart.many)
      .thenSkip(_closeQuote)
      .map((parts) {
        if (parts.isEmpty) return const StrLit('') as LamExpr;
        if (parts.length == 1 && parts[0] is StrLit) return parts[0];
        if (parts.every((p) => p is StrLit)) {
          return StrLit(parts.cast<StrLit>().map((s) => s.value).join())
              as LamExpr;
        }
        return StringInterp(parts) as LamExpr;
      })
      .named('string'),
);

final Parser<ParseError, LamExpr> _boolLit = _lex(
  keywords<LamExpr>({
    'true': const BoolLit(true),
    'false': const BoolLit(false),
  }),
).named('boolean');

final Parser<ParseError, LamExpr> _nullLit = _lex(
  string('null').as<LamExpr>(const NullLit()),
).named('null');

/// `.field` → Field, `.` alone → Identity.
/// No whitespace allowed between `.` and field name, but trailing whitespace
/// is consumed so subsequent operators can match.
final Parser<ParseError, LamExpr> _dotField = _lex(
  char('.')
      .skipThen(_identNoWs.optional)
      .map(
        (name) =>
            name != null ? Field(name) as LamExpr : const Identity() as LamExpr,
      ),
);

final Parser<ParseError, LamExpr> _parenExpr = _sym(
  '(',
).skipThen(defer(() => _expr)).thenSkip(_closeParen);

/// A single character of a JSON-string key. Must match `_stringLit`'s
/// escape vocabulary so the two spellings can never disagree on what
/// characters a key may carry. Interpolation (`\(...)`) is rejected
/// with a clear message — the construction grammar accepts any string
/// literal as a key, but key position is not an expression position.
final Parser<ParseError, String> _stringKeyChar =
    string(r'\(').flatMap(
      (_) => failure<ParseError, String>(
        CustomError(
          'string interpolation \\(...) is not allowed in object key '
          'position; build interpolated keys via from_entries on a list '
          'of {key, value} maps',
          Location.zero,
        ),
      ),
    ) |
    string(r'\\').as<String>(r'\') |
    string(r'\"').as<String>('"') |
    string(r'\n').as<String>('\n') |
    string(r'\t').as<String>('\t') |
    satisfy((c) => c != '"' && c != r'\' && c != '\n', 'string char');

/// JSON-string key for object construction: `"name"`, `"x-axis"`,
/// `"with spaces"`. Lexed (consumes trailing whitespace). Returns the
/// raw key string. Mirrors `_stringLit` minus interpolation; key
/// position is structurally not an expression position so a static
/// string is the only sensible thing.
final Parser<ParseError, String> _stringKey = _lex(
  char(
    '"',
  ).skipThen(_stringKeyChar.many).thenSkip(_closeQuote).map((cs) => cs.join()),
);

/// A single entry: either `key: expr`, or shorthand `name`
/// (= `name: .name`). Shorthand only applies to bare identifiers —
/// `{"name"}` is intentionally not supported because it would conflict
/// with treating the JSON-string as a value-with-defaulted-key.
final Parser<ParseError, (String, LamExpr)> _objEntry =
    _lex(_identNoWs).flatMap(
      (key) =>
          _sym(':').skipThen(defer(() => _expr)).map((val) => (key, val)) |
          succeed<ParseError, (String, LamExpr)>((key, Field(key))),
    ) |
    _stringKey.flatMap(
      (key) => _sym(':').skipThen(defer(() => _expr)).map((val) => (key, val)),
    );

/// Object constructor: `{expr}`, `{a: 1, b: 2}`, or `{a: 1,}` — a
/// trailing comma before the closing brace is tolerated, mirroring the
/// list form and common JSON5/JS habit.
final Parser<ParseError, LamExpr> _objConstruct = _sym('{')
    .skipThen(_objEntry.sepBy(_sym(',')))
    .thenSkip(_sym(',').optional)
    .thenSkip(_closeBrace)
    .map((entries) => ObjConstruct(entries) as LamExpr);

/// List literal: `[expr, expr, ...]`, `[]`, or `[1, 2,]` — a trailing
/// comma before the closing bracket is tolerated.
///
/// Parsed at atom level so it never shadows postfix indexing
/// (`expr[i]`), which requires a prior atom to the left of `[`.
final Parser<ParseError, LamExpr> _listConstruct = _sym('[')
    .skipThen(defer(() => _expr).sepBy(_sym(',')))
    .thenSkip(_sym(',').optional)
    .thenSkip(_closeBracket)
    .map((parts) => ListConstruct(parts) as LamExpr);

final Parser<ParseError, LamExpr> _conditional = _sym('if')
    .skipThen(_innerExpr)
    .flatMap(
      (cond) => _sym('then')
          .skipThen(_innerExpr)
          .flatMap(
            (then_) => _sym('else')
                .recover(succeed(''))
                .skipThen(_innerExpr)
                .map((else_) => Conditional(cond, then_, else_) as LamExpr),
          ),
    )
    .named('conditional');

/// Base expression.
///
/// `_pipeOp` is admitted here so ops like `has("k")`, `length`, `keys` work
/// as bare expressions with implicit `.` input — i.e. `has("k")` is parsed
/// as sugar for `. | has("k")`, and `map(has("k"))` Just Works. Placed last
/// so op keywords never shadow other `_atom` alternatives (object shorthand
/// `{length}`, field access `.length`, string interpolation `"\(length)"`).
final Parser<ParseError, LamExpr> _atom =
    _number |
    _stringLit |
    _boolLit |
    _nullLit |
    _conditional |
    _objConstruct |
    _listConstruct |
    _parenExpr |
    _dotField |
    _pipeOp;

/// Tolerant inner expression - recovers with [Identity] when empty.
///
/// Used inside parameterized pipe ops so `filter(` without an expression
/// produces a [Partial] result (for REPL completion) instead of failing.
final Parser<ParseError, LamExpr> _innerExpr = defer(
  () => _expr,
).recover(succeed(const Identity()));

/// Tolerant closing paren - recovers when `)` is missing.
///
/// Produces a [Partial] result (for REPL completion) instead of failing.
final Parser<ParseError, String> _closeParen = _sym(')').recover(succeed(''));

/// Tolerant closing bracket - recovers when `]` is missing.
final Parser<ParseError, String> _closeBracket = _sym(']').recover(succeed(''));

/// Tolerant closing brace - recovers when `}` is missing.
final Parser<ParseError, String> _closeBrace = _sym('}').recover(succeed(''));

/// Parameterized pipe op: `name(expr)` with tolerant inner and close.
///
/// [astName] is the canonical op name written into [BuiltinPipeOp];
/// [synName] is the keyword the parser matches in the source. They
/// differ for jq-idiom aliases (e.g. parser sees `tonumber`, AST says
/// `to_number`). For canonical ops the two are equal.
Parser<ParseError, LamExpr> _paramOp(String synName, String astName) =>
    _sym(synName)
        .skipThen(_sym('('))
        .skipThen(_innerExpr)
        .thenSkip(_closeParen)
        .map((inner) => BuiltinPipeOp(astName, [inner]));

/// `as(format)` parser: shape-directed bridge to an output format.
///
/// Accepts the known [OutputFormat] names (`json`, `yaml`, `toml`,
/// `csv`, `tsv`, `hcl`). The argument is a closed set at parse time,
/// so unknown format names are rejected with a parse error.
final Parser<ParseError, LamExpr> _asOp = _sym('as')
    .skipThen(_sym('('))
    .skipThen(
      keywords<OutputFormat>({
        for (final fmt in OutputFormat.values) fmt.name: fmt,
      }).named('output format'),
    )
    .thenSkip(_ws)
    .thenSkip(_closeParen)
    .map<LamExpr>(As.new);

/// The pipe-op parser.
///
/// Built by iterating over [shape_ops.pipeOpSpecs] (longest-name-first,
/// so `sort_by` is tried before `sort`). Each spec contributes one
/// alternative whose shape depends on [shape_ops.PipeOpParseKind]:
///
/// - `zeroArg` → `_kw(name).as(BuiltinPipeOp(name, const []))`
/// - `oneArg`  → `_paramOp(name, name)` (builds `BuiltinPipeOp(name, [arg])`)
/// - `custom`  → hand-written rule (currently only `as(fmt)`, which
///   takes a closed keyword set rather than an arbitrary expression).
///
/// Adding a new non-custom op requires only a new spec in
/// `pipe_ops.dart`; the parser picks it up automatically. Custom ops
/// still need an explicit rule here.
final Parser<ParseError, LamExpr> _pipeOp = _buildPipeOp();

/// jq-ism aliases: names agents reach for that map cleanly to an
/// existing Lambë op. Registered at the parser layer so shape/eval
/// stay unaware. Canonical name is what `--print-shape` / `--explain`
/// emit; these just let jq-trained agents land the query.
///
/// Only entries whose jq semantics match an existing Lambë op exactly
/// belong here. `select` deliberately stays out — `select(p)` is only
/// valid inside `filter(...)` in Lambë and an alias would mislead;
/// `_jqIdiomHint` already steers users to `filter`. `paths`,
/// `recurse`, etc. need pattern hints, not aliases.
const Map<String, String> _jqAliases = {'tonumber': 'to_number', 'add': 'sum'};

Parser<ParseError, LamExpr> _buildPipeOp() {
  final alternatives = <Parser<ParseError, LamExpr>>[];
  for (final spec in shape_ops.pipeOpSpecs) {
    switch (spec.parseKind) {
      case shape_ops.PipeOpParseKind.zeroArg:
        alternatives.add(
          _kw(spec.name).as<LamExpr>(BuiltinPipeOp(spec.name, const [])),
        );
      case shape_ops.PipeOpParseKind.oneArg:
        alternatives.add(_paramOp(spec.name, spec.name));
      case shape_ops.PipeOpParseKind.custom:
        // Handled below.
        break;
    }
  }
  // Custom ops: hand-written rules, in the order the grammar wants
  // to try them. Currently just `as(fmt)`.
  alternatives.add(_asOp);
  // jq-idiom aliases. Registered last so a canonical spec always wins
  // the parse; the alias only fires when nothing else matches.
  for (final entry in _jqAliases.entries) {
    final canonical = shape_ops.pipeOpInfoForName(entry.value);
    if (canonical == null) continue;
    switch (canonical.parseKind) {
      case shape_ops.PipeOpParseKind.zeroArg:
        alternatives.add(
          _kw(entry.key).as<LamExpr>(BuiltinPipeOp(canonical.name, const [])),
        );
      case shape_ops.PipeOpParseKind.oneArg:
        alternatives.add(_paramOp(entry.key, canonical.name));
      case shape_ops.PipeOpParseKind.custom:
        break;
    }
  }
  return alternatives.reduce((a, b) => a | b);
}

/// The full pipe op parser, named for error messages.
final Parser<ParseError, LamExpr> _namedPipeOp = _pipeOp.named(
  'pipeline operation',
);

/// Pipeline operator `|` - must not match `||`.
final Parser<ParseError, String> _pipe = _lex(
  string('|').thenSkip(char('|').notFollowedBy),
);

/// A single postfix suffix, parsed as a function that wraps the
/// already-parsed left expression. A left-recursive postfix chain
/// (`postfix SUFFIX | atom`) is equivalent to an atom followed by zero or
/// more such suffixes folded left-to-right, which is how [_postfix] is built —
/// the standard LR-free rewrite, avoiding `rule()`/Warth seed-growth.
///
/// Branch order is significant: the `_sym('[')`-prefixed slice is tried before
/// index, relying on rumil's `|` backtracking after a consumed `[` (a bare
/// `[expr]` fails the slice branch at the missing `:` and retries as index).
final Parser<ParseError, LamExpr Function(LamExpr)> _postfixSuffix =
    _pipe
        .skipThen(_namedPipeOp | _atom)
        .map<LamExpr Function(LamExpr)>((op) => (e) => Pipe(e, op)) |
    char('.')
        .skipThen(_identNoWs)
        .thenSkip(_ws)
        .map<LamExpr Function(LamExpr)>((f) => (e) => Access(e, f)) |
    _sym('[').skipThen(
      defer(() => _expr).optional.flatMap<LamExpr Function(LamExpr)>(
        (start) => _sym(':')
            .skipThen(defer(() => _expr).optional)
            .thenSkip(_closeBracket)
            .map<LamExpr Function(LamExpr)>(
              (end) => (e) => Slice(e, start, end),
            ),
      ),
    ) |
    _sym('[')
        .skipThen(_innerExpr)
        .thenSkip(_closeBracket)
        .map<LamExpr Function(LamExpr)>((i) => (e) => Index(e, i));

/// Postfix chain: an atom followed by zero or more suffixes (`| op`,
/// `.field`, `[index]`, `[slice]`), folded left-to-right onto the atom.
///
/// This replaces an earlier `rule()`/Warth-seed-growth definition. The fold is
/// the standard LR-free form for a left-recursive postfix chain: it produces
/// byte-for-byte identical ASTs (verified against the old form over a stress
/// corpus) and parses real queries ~1.3–1.6x faster, since it iterates with
/// `many` instead of re-running a growing seed per input position.
final Parser<ParseError, LamExpr> _postfix = _atom.flatMap(
  (base) => _postfixSuffix.many.map(
    (suffixes) => suffixes.fold(base, (acc, wrap) => wrap(acc)),
  ),
);

/// `/` must not match the first `/` of `//` (alternative operator). Other
/// single-char ops don't have a longer variant that would be ambiguous at
/// the binary-operator level, so only `/` needs a notFollowedBy guard.
final Parser<ParseError, String> _divSym = _lex(
  string('/').thenSkip(char('/').notFollowedBy),
);

/// Lambë's symbol parser routing: `/` requires a not-followed-by guard
/// so it doesn't shadow the `//` alternative; everything else is a
/// whitespace-tolerant `_sym(...)`.
Parser<ParseError, String> _opSym(String s) => s == '/' ? _divSym : _sym(s);

/// Single Pratt parse covering prefix unary, the six binary precedence
/// levels supplied by [cFamilyPrecedence], plus Lambë extensions: the
/// right-associative `//` alternative at the bottom, and the keyword
/// aliases `and` / `or`. The conditional (`if/then/else`) is parsed
/// inside `_atom` rather than as a Pratt operator because its
/// three-branch shape doesn't fit infix dispatch.
final Parser<ParseError, LamExpr> _operators = pratt<LamExpr>(_postfix, [
  // Alternative (right-associative, below `||`).
  InfixRight(_sym('//'), 5, Alternative.new),
  // Standard C-family operators.
  ...cFamilyPrecedence<LamExpr>(
    sym: _opSym,
    binary: BinaryOp.new,
    unary: UnaryOp.new,
  ),
  // Lambë-specific keyword aliases for && / ||. _kw enforces a word
  // boundary so `.andy` / `.orbit` keep tokenizing as identifiers.
  InfixLeft(_kw('and'), 20, (LamExpr a, LamExpr b) => BinaryOp('&&', a, b)),
  InfixLeft(_kw('or'), 10, (LamExpr a, LamExpr b) => BinaryOp('||', a, b)),
]);

final Parser<ParseError, LamExpr> _expr = _operators;
