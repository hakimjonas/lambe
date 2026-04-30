/// Tab completion for the Lambé REPL.
///
/// The completer uses [parsePartial] with `.recover()` to obtain the
/// AST of a valid prefix (including inner expressions of parameterized
/// pipe ops), then resolves the completion context by walking that AST
/// over an inferred [Shape] tree. Unparsed-remainder classification
/// uses small Rumil parsers (no regex), so whitespace handling is
/// uniform across space, tab, CR, and LF.
///
/// Completion cost is bounded by the structural depth of the input
/// data and the size of the query, not by the number of elements in
/// the input. [shapeOf] samples lists on entry and [inferShape]
/// recurses over AST nodes only, so queries against very large
/// collections still complete in constant time.
library;

import 'package:rumil/rumil.dart';

import '../lambe.dart';
import 'parser.dart' as parser_;

/// Completion result: the half-open range `[start, end)` in the
/// original input that should be replaced with a chosen candidate,
/// and the list of [candidates].
///
/// Callers splice with `text.replaceRange(start, end, candidate)`.
/// The range ends at the last non-whitespace character of the user's
/// partial token, not at the cursor — so trailing whitespace typed
/// after a complete token is preserved on accept.
///
/// When [candidates] is empty, [start] and [end] both equal the
/// cursor position; no splice should occur.
typedef Completions = ({int start, int end, List<String> candidates});

/// All pipeline operation names, sorted alphabetically.
///
/// Re-exported from the parser (the canonical source of truth).
const pipelineOps = parser_.pipeOpNames;

/// REPL command names, sorted alphabetically.
const _replCommands = <String>[
  'help',
  'history',
  'load',
  'pretty',
  'q',
  'quit',
  'raw',
  'schema',
  'to',
];

/// Output format names for `:to` command completion.
const _outputFormats = <String>['csv', 'hcl', 'json', 'toml', 'tsv', 'yaml'];

/// Identifier: letter or underscore, then alphanumerics and underscores.
///
/// Re-derives the parser's `_identNoWs` rather than importing a
/// private name.
final Parser<ParseError, String> _ident = (letter() | char('_'))
    .zip((alphaNum() | char('_')).many)
    .map((pair) => pair.$1 + pair.$2.join());

/// Raw whitespace: space, tab, carriage return, or newline.
final Parser<ParseError, void> _wsRaw = satisfy(
  (c) => c == ' ' || c == '\t' || c == '\r' || c == '\n',
  'whitespace',
).many.as<void>(null);

/// Pipe-op context: `|` then optional whitespace then optional
/// partial op name then optional trailing whitespace then end-of-input.
///
/// Yields `(partialStart, partial)` where `partialStart` is the offset
/// within the parsed remainder at which the replacement begins (the
/// first character after the `|` and its whitespace). The partial is
/// `''` when the user has typed only `|` or `| `.
final Parser<ParseError, (int, String)> _pipeCtx = char('|')
    .skipThen(_wsRaw)
    .skipThen(position<ParseError>())
    .zip(_ident.optional)
    .thenSkip(_wsRaw)
    .thenSkip(eof())
    .map((pair) => (pair.$1, pair.$2 ?? ''));

/// Field-tail context: `.` then optional partial field name then
/// optional trailing whitespace then end-of-input.
///
/// Yields `(dotOffset, partial)` where `dotOffset` is the offset of
/// the `.` within the parsed remainder.
final Parser<ParseError, (int, String)> _fieldTailCtx = position<ParseError>()
    .thenSkip(char('.'))
    .zip(_ident.optional)
    .thenSkip(_wsRaw)
    .thenSkip(eof())
    .map((pair) => (pair.$1, pair.$2 ?? ''));

/// Compute tab completions for [text] at [cursor] position against [data].
///
/// Uses [parsePartial] to parse the valid expression prefix (with
/// `.recover()` preserving inner expressions in pipe ops), then classifies
/// the unparsed remainder (pipe-op context or field-tail context) via
/// small Rumil parsers. Falls through to AST-tail-based completion when
/// the remainder classifies as neither.
///
/// Contract: the returned `start`/`end` delimit the range in [text]
/// that the caller should replace with the chosen candidate. `end` is
/// positioned at the last non-whitespace character of the partial
/// token, so trailing whitespace between the token and the cursor is
/// preserved on accept. When `candidates` is empty, `start` and `end`
/// both equal [cursor] and no splice should occur.
Completions complete(String text, int cursor, Object? data) {
  final before = text.substring(0, cursor);

  if (before.startsWith(':')) return _completeCommand(before);

  final result = parser_.parsePartial(before);
  final ast = result.valueOrNull;
  final consumed = switch (result) {
    Success(:final consumed) => consumed,
    Partial(:final consumed) => consumed,
    Failure() => 0,
  };

  // `parsePartial` wraps `_expr` in `_ws ... _ws`, so `consumed` may
  // overshoot the AST's last significant character when the user has
  // typed trailing whitespace. Walk back to recover the true AST-end
  // offset; the AST-tail path computes replacement `start`/`end` from it.
  var astEnd = consumed;
  while (astEnd > 0 && _isWs(before.codeUnitAt(astEnd - 1))) {
    astEnd--;
  }

  final remainder = before.substring(consumed);

  final pipeRes = _pipeCtx.run(remainder);
  if (pipeRes case Success<ParseError, (int, String)>(
    value: (final partialStart, final partial),
  )) {
    final tokenStart = consumed + partialStart;
    return (
      start: tokenStart,
      end: tokenStart + partial.length,
      candidates: <String>[
        for (final op in pipelineOps)
          if (op.startsWith(partial)) op,
      ],
    );
  }

  // Infer the root shape once; downstream resolution walks the AST
  // against this shape rather than against the value.
  final rootShape = shapeOf(data);

  final fieldRes = _fieldTailCtx.run(remainder);
  if (fieldRes case Success<ParseError, (int, String)>(
    value: (final dotOff, final partial),
  ) when dotOff == 0) {
    final dotPos = consumed + dotOff;
    return _fieldsOf(_resolveTarget(ast, rootShape), partial, dotPos);
  }

  if (ast != null) {
    return _completionContext(ast, astEnd, rootShape);
  }

  return (start: cursor, end: cursor, candidates: <String>[]);
}

bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

Completions _completeCommand(String before) {
  if (before.startsWith(':to ')) {
    final prefix = before.substring(4);
    return (
      start: 4,
      end: 4 + prefix.length,
      candidates: <String>[
        for (final f in _outputFormats)
          if (f.startsWith(prefix)) f,
      ],
    );
  }
  final partial = before.substring(1);
  return (
    start: 1,
    end: 1 + partial.length,
    candidates: <String>[
      for (final cmd in _replCommands)
        if (cmd.startsWith(partial)) cmd,
    ],
  );
}

/// Walk the AST to find the innermost completion context.
///
/// [astEnd] is the offset in the original input just past the last
/// non-whitespace character of the parsed AST. The tail path uses it
/// to position `start` at the dot preceding the user's partial token,
/// independently of any trailing whitespace the user has typed.
///
/// For [Pipe] nodes whose right-hand side is a parameterized op
/// (`filter`, `map`, and so on), this recurses into the inner
/// expression against the element shape of the pipe input. A query
/// such as `.users | filter(.address.ci` resolves the trailing
/// identifier against the shape of one user's `address`.
Completions _completionContext(LamExpr ast, int astEnd, Shape inputShape) {
  if (ast is Pipe) {
    final inner = _innerExpr(ast.op);
    if (inner != null) {
      final collection = inferShape(ast.input, inputShape);
      if (collection is SList) {
        return _completionContext(inner, astEnd, collection.element);
      }
      return (start: astEnd, end: astEnd, candidates: <String>[]);
    }
  }
  return _completeAstTail(ast, astEnd, inputShape);
}

/// Complete fields based on the AST tail node.
///
/// [Identity] yields all fields. [Field] matches by prefix. [Access]
/// infers the target shape and completes the trailing field. [BinaryOp]
/// and [UnaryOp] recurse into the right-most branch, so a tab in
/// `.users | filter(.age > 20 && .na<TAB>)` resolves against the
/// element shape.
Completions _completeAstTail(
  LamExpr ast,
  int astEnd,
  Shape inputShape,
) => switch (ast) {
  Identity() => _fieldsOf(inputShape, '', astEnd - 1),
  Field(:final name) => _fieldsOf(inputShape, name, astEnd - name.length - 1),
  Access(:final target, :final field) => _fieldsOf(
    inferShape(target, inputShape),
    field,
    astEnd - field.length - 1,
  ),
  BinaryOp(:final right) => _completeAstTail(right, astEnd, inputShape),
  UnaryOp(:final operand) => _completeAstTail(operand, astEnd, inputShape),
  Conditional(:final then_, :final else_) =>
    else_ is Identity
        ? _completeAstTail(then_, astEnd, inputShape)
        : _completeAstTail(else_, astEnd, inputShape),
  StringInterp(:final parts) when parts.isNotEmpty => _completeAstTail(
    parts.last,
    astEnd,
    inputShape,
  ),
  _ => (start: astEnd, end: astEnd, candidates: <String>[]),
};

/// Return field name completions from [target] starting with [partial].
///
/// The [dotPos] is the position of the `.` in the input, used as the
/// replacement start. The replacement end is just past the last char
/// of the partial token (`dotPos + 1 + partial.length`). Only [SMap]
/// shapes carry field names; any other shape (including [SAny])
/// produces no field candidates.
Completions _fieldsOf(Shape target, String partial, int dotPos) {
  final tokenEnd = dotPos + 1 + partial.length;
  if (target is! SMap) {
    return (start: tokenEnd, end: tokenEnd, candidates: <String>[]);
  }
  final matching =
      target.fields.keys.where((k) => k.startsWith(partial)).toList()..sort();
  return (
    start: dotPos,
    end: tokenEnd,
    candidates: <String>[for (final k in matching) '.$k'],
  );
}

/// Resolve the target shape for field completion, walking into [Pipe]
/// nodes whose right-hand side is a parameterized op.
///
/// For such pipes this infers the element shape of the pipe input and
/// walks the inner expression against it. A query like
/// `.users | map(.address.` resolves the trailing `.` against a single
/// user's `address` shape rather than the pipeline result shape.
Shape _resolveTarget(LamExpr? ast, Shape inputShape) {
  if (ast == null) return inputShape;
  if (ast is Pipe) {
    final inner = _innerExpr(ast.op);
    if (inner != null) {
      final collection = inferShape(ast.input, inputShape);
      if (collection is SList) {
        return inferShape(inner, collection.element);
      }
      return const SAny();
    }
  }
  return inferShape(ast, inputShape);
}

/// Extract the inner expression from a parameterized pipe operation.
///
/// Returns `null` for simple (no-arg) ops like [SortOp], [ReverseOp],
/// etc. and for non-operation expressions like [ObjConstruct].
LamExpr? _innerExpr(LamExpr op) => switch (op) {
  FilterOp(:final predicate) => predicate,
  MapOp(:final transform) => transform,
  SortByOp(:final key) => key,
  GroupByOp(:final key) => key,
  UniqueByOp(:final key) => key,
  FilterValuesOp(:final predicate) => predicate,
  MapValuesOp(:final transform) => transform,
  FilterKeysOp(:final predicate) => predicate,
  HasOp(:final key) => key,
  _ => null,
};
