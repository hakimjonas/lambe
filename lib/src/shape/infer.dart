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
import '../output_format.dart';
import 'check.dart';
import 'pipe_ops.dart';
import 'shape.dart';
import 'synthesize.dart';

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
  // Pipe ops are dispatched through the shared spec table so the
  // completer, `--explain`, and the evaluator agree on per-op
  // behaviour. Non-op expressions (ObjConstruct, literals, field
  // access, etc.) fall through to the switch below.
  final pipeInfo = pipeOpInfoFor(expr);
  if (pipeInfo != null) {
    // `as(target)` needs access to the synthesis table, which lives in
    // this file to avoid importing it from `pipe_ops.dart`. Handle it
    // explicitly rather than teaching the spec table about synthesis.
    if (expr is As) return _asShape(input, expr.target);
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

    // Indexing into a list yields the element shape. Indexing into a
    // map cannot be resolved statically without the runtime key.
    Index(:final target) => switch (inferShape(target, input)) {
      SList(element: final e) => e,
      SMap() => const SAny(),
      _ => const SAny(),
    },

    Pipe(input: final lhs, :final op) => inferShape(op, inferShape(lhs, input)),

    UnaryOp(:final op) => _unaryOpShape(op),
    BinaryOp(:final op) => _binaryOpShape(op),

    ObjConstruct(:final entries) => SMap({
      for (final (key, valueExpr) in entries) key: inferShape(valueExpr, input),
    }),

    StringInterp() => const SString(),

    Slice(:final target) => switch (inferShape(target, input)) {
      SList(element: final e) => SList(e),
      _ => const SAny(),
    },

    // Both branches must agree for the result shape to be known;
    // otherwise the inference widens to [SAny].
    Conditional(:final then_, :final else_) => _joinBranches(
      inferShape(then_, input),
      inferShape(else_, input),
    ),

    // `a // b` is either a's shape (when non-null) or b's. Equal
    // shapes pass through; otherwise widen.
    Alternative(:final left, :final right) => _joinBranches(
      inferShape(left, input),
      inferShape(right, input),
    ),

    // `[e1, e2, ...]` yields `SList(join(parts))`. Empty list literal
    // has no element shape, so widen to `SList(SAny)`.
    ListConstruct(:final parts) => parts.isEmpty
        ? const SList(SAny())
        : SList(parts
            .map((p) => inferShape(p, input))
            .reduce(_joinBranches)),

    // Pipe ops are handled above via [pipeOpInfoFor]; reaching this
    // case means the spec table is missing an op AST subtype. Falling
    // through to [SAny] is the safe default.
    _ => const SAny(),
  };
}

Shape _asShape(Shape input, OutputFormat target) {
  final report = canWriteShapeAs(input, target);
  if (report is Writable) return input;
  final bridges = synthesize(input, target);
  if (bridges.length == 1) return inferShape(bridges.first, input);
  return const SAny();
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

Shape _unaryOpShape(String op) => switch (op) {
  '-' => const SNum(),
  '!' => const SBool(),
  _ => const SAny(),
};

Shape _binaryOpShape(String op) => switch (op) {
  '+' || '-' || '*' || '/' || '%' => const SNum(),
  '==' || '!=' || '<' || '<=' || '>' || '>=' => const SBool(),
  '&&' || '||' => const SBool(),
  _ => const SAny(),
};

/// Join two shapes into a structural upper bound.
///
/// Equal shapes pass through; otherwise the result widens to [SAny].
/// This is the single point at which inference loses precision.
Shape _joinBranches(Shape a, Shape b) {
  if (a == b) return a;
  return const SAny();
}
