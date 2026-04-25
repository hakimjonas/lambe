/// Tab completion for the Lambé REPL.
///
/// The completer uses [parsePartial] with `.recover()` to obtain the
/// AST of a valid prefix (including inner expressions of parameterized
/// pipe ops), then resolves the completion context by walking that AST
/// over an inferred [Shape] tree. Regex is only applied to the
/// unparsed remainder; string literals are already consumed by the
/// parser.
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

/// Completion result: replacement [start] position and [candidates].
typedef Completions = ({int start, List<String> candidates});

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

/// Matches a pipe operator followed by a partial op name at end of string.
final _pipeRx = RegExp(r'^\|\s*(\w*)$');

/// Matches a trailing field access (e.g., `.name` or `.`).
final _fieldTailRx = RegExp(r'\.(\w*)$');

/// Compute tab completions for [text] at [cursor] position against [data].
///
/// Uses [parsePartial] to parse the valid expression prefix (with
/// `.recover()` preserving inner expressions in pipe ops), then inspects
/// the AST and any unparsed remainder to determine completion context.
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

  final remainder = before.substring(consumed);
  final trimmed = remainder.trimLeft();
  final trimOff = consumed + remainder.length - trimmed.length;

  final pipeMatch = _pipeRx.firstMatch(trimmed);
  if (pipeMatch != null) {
    final partial = pipeMatch.group(1)!;
    final start = trimOff + pipeMatch.end - partial.length;
    return (
      start: start,
      candidates: <String>[
        for (final op in pipelineOps)
          if (op.startsWith(partial)) op,
      ],
    );
  }

  // Infer the root shape once; downstream resolution walks the AST
  // against this shape rather than against the value.
  final rootShape = shapeOf(data);

  final fMatch = _fieldTailRx.firstMatch(trimmed);
  if (fMatch != null && fMatch.start == 0) {
    final partial = fMatch.group(1)!;
    final dotPos = trimOff + fMatch.start;
    return _fieldsOf(_resolveTarget(ast, rootShape), partial, dotPos);
  }

  if (ast != null) {
    return _completionContext(ast, before, rootShape);
  }

  return (start: cursor, candidates: <String>[]);
}

Completions _completeCommand(String before) {
  if (before.startsWith(':to ')) {
    final prefix = before.substring(4);
    return (
      start: 4,
      candidates: <String>[
        for (final f in _outputFormats)
          if (f.startsWith(prefix)) f,
      ],
    );
  }
  final partial = before.substring(1);
  return (
    start: 1,
    candidates: <String>[
      for (final cmd in _replCommands)
        if (cmd.startsWith(partial)) cmd,
    ],
  );
}

/// Walk the AST to find the innermost completion context.
///
/// For [Pipe] nodes whose right-hand side is a parameterized op
/// (`filter`, `map`, and so on), this recurses into the inner
/// expression against the element shape of the pipe input. A query
/// such as `.users | filter(.address.ci` resolves the trailing
/// identifier against the shape of one user's `address`.
Completions _completionContext(LamExpr ast, String before, Shape inputShape) {
  if (ast is Pipe) {
    final inner = _innerExpr(ast.op);
    if (inner != null) {
      final collection = inferShape(ast.input, inputShape);
      if (collection is SList) {
        return _completionContext(inner, before, collection.element);
      }
      return (start: before.length, candidates: <String>[]);
    }
  }
  return _completeAstTail(ast, before, inputShape);
}

/// Complete fields based on the AST tail node.
///
/// [Identity] yields all fields. [Field] matches by prefix. [Access]
/// infers the target shape and completes the trailing field. [BinaryOp]
/// and [UnaryOp] recurse into the right-most branch, so a tab in
/// `.users | filter(.age > 20 && .na<TAB>)` resolves against the
/// element shape.
Completions _completeAstTail(LamExpr ast, String before, Shape inputShape) =>
    switch (ast) {
      Identity() => _fieldsOf(inputShape, '', before.length - 1),
      Field(:final name) => _fieldsOf(
        inputShape,
        name,
        before.length - name.length - 1,
      ),
      Access(:final target, :final field) => _fieldsOf(
        inferShape(target, inputShape),
        field,
        before.length - field.length - 1,
      ),
      BinaryOp(:final right) => _completeAstTail(right, before, inputShape),
      UnaryOp(:final operand) => _completeAstTail(operand, before, inputShape),
      Conditional(:final then_, :final else_) =>
        else_ is Identity
            ? _completeAstTail(then_, before, inputShape)
            : _completeAstTail(else_, before, inputShape),
      StringInterp(:final parts) when parts.isNotEmpty => _completeAstTail(
        parts.last,
        before,
        inputShape,
      ),
      _ => (start: before.length, candidates: <String>[]),
    };

/// Return field name completions from [target] starting with [partial].
///
/// The [dotPos] is the position of the `.` in the input, used as the
/// replacement start. Only [SMap] shapes carry field names; any other
/// shape (including [SAny]) produces no field candidates.
Completions _fieldsOf(Shape target, String partial, int dotPos) {
  if (target is! SMap) {
    return (start: dotPos + partial.length + 1, candidates: <String>[]);
  }
  final matching =
      target.fields.keys.where((k) => k.startsWith(partial)).toList()..sort();
  return (start: dotPos, candidates: <String>[for (final k in matching) '.$k']);
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
