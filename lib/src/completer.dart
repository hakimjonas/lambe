/// Tab completion for the Lambé REPL.
///
/// Uses [parsePartial] with `.recover()` from the Rumil-based parser to get
/// the full AST (including inner expressions in pipe ops), then walks the
/// AST to determine completion context. Regex is only applied to the unparsed
/// remainder (guaranteed free of string literals - the parser consumed those).
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
const _outputFormats = <String>[
  'csv',
  'hcl',
  'json',
  'toml',
  'tsv',
  'xml',
  'yaml',
];

/// Matches a pipe operator followed by a partial op name at end of string.
final _pipeRx = RegExp(r'^\|\s*(\w*)$');

/// Matches a trailing field access (e.g., `.name` or `.`).
final _fieldTailRx = RegExp(r'\.(\w*)$');

/// Compute tab completions for [text] at [cursor] position against [data].
///
/// Uses [parsePartial] to parse the valid expression prefix (with `.recover()`
/// preserving inner expressions in pipe ops), then inspects the AST and any
/// unparsed remainder to determine completion context.
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

  final fMatch = _fieldTailRx.firstMatch(trimmed);
  if (fMatch != null && fMatch.start == 0) {
    final partial = fMatch.group(1)!;
    final dotPos = trimOff + fMatch.start;
    return _fieldsOf(_resolveTarget(ast, data), partial, dotPos);
  }

  if (ast != null) {
    return _completionContext(ast, before, data);
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
/// For [Pipe] nodes with parameterized ops (filter, map, etc.), recursively
/// descends into the inner expression, evaluating the pipe input to get
/// element-level data context. This handles nested fields like
/// `.users | filter(.address.ci` correctly.
Completions _completionContext(LamExpr ast, String before, Object? data) {
  if (ast is Pipe) {
    final inner = _innerExpr(ast.op);
    if (inner != null) {
      final collection = _tryEvalAst(ast.input, data);
      if (collection is List<Object?> && collection.isNotEmpty) {
        return _completionContext(inner, before, collection.first);
      }
      return (start: before.length, candidates: <String>[]);
    }
  }
  return _completeAstTail(ast, before, data);
}

/// Complete fields based on the AST tail node.
///
/// [Identity] completes all fields, [Field] completes by prefix,
/// [Access] evaluates the target and completes the trailing field.
/// For [BinaryOp] and [UnaryOp], recursively descends the right-most
/// branch - this handles `.users | filter(.age > 20 && .na<TAB>)`.
Completions _completeAstTail(
  LamExpr ast,
  String before,
  Object? data,
) => switch (ast) {
  Identity() => _fieldsOf(data, '', before.length - 1),
  Field(:final name) => _fieldsOf(data, name, before.length - name.length - 1),
  Access(:final target, :final field) => _fieldsOf(
    _tryEvalAst(target, data),
    field,
    before.length - field.length - 1,
  ),
  BinaryOp(:final right) => _completeAstTail(right, before, data),
  UnaryOp(:final operand) => _completeAstTail(operand, before, data),
  Conditional(:final then_, :final else_) =>
    else_ is Identity
        ? _completeAstTail(then_, before, data)
        : _completeAstTail(else_, before, data),
  StringInterp(:final parts) when parts.isNotEmpty => _completeAstTail(
    parts.last,
    before,
    data,
  ),
  _ => (start: before.length, candidates: <String>[]),
};

/// Return field name completions from [target] starting with [partial].
///
/// The [dotPos] is the position of the `.` in the input, used as the
/// replacement start.
Completions _fieldsOf(Object? target, String partial, int dotPos) {
  if (target is! Map<String, Object?>) {
    return (start: dotPos + partial.length + 1, candidates: <String>[]);
  }
  final matching =
      target.keys.where((k) => k.startsWith(partial)).toList()..sort();
  return (start: dotPos, candidates: <String>[for (final k in matching) '.$k']);
}

/// Resolve the target for field completion, walking into Pipe/PipeOp.
///
/// When [ast] is a Pipe with a parameterized op, evaluates the inner
/// expression against the first element of the piped collection. This
/// handles cases like `.users | map(.address.` where the trailing `.`
/// should complete on the evaluated `.address`, not the full pipeline result.
Object? _resolveTarget(LamExpr? ast, Object? data) {
  if (ast is Pipe) {
    final inner = _innerExpr(ast.op);
    if (inner != null) {
      final collection = _tryEvalAst(ast.input, data);
      if (collection is List<Object?> && collection.isNotEmpty) {
        return _tryEvalAst(inner, collection.first);
      }
      return null;
    }
  }
  return _tryEvalAst(ast, data);
}

/// Extract the inner expression from a parameterized [PipeOp].
///
/// Returns `null` for simple (no-arg) ops like [SortOp], [ReverseOp], etc.
LamExpr? _innerExpr(PipeOp op) => switch (op) {
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

/// Evaluate a parsed [ast] against [data], returning `null` on any error.
///
/// Unlike the old `_tryEval` which re-parsed a string, this evaluates a
/// pre-parsed AST directly via [eval].
Object? _tryEvalAst(LamExpr? ast, Object? data) {
  if (ast == null) return data;
  try {
    return eval(ast, data);
  } on Exception {
    return null;
  }
}
