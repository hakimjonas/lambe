/// Query parser. Left-recursive grammar via `rule()`, operator precedence
/// via layered `chainl1` calls.
///
/// Grammar structure (lowest to highest precedence):
///   _expr      = _logicOr             (top-level, lowest precedence)
///   _logicOr   = _logicAnd  chainl1 '||'
///   _logicAnd  = _equality  chainl1 '&&'
///   _equality  = _comparison chainl1 '==' | '!='
///   _comparison = _additive  chainl1 '<' | '>' | '<=' | '>='
///   _additive  = _multiplicative chainl1 '+' | '-'
///   _multiplicative = _unary chainl1 '*' | '/' | '%'
///   _unary     = ('-' | '!') _unary | _postfix
///   _postfix   = rule(                (left-recursive via Warth)
///                  _postfix '|' pipe_op
///                | _postfix '.' ident
///                | _postfix '[' _expr ']'
///                | _atom )
///   _atom      = number | string | bool | null | '(' _expr ')' | dotField
library;

import 'package:rumil/rumil.dart';

import 'ast.dart';

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
/// This is the canonical source of truth for pipe op names. The REPL
/// completer uses this list for tab completion candidates.
const pipeOpNames = <String>[
  'avg',
  'filter',
  'filter_keys',
  'filter_values',
  'first',
  'flatten',
  'from_entries',
  'group_by',
  'has',
  'keys',
  'last',
  'length',
  'map',
  'map_values',
  'max',
  'min',
  'reverse',
  'sort',
  'sort_by',
  'sum',
  'to_entries',
  'unique',
  'unique_by',
  'values',
];

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

/// A single entry: either `name: expr` or shorthand `name` (= `name: .name`).
final Parser<ParseError, (String, LamExpr)> _objEntry = _lex(
  _identNoWs,
).flatMap(
  (key) =>
      _sym(':').skipThen(defer(() => _expr)).map((val) => (key, val)) |
      succeed<ParseError, (String, LamExpr)>((key, Field(key))),
);

final Parser<ParseError, LamExpr> _objConstruct = _sym('{')
    .skipThen(_objEntry.sepBy(_sym(',')))
    .thenSkip(_closeBrace)
    .map((entries) => ObjConstruct(entries) as LamExpr);

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

final Parser<ParseError, LamExpr> _atom =
    _number |
    _stringLit |
    _boolLit |
    _nullLit |
    _conditional |
    _objConstruct |
    _parenExpr |
    _dotField;

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
Parser<ParseError, PipeOp> _paramOp(
  String name,
  PipeOp Function(LamExpr) ctor,
) => _sym(
  name,
).skipThen(_sym('(')).skipThen(_innerExpr).thenSkip(_closeParen).map(ctor);

final Parser<ParseError, PipeOp> _pipeOp =
    _paramOp('filter_values', FilterValuesOp.new) |
    _paramOp('filter_keys', FilterKeysOp.new) |
    _paramOp('filter', FilterOp.new) |
    _paramOp('map_values', MapValuesOp.new) |
    _paramOp('map', MapOp.new) |
    _paramOp('sort_by', SortByOp.new) |
    _kw('sort').as<PipeOp>(const SortOp()) |
    _paramOp('group_by', GroupByOp.new) |
    _paramOp('unique_by', UniqueByOp.new) |
    _kw('unique').as<PipeOp>(const UniqueOp()) |
    _kw('flatten').as<PipeOp>(const FlattenOp()) |
    _kw('reverse').as<PipeOp>(const ReverseOp()) |
    _kw('keys').as<PipeOp>(const KeysOp()) |
    _kw('values').as<PipeOp>(const ValuesOp()) |
    _kw('length').as<PipeOp>(const LengthOp()) |
    _kw('first').as<PipeOp>(const FirstOp()) |
    _kw('last').as<PipeOp>(const LastOp()) |
    _kw('sum').as<PipeOp>(const SumOp()) |
    _kw('avg').as<PipeOp>(const AvgOp()) |
    _kw('min').as<PipeOp>(const MinOp()) |
    _kw('max').as<PipeOp>(const MaxOp()) |
    _paramOp('has', HasOp.new) |
    _kw('to_entries').as<PipeOp>(const ToEntriesOp()) |
    _kw('from_entries').as<PipeOp>(const FromEntriesOp());

/// The full pipe op parser, named for error messages.
final Parser<ParseError, PipeOp> _namedPipeOp = _pipeOp.named(
  'pipeline operation',
);

/// Pipeline operator `|` - must not match `||`.
final Parser<ParseError, String> _pipe = _lex(
  string('|').thenSkip(char('|').notFollowedBy),
);

final Parser<ParseError, LamExpr> _postfix = rule(
  () =>
      defer(() => _postfix).flatMap(
        (e) => _pipe.skipThen(_namedPipeOp).map((op) => Pipe(e, op) as LamExpr),
      ) |
      defer(() => _postfix).flatMap(
        (e) => char('.')
            .skipThen(_identNoWs)
            .thenSkip(_ws)
            .map((f) => Access(e, f) as LamExpr),
      ) |
      defer(() => _postfix).flatMap(
        (e) => _sym('[').skipThen(
          defer(() => _expr).optional.flatMap(
            (start) => _sym(':')
                .skipThen(defer(() => _expr).optional)
                .thenSkip(_closeBracket)
                .map((end) => Slice(e, start, end) as LamExpr),
          ),
        ),
      ) |
      defer(() => _postfix).flatMap(
        (e) => _sym('[')
            .skipThen(_innerExpr)
            .thenSkip(_closeBracket)
            .map((i) => Index(e, i) as LamExpr),
      ) |
      _atom,
);

final Parser<ParseError, LamExpr> _unary =
    (_sym('-').as('-') | _sym('!').as('!')).flatMap(
      (op) =>
          defer(() => _unary).map((operand) => UnaryOp(op, operand) as LamExpr),
    ) |
    _postfix;

Parser<ParseError, LamExpr Function(LamExpr, LamExpr)> _binOp(String op) =>
    _sym(
      op,
    ).as<LamExpr Function(LamExpr, LamExpr)>((l, r) => BinaryOp(op, l, r));

Parser<ParseError, LamExpr Function(LamExpr, LamExpr)> _binOps(
  List<String> ops,
) {
  var p = _binOp(ops.first);
  for (var i = 1; i < ops.length; i++) {
    p = p | _binOp(ops[i]);
  }
  return p;
}

final Parser<ParseError, LamExpr> _multiplicative = _unary.chainl1(
  _binOps(['*', '/', '%']),
);

final Parser<ParseError, LamExpr> _additive = _multiplicative.chainl1(
  _binOps(['+', '-']),
);

final Parser<ParseError, LamExpr> _comparison = () {
  final ops = _binOp('<=') | _binOp('>=') | _binOp('<') | _binOp('>');
  return _additive.chainl1(ops);
}();

final Parser<ParseError, LamExpr> _equality = _comparison.chainl1(
  _binOps(['==', '!=']),
);

final Parser<ParseError, LamExpr> _logicAnd = _equality.chainl1(_binOp('&&'));

final Parser<ParseError, LamExpr> _logicOr = _logicAnd.chainl1(_binOp('||'));

final Parser<ParseError, LamExpr> _expr = _logicOr;
