/// Shape inference over query expressions.
///
/// [inferShape] takes a [LamExpr] query AST and an input [Shape] (the
/// shape of the value that `.` refers to) and returns the [Shape] the
/// query would produce when evaluated against any value matching the
/// input shape.
///
/// Inference is conservative. When the output shape depends on runtime
/// values that cannot be determined statically (such as dynamic map
/// keys, the subset of elements a filter accepts, or arithmetic with
/// mixed operands), the result is [SAny]. An [SAny] result means the
/// caller cannot prove incompatibility, not that compatibility has been
/// proven.
library;

import '../ast.dart';
import 'pipe_ops.dart';
import 'shape.dart';

/// Tracks whether [inferShape] has been registered as the
/// sub-expression inferrer for `pipe_ops.dart`. Checked on entry to
/// [inferShape]. The first call pays a bool-compare and a function
/// reference; subsequent calls pay only the bool-compare.
///
/// The indirection through [registerSubExprInferrer] keeps
/// `pipe_ops.dart` free of a circular import on this file while
/// still letting op specs recurse into their inner expressions.
bool _inferrerRegistered = false;

/// Infer the shape of [expr] given [input] as the initial context.
///
/// `inputShape` describes what `.` means when the query starts. For a
/// query run at the top level of a document, this is `shapeOf(data)`.
///
/// Pipe ops dispatch through [inferPipeOpShape], which consults the
/// single spec table in `pipe_ops.dart`. Non-op right-hand sides of a
/// pipe (object constructors, literals, bare field accesses, etc.)
/// fall through to the generic expression cases below.
Shape inferShape(LamExpr expr, Shape input) {
  if (!_inferrerRegistered) {
    registerSubExprInferrer(inferShape);
    _inferrerRegistered = true;
  }
  // Pipe ops dispatch through the shared spec table so the completer,
  // `--explain`, and the evaluator agree on per-op behaviour. This
  // includes `as` (the lone typed-argument op) — its `infer` field in
  // the spec table consults the synthesis table directly. Non-op
  // expressions (ObjConstruct, literals, field access, etc.) fall
  // through to the switch below.
  if (pipeOpInfoFor(expr) != null) {
    return inferPipeOpShape(input, expr);
  }
  return switch (expr) {
    Identity() => input,
    NumLit() => const SNum(),
    StrLit() => const SString(),
    BoolLit() => const SBool(),
    NullLit() => const SNull(),

    Field(:final name) => _lookupField(input, name),
    Access(:final target, :final field) => _lookupField(
      inferShape(target, input),
      field,
    ),

    // Indexing into a list yields the element shape (out-of-range reads
    // are null at runtime, matching the evaluator's convention for
    // slices and negative indices — left unchecked here for parity with
    // the historical behavior). Indexing a string with a number yields a
    // one-character substring, but only when the index is in range, so
    // the result is optional. Indexing a map with a string literal
    // resolves the key statically; a literal key that is not in
    // [SMap.fields] reads as null at runtime, so it infers [SNull].
    Index(:final target, :final index) => switch (inferShape(target, input)) {
      SList(element: final e) => e,
      SString() when _plausiblyNum(inferShape(index, input)) => SOptional(
        const SString(),
      ),
      SMap(:final fields) when index is StrLit =>
        fields[index.value] ?? const SNull(),
      SMap() => const SAny(),
      SOptional(:final inner) => _indexOnOptional(inner, index),
      _ => const SAny(),
    },

    Pipe(input: final lhs, :final op) => inferShape(op, inferShape(lhs, input)),

    UnaryOp(:final op) => _unaryOpShape(op, inferShape(expr.operand, input)),
    BinaryOp(:final op, :final left, :final right) => _binaryOpShape(
      op,
      left,
      right,
      input,
    ),

    ObjConstruct(:final entries) => SMap({
      for (final (key, valueExpr) in entries) key: inferShape(valueExpr, input),
    }),

    StringInterp() => const SString(),

    Slice(:final target) => switch (inferShape(target, input)) {
      SList(element: final e) => SList(e),
      SString() => const SString(),
      SOptional(:final inner) => switch (inner) {
        SString() => SOptional(const SString()),
        SList(:final element) => SOptional(SList(element)),
        _ => const SAny(),
      },
      _ => const SAny(),
    },

    // Both branches must agree for the result shape to be known;
    // otherwise the inference widens to [SAny].
    Conditional(:final then_, :final else_) => _joinBranches(
      inferShape(then_, input),
      inferShape(else_, input),
    ),

    // `a // b` is either a's shape (when non-null) or b's. An optional
    // left operand unwraps to its inner shape before joining, since
    // `//` fires exactly on null; the result is optional only when both
    // sides can be null.
    Alternative(:final left, :final right) => _alternativeShape(
      inferShape(left, input),
      inferShape(right, input),
    ),

    // `[e1, e2, ...]` yields `SList(join(parts))`. Empty list literal
    // has no element shape, so widen to `SList(SAny)`.
    ListConstruct(:final parts) =>
      parts.isEmpty
          ? const SList(SAny())
          : SList(parts.map((p) => inferShape(p, input)).reduce(_joinBranches)),

    // Pipe ops are handled above via [pipeOpInfoFor]; reaching this
    // case means the spec table is missing an op AST subtype. Falling
    // through to [SAny] is the safe default.
    _ => const SAny(),
  };
}

Shape _lookupField(Shape context, String name) {
  if (context is SOptional) {
    // Field access through an optional propagates the optional: if
    // the outer value is absent, null propagation returns null for
    // the field access too. So `.field` on SOptional<SMap> yields
    // SOptional<fieldShape>.
    final inner = _lookupField(context.inner, name);
    return SOptional(inner);
  }
  if (context is SMap) {
    return context.fields[name] ?? const SAny();
  }
  // Field access on a non-map value is a runtime error. Inference
  // returns [SAny] so downstream stages are not forced to concrete
  // shapes derived from an impossible path.
  return const SAny();
}

/// Indexing into a value behind an [SOptional]: null propagates, so
/// the result keeps the optionality of the target.
Shape _indexOnOptional(Shape inner, LamExpr index) => switch (inner) {
  SList(element: final e) => SOptional(e),
  SString() => SOptional(const SString()),
  SMap(:final fields) when index is StrLit => SOptional(
    fields[index.value] ?? const SNull(),
  ),
  _ => const SAny(),
};

Shape _unaryOpShape(String op, Shape operand) => switch (op) {
  '-' => _plausiblyNum(operand) ? const SNum() : const SAny(),
  '!' => _plausiblyBool(operand) ? const SBool() : const SAny(),
  _ => const SAny(),
};

Shape _binaryOpShape(String op, LamExpr left, LamExpr right, Shape input) {
  final l = inferShape(left, input);
  final r = inferShape(right, input);
  return switch (op) {
    '+' => _addShape(l, r),
    // The evaluator coerces both operands with `asNum`, so a concrete
    // non-number operand is a guaranteed runtime error, not a number.
    '-' ||
    '*' ||
    '/' ||
    '%' => _plausiblyNum(l) && _plausiblyNum(r) ? const SNum() : const SAny(),
    // `==` / `!=` succeed on any operand pair.
    '==' || '!=' => const SBool(),
    // Ordering comparisons also run through `asNum`: strings, bools,
    // and containers cannot be ordered.
    '<' ||
    '<=' ||
    '>' ||
    '>=' => _plausiblyNum(l) && _plausiblyNum(r) ? const SBool() : const SAny(),
    // The evaluator coerces both operands with `asBool`.
    '&&' || '||' =>
      _plausiblyBool(l) && _plausiblyBool(r) ? const SBool() : const SAny(),
    _ => const SAny(),
  };
}

/// Shape of `l + r`, mirroring the evaluator's dispatch:
///
/// - `list + list` concatenates; the element shape joins.
/// - `list` mixed with a non-list is a type error.
/// - a `string` operand concatenates via `toString` with any non-list
///   scalar (including `null`), so the result is a string.
/// - `number + number` adds numerically.
/// - everything else may be a runtime error and widens to [SAny].
Shape _addShape(Shape l, Shape r) {
  if (l is SList && r is SList) {
    return SList(_joinBranches(l.element, r.element));
  }
  if (l is SList || r is SList) return const SAny();
  if (l is SString || r is SString) {
    // An [SAny] operand may be a list at runtime, which the evaluator
    // rejects for `+`; stay conservative.
    if (l is SAny || r is SAny) return const SAny();
    return const SString();
  }
  if (l is SNum && r is SNum) return const SNum();
  return const SAny();
}

/// Shape of `left // right`: `left` when non-null, else `right`.
///
/// The result is null only when both sides can be null, so optionality
/// survives only when both operands are optional. A definitely-null
/// left always falls through to `right`.
Shape _alternativeShape(Shape left, Shape right) {
  if (left is SNull) return right;
  final lInner = left is SOptional ? left.inner : left;
  final rInner = right is SOptional ? right.inner : right;
  final joined = _joinBranches(lInner, rInner);
  if (joined is SAny) return const SAny();
  final bothOptional = left is SOptional && right is SOptional;
  return bothOptional ? SOptional(joined) : joined;
}

/// True when [shape] may be a number at runtime. [SAny] cannot prove
/// non-numbership, so it counts as plausible.
bool _plausiblyNum(Shape shape) => shape is SNum || shape is SAny;

/// True when [shape] may be a boolean at runtime.
bool _plausiblyBool(Shape shape) => shape is SBool || shape is SAny;

/// Join two shapes into a structural upper bound.
///
/// Equal shapes pass through; otherwise the result widens to [SAny].
/// This is the single point at which inference loses precision.
Shape _joinBranches(Shape a, Shape b) {
  if (a == b) return a;
  return const SAny();
}
