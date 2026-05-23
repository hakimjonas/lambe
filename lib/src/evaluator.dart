/// Query evaluator. Walks the AST over `Object?` JSON values.
library;

import 'package:rumil_expressions/rumil_expressions.dart'
    show applyBinaryOp, applyUnaryOp, asBool, typeName;

import 'ast.dart';
import 'errors.dart';
import 'output_format.dart';
import 'shape/check.dart';
import 'shape/pipe_ops.dart';
import 'shape/shape.dart';

/// Evaluate a [LamExpr] AST against a JSON [ctx] value.
///
/// The context flows through the expression: `.` returns it, `.field` accesses
/// a field on it, pipeline operations transform it.
///
/// **Null propagation:** navigation operations (field access, indexing,
/// pipeline) propagate `null` - if the target is absent, the result is absent.
/// Computation operations (arithmetic, comparison, conditionals) throw on
/// `null` - using a missing value in a calculation is a type error.
Object? evaluate(LamExpr expr, Object? ctx) => switch (expr) {
  Identity() => ctx,
  Field(:final name) => _field(ctx, name),
  NumLit(:final value) => value,
  StrLit(:final value) => value,
  BoolLit(:final value) => value,
  NullLit() => null,
  Access(:final target, :final field) => _field(evaluate(target, ctx), field),
  Index(:final target, :final index) => _index(
    evaluate(target, ctx),
    evaluate(index, ctx),
  ),
  Pipe(:final input, :final op) => _pipe(evaluate(input, ctx), op),
  UnaryOp(:final op, :final operand) => applyUnaryOp(
    op,
    evaluate(operand, ctx),
  ),
  BinaryOp(:final op, :final left, :final right) => _binaryOp(
    op,
    evaluate(left, ctx),
    evaluate(right, ctx),
  ),
  // Duplicate keys: later entries silently override earlier ones (Dart
  // map literal semantics). The parser does not reject duplicates; users
  // wanting strictness can validate the AST.
  ObjConstruct(:final entries) => {
    for (final (key, valExpr) in entries) key: evaluate(valExpr, ctx),
  },
  Conditional(:final condition, :final then_, :final else_) =>
    asBool(evaluate(condition, ctx), 'if')
        ? evaluate(then_, ctx)
        : evaluate(else_, ctx),
  Alternative(:final left, :final right) => _alternative(left, right, ctx),
  ListConstruct(:final parts) => [for (final p in parts) evaluate(p, ctx)],
  StringInterp(:final parts) => _interpolate(parts, ctx),
  Slice(:final target, :final start, :final end) => _slice(
    evaluate(target, ctx),
    start,
    end,
    ctx,
  ),
  BuiltinPipeOp() => evalBuiltinPipeOp(expr, ctx, evaluate),
  As(:final target) => _as(ctx, target),
};

/// Evaluate `as(target)`. Returns [ctx] unchanged when its shape is
/// already compatible with [target]. When exactly one curated bridge
/// exists for the mismatch, that bridge is evaluated against [ctx] and
/// its result returned. When no curated bridge exists, or when more
/// than one would apply, throws [QueryError] listing the candidates.
Object? _as(Object? ctx, OutputFormat target) {
  final report = canWriteAs(ctx, target);
  if (report is Writable) return ctx;
  final nw = report as NotWritable;
  if (nw.suggestions.isEmpty) {
    throw QueryError(
      'as(${target.name}): no known bridge from '
      '${renderShape(nw.got)} to ${target.name}. ',
    );
  }
  if (nw.suggestions.length > 1) {
    final listing = nw.suggestions
        .map((r) => '  | ${r.display}    # ${r.explanation}')
        .join('\n');
    throw QueryError(
      'as(${target.name}): ambiguous bridge from '
      '${renderShape(nw.got)}. Pick one explicitly:\n$listing',
    );
  }
  return evaluate(nw.suggestions.first.template, ctx);
}

Object? _field(Object? target, String name) {
  if (target == null) return null;
  if (target is Map<String, Object?>) return target[name];
  throw QueryError('Cannot access .$name on ${typeName(target)}');
}

Object? _index(Object? target, Object? idx) => switch (target) {
  null => null,
  List<Object?>() when idx is num => () {
    final i = idx.toInt();
    final resolved = i < 0 ? target.length + i : i;
    if (resolved < 0 || resolved >= target.length) return null;
    return target[resolved];
  }(),
  List<Object?>() =>
    throw QueryError('Cannot index list with ${typeName(idx)}'),
  Map<String, Object?>() when idx is String => target[idx],
  Map<String, Object?>() =>
    throw QueryError('Cannot index map with ${typeName(idx)}'),
  // String single-char indexing mirrors slice semantics: `.name[0]`
  // returns a one-character substring, matching how `.name[0:1]` already
  // worked. Out-of-range returns null (same convention as list
  // indexing).
  String() when idx is num => () {
    final i = idx.toInt();
    final resolved = i < 0 ? target.length + i : i;
    if (resolved < 0 || resolved >= target.length) return null;
    return target.substring(resolved, resolved + 1);
  }(),
  String() => throw QueryError('Cannot index string with ${typeName(idx)}'),
  _ => throw QueryError('Cannot index ${typeName(target)}'),
};

Object? _pipe(Object? input, LamExpr op) {
  if (input == null) return null;
  return evaluate(op, input);
}

/// Evaluate `left // right`: returns `left`'s value if non-null,
/// otherwise `right`'s value.
///
/// `//` is a null-fallback, not an error-handler. If `left` throws
/// (e.g. a type error during evaluation), the throw propagates without
/// trying `right`. To rescue from errors, use shape-checking facilities
/// (e.g. `filter(has("foo")) | .foo` instead of `.foo // ...`).
///
/// `right` is only evaluated on null fallback, so
/// `.a // someExpensiveFallback` pays nothing when `.a` hits.
Object? _alternative(LamExpr left, LamExpr right, Object? ctx) {
  final primary = evaluate(left, ctx);
  if (primary != null) return primary;
  return evaluate(right, ctx);
}

/// Lambé's binary-op wrapper. Intercepts `+` on two lists for
/// concatenation; delegates everything else to rumil_expressions'
/// scalar dispatcher. A mixed list/scalar `+` is a type error —
/// Lambé's strictness stance over silent lifting.
Object _binaryOp(String op, Object? l, Object? r) {
  if (op == '+' && l is List<Object?> && r is List<Object?>) {
    return [...l, ...r];
  }
  if (op == '+' && (l is List<Object?>) != (r is List<Object?>)) {
    throw QueryError(
      '+: cannot mix list with ${typeName(r is List ? l : r)}; '
      'coerce one side explicitly.',
    );
  }
  return applyBinaryOp(op, l, r);
}

String _interpolate(List<LamExpr> parts, Object? ctx) {
  final buffer = StringBuffer();
  for (final part in parts) {
    final value = evaluate(part, ctx);
    buffer.write(value ?? 'null');
  }
  return buffer.toString();
}

Object? _slice(
  Object? target,
  LamExpr? startExpr,
  LamExpr? endExpr,
  Object? ctx,
) => switch (target) {
  null => null,
  List<Object?>() => () {
    final len = target.length;
    final start = _resolveSliceIndex(startExpr, ctx, len, 0);
    final end = _resolveSliceIndex(endExpr, ctx, len, len);
    if (start >= end || start >= len) return <Object?>[];
    return target.sublist(start.clamp(0, len), end.clamp(0, len));
  }(),
  String() => () {
    final len = target.length;
    final start = _resolveSliceIndex(startExpr, ctx, len, 0);
    final end = _resolveSliceIndex(endExpr, ctx, len, len);
    if (start >= end || start >= len) return '';
    return target.substring(start.clamp(0, len), end.clamp(0, len));
  }(),
  _ => throw QueryError('Cannot slice ${typeName(target)}'),
};

int _resolveSliceIndex(
  LamExpr? expr,
  Object? ctx,
  int length,
  int defaultValue,
) {
  if (expr == null) return defaultValue;
  final value = evaluate(expr, ctx);
  if (value is num) {
    final i = value.toInt();
    return i < 0 ? length + i : i;
  }
  throw QueryError('Slice index must be a number, got ${typeName(value)}');
}
