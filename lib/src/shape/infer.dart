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
import 'shape.dart';
import 'synthesize.dart';

/// Infer the shape of [expr] given [input] as the initial context.
///
/// `inputShape` describes what `.` means when the query starts. For a
/// query run at the top level of a document, this is `shapeOf(data)`.
Shape inferShape(LamExpr expr, Shape input) => switch (expr) {
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

  // Indexing into a list yields the element shape. Indexing into a map
  // cannot be resolved statically without the runtime key.
  Index(:final target) => switch (inferShape(target, input)) {
    SList(element: final e) => e,
    SMap() => const SAny(),
    _ => const SAny(),
  },

  Pipe(input: final lhs, :final op) => inferShape(op, inferShape(lhs, input)),

  UnaryOp(:final op) => _unaryOpShape(op),
  BinaryOp(:final op) => _binaryOpShape(op),

  KeysOp() => _keysShape(input),
  ValuesOp() => _valuesShape(input),
  LengthOp() => const SNum(),
  FirstOp() || LastOp() => switch (input) {
    SList(element: final e) => e,
    _ => const SAny(),
  },
  SumOp() || AvgOp() => const SNum(),
  MinOp() || MaxOp() => switch (input) {
    SList(element: final e) => e,
    _ => const SAny(),
  },
  SortOp() || ReverseOp() || UniqueOp() || FlattenOp() => input,

  FilterOp() => input,
  MapOp(:final transform) => switch (input) {
    SList(element: final e) => SList(inferShape(transform, e)),
    _ => const SAny(),
  },
  SortByOp() || UniqueByOp() => input,
  GroupByOp() => switch (input) {
    SList(element: final e) => SList(
      SMap({'key': const SAny(), 'values': SList(e)}),
    ),
    _ => const SAny(),
  },

  FilterValuesOp() || FilterKeysOp() => input,
  MapValuesOp(:final transform) => switch (input) {
    SMap(fields: final fields) => SMap({
      for (final MapEntry(:key, :value) in fields.entries)
        key: inferShape(transform, value),
    }),
    _ => const SAny(),
  },

  HasOp() => const SBool(),
  ToEntriesOp() => _toEntriesShape(input),
  FromEntriesOp() => _fromEntriesShape(input),
  ToNumberOp() => const SNum(),
  TypeOp() => const SString(),

  ObjConstruct(:final entries) => SMap({
    for (final (key, valueExpr) in entries) key: inferShape(valueExpr, input),
  }),

  StringInterp() => const SString(),

  Slice(:final target) => switch (inferShape(target, input)) {
    SList(element: final e) => SList(e),
    _ => const SAny(),
  },

  // Both branches must agree for the result shape to be known; otherwise
  // the inference widens to [SAny].
  Conditional(:final then_, :final else_) => _joinBranches(
    inferShape(then_, input),
    inferShape(else_, input),
  ),

  // `as(target)` is a no-op when the input already satisfies the
  // requirement. When exactly one curated bridge exists the output
  // shape is the bridge's output shape. Ambiguous or missing bridges
  // widen to [SAny], since the runtime evaluator will throw.
  As(:final target) => _asShape(input, target),
};

Shape _asShape(Shape input, OutputFormat target) {
  final report = canWriteShapeAs(input, target);
  if (report is Writable) return input;
  final bridges = synthesize(input, target);
  if (bridges.length == 1) return inferShape(bridges.first, input);
  return const SAny();
}

Shape _lookupField(Shape context, String name) {
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

Shape _keysShape(Shape input) => switch (input) {
  SMap() => const SList(SString()),
  SList() => const SList(SNum()),
  _ => const SAny(),
};

Shape _valuesShape(Shape input) => switch (input) {
  SMap(fields: final fields) =>
    fields.isEmpty ? const SList(SAny()) : SList(_joinAll(fields.values)),
  SList() => input,
  _ => const SAny(),
};

Shape _toEntriesShape(Shape input) {
  if (input is SMap) {
    final valueShape =
        input.fields.isEmpty ? const SAny() : _joinAll(input.fields.values);
    return SList(SMap({'key': const SString(), 'value': valueShape}));
  }
  return const SAny();
}

Shape _fromEntriesShape(Shape input) {
  // `from_entries` expects a list of `{key, value}` records. The
  // runtime key strings are not knowable statically, so the resulting
  // map shape carries no known fields. Callers that only check for a
  // map root (such as [canWriteShapeAs] against TOML or HCL) still
  // succeed.
  if (input is SList) {
    return const SMap(<String, Shape>{});
  }
  return const SAny();
}

/// Join two shapes into a structural upper bound.
///
/// Equal shapes pass through; otherwise the result widens to [SAny].
/// This is the single point at which inference loses precision.
Shape _joinBranches(Shape a, Shape b) {
  if (a == b) return a;
  return const SAny();
}

Shape _joinAll(Iterable<Shape> shapes) {
  final iterator = shapes.iterator;
  if (!iterator.moveNext()) return const SAny();
  var acc = iterator.current;
  while (iterator.moveNext()) {
    acc = _joinBranches(acc, iterator.current);
    if (acc is SAny) return acc;
  }
  return acc;
}
