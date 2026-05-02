/// Shape-trace rendering for the `--explain` CLI flag.
///
/// [explain] walks the pipe backbone of a parsed query, applies
/// [inferShape] at each stage, and returns a report of the shape at
/// each stage together with the set of output formats the final shape
/// can be serialized as. It performs static analysis only and does not
/// evaluate the query. An optional initial [Shape] seeds the trace;
/// pass [SAny] when no input data is available.
library;

import '../ast.dart';
import '../output_format.dart';
import 'check.dart';
import 'infer.dart';
import 'shape.dart';

/// A single row in an explain trace.
///
/// A query like `.users | map(.name) | length` produces three stages:
/// one per element of the pipe backbone. Each carries the stage's
/// source string and the shape it produces.
final class ExplainStage {
  /// Rendered source text of this stage's fragment. The first stage
  /// carries the leading expression (for example `.users`). Subsequent
  /// stages are prefixed with `| ` so the trace reads as a pipeline.
  final String source;

  /// The inferred shape produced by the stage, given the shape of its
  /// preceding context.
  final Shape shape;

  /// Creates an [ExplainStage].
  const ExplainStage({required this.source, required this.shape});
}

/// A static-analysis warning attached to an explain report.
///
/// Warnings call out constructs that will evaluate to a trivial result
/// regardless of input, such as a `filter` predicate whose inferred
/// shape is not [SBool] — `filter` requires `== true`, so any non-bool
/// predicate makes the filter always empty.
///
/// [stageIndex] points into [ExplainReport.stages] so a renderer can
/// highlight the offending stage.
final class ExplainWarning {
  /// The stage this warning refers to, as an index into
  /// [ExplainReport.stages].
  final int stageIndex;

  /// One-line human-readable message.
  final String message;

  /// Creates an [ExplainWarning].
  const ExplainWarning({required this.stageIndex, required this.message});
}

/// A full explain report for a query.
final class ExplainReport {
  /// The stages along the pipe backbone, in left-to-right order.
  final List<ExplainStage> stages;

  /// The formats the final shape is writable as.
  final List<OutputFormat> writableAs;

  /// The formats the final shape is *not* writable as.
  final List<OutputFormat> notWritableAs;

  /// Static-analysis warnings attached to individual stages. Empty when
  /// nothing was flagged.
  final List<ExplainWarning> warnings;

  /// Creates an [ExplainReport].
  const ExplainReport({
    required this.stages,
    required this.writableAs,
    required this.notWritableAs,
    this.warnings = const [],
  });
}

/// Produce an [ExplainReport] for [expr] given [inputShape] as the
/// initial context. Pass [SAny] when the input's shape is unknown.
ExplainReport explain(LamExpr expr, Shape inputShape) {
  final backbone = _flattenPipe(expr);
  final stages = <ExplainStage>[];
  final warnings = <ExplainWarning>[];
  var prev = inputShape;
  var ctx = inputShape;
  for (var i = 0; i < backbone.length; i++) {
    final piece = backbone[i];
    final warning = _analyzePredicate(piece, prev);
    if (warning != null) {
      warnings.add(ExplainWarning(stageIndex: i, message: warning));
    }
    ctx = inferShape(piece, ctx);
    stages.add(
      ExplainStage(
        source: i == 0 ? _render(piece) : '| ${_render(piece)}',
        shape: ctx,
      ),
    );
    prev = ctx;
  }

  final writable = <OutputFormat>[];
  final notWritable = <OutputFormat>[];
  for (final fmt in OutputFormat.values) {
    if (canWriteShapeAs(ctx, fmt) is Writable) {
      writable.add(fmt);
    } else {
      notWritable.add(fmt);
    }
  }

  return ExplainReport(
    stages: stages,
    writableAs: writable,
    notWritableAs: notWritable,
    warnings: warnings,
  );
}

/// Detect predicate anti-patterns in parameterized ops.
///
/// `filter`, `filter_values`, and `filter_keys` all reject elements
/// whose predicate does not evaluate to `== true`. Two patterns can
/// prove the predicate will never return `true` and therefore the op
/// will always be empty:
///
/// - The predicate references a field that doesn't exist on the
///   known element shape (e.g. `filter(.missing)` when the element
///   is `SMap<name, age>`). At runtime the field access yields
///   `null`, which never equals `true`.
/// - The predicate's inferred shape is a concrete non-boolean scalar
///   (`SNum`, `SString`, `SList`, `SMap`, `SNull`). Even without an
///   unknown-field match, a predicate that can only return, say, a
///   number is always non-boolean, so `== true` never holds.
///
/// [SBool] and [SAny] are left alone: booleans might be true,
/// unknowns might be true, neither is provably-empty.
///
/// Returns `null` when no warning applies.
String? _analyzePredicate(LamExpr op, Shape inputShape) {
  switch (op) {
    case FilterOp(:final predicate):
      final element = inputShape is SList ? inputShape.element : const SAny();
      return _predicateWarning(predicate, element, 'filter', 'element');
    case FilterValuesOp(:final predicate):
      final value = switch (inputShape) {
        SMap(:final fields) when fields.isNotEmpty => fields.values.reduce(
          (a, b) => a == b ? a : const SAny(),
        ),
        _ => const SAny(),
      };
      return _predicateWarning(predicate, value, 'filter_values', 'value');
    case FilterKeysOp(:final predicate):
      return _predicateWarning(
        predicate,
        const SString(),
        'filter_keys',
        'key',
      );
    default:
      return null;
  }
}

String? _predicateWarning(
  LamExpr predicate,
  Shape context,
  String opName,
  String domain,
) {
  final missing = _missingFieldPath(predicate, context);
  if (missing != null) {
    return 'predicate $missing does not exist on the $domain shape; '
        '$opName will always be empty';
  }
  final predShape = inferShape(predicate, context);
  if (predShape is SBool || predShape is SAny) return null;
  return '$opName predicate has shape ${renderShape(predShape)}; '
      '$opName requires a boolean, so this will always be empty';
}

/// Render `.a.b.c` if [expr] is a [Field]/[Access] chain whose root
/// resolves to a known [SMap] missing a segment in the chain; otherwise
/// `null`.
///
/// Walks left-to-right along a `Field`/`Access` spine, narrowing the
/// context at each step. As soon as a step lands on a known map whose
/// fields don't include the required name, returns the rendered path up
/// to and including that missing segment. [SAny] anywhere along the
/// path disables the check — unknown context means we cannot prove
/// the field is missing.
String? _missingFieldPath(LamExpr expr, Shape context) {
  final segments = <String>[];
  LamExpr cur = expr;
  while (true) {
    if (cur is Field) {
      segments.insert(0, cur.name);
      break;
    }
    if (cur is Access) {
      segments.insert(0, cur.field);
      cur = cur.target;
      continue;
    }
    return null;
  }

  var ctx = context;
  for (var i = 0; i < segments.length; i++) {
    if (ctx is SAny) return null;
    if (ctx is! SMap) return null;
    final name = segments[i];
    if (!ctx.fields.containsKey(name)) {
      final path = segments.sublist(0, i + 1).join('.');
      return '.$path';
    }
    ctx = ctx.fields[name]!;
  }
  return null;
}

/// Flatten a left-associative [Pipe] chain into a list of stages.
///
/// `a | b | c` parses as `Pipe(Pipe(a, b), c)`. Walking the left spine
/// produces `[a, b, c]`. A non-[Pipe] node yields a single-element list.
List<LamExpr> _flattenPipe(LamExpr expr) {
  final stages = <LamExpr>[];
  LamExpr cur = expr;
  while (cur is Pipe) {
    stages.insert(0, cur.op);
    cur = cur.input;
  }
  stages.insert(0, cur);
  return stages;
}

/// Render a [LamExpr] as a human-readable source string.
///
/// Literals and bare ops render to their canonical form. Parameterized
/// ops render as `name(inner)` using a compact rendering of the inner
/// expression. The output is intended for display, not for round-trip
/// through the parser.
String _render(LamExpr expr) => switch (expr) {
  Identity() => '.',
  Field(:final name) => '.$name',
  NumLit(:final value) => '$value',
  StrLit(:final value) => '"$value"',
  BoolLit(:final value) => '$value',
  NullLit() => 'null',
  Access(:final target, :final field) => '${_render(target)}.$field',
  Index(:final target, :final index) => '${_render(target)}[${_render(index)}]',
  Pipe(:final input, :final op) => '${_render(input)} | ${_render(op)}',
  UnaryOp(:final op, :final operand) => '$op${_render(operand)}',
  BinaryOp(:final op, :final left, :final right) =>
    '${_render(left)} $op ${_render(right)}',
  FilterOp(:final predicate) => 'filter(${_render(predicate)})',
  MapOp(:final transform) => 'map(${_render(transform)})',
  SortByOp(:final key) => 'sort_by(${_render(key)})',
  GroupByOp(:final key) => 'group_by(${_render(key)})',
  UniqueByOp(:final key) => 'unique_by(${_render(key)})',
  FilterValuesOp(:final predicate) => 'filter_values(${_render(predicate)})',
  MapValuesOp(:final transform) => 'map_values(${_render(transform)})',
  FilterKeysOp(:final predicate) => 'filter_keys(${_render(predicate)})',
  HasOp(:final key) => 'has(${_render(key)})',
  SortOp() => 'sort',
  ReverseOp() => 'reverse',
  KeysOp() => 'keys',
  ValuesOp() => 'values',
  LengthOp() => 'length',
  FirstOp() => 'first',
  LastOp() => 'last',
  SumOp() => 'sum',
  AvgOp() => 'avg',
  MinOp() => 'min',
  MaxOp() => 'max',
  UniqueOp() => 'unique',
  FlattenOp() => 'flatten',
  ToEntriesOp() => 'to_entries',
  FromEntriesOp() => 'from_entries',
  ToNumberOp() => 'to_number',
  TypeOp() => 'type',
  As(:final target) => 'as(${target.name})',
  ObjConstruct(:final entries) =>
    '{${[for (final (k, v) in entries) '$k: ${_render(v)}'].join(', ')}}',
  StringInterp() => '"<interp>"',
  Slice(:final target, :final start, :final end) =>
    '${_render(target)}[${start == null ? '' : _render(start)}:'
        '${end == null ? '' : _render(end)}]',
  Conditional(:final condition, :final then_, :final else_) =>
    'if ${_render(condition)} then ${_render(then_)} else ${_render(else_)}',
};

/// Render an [ExplainReport] as a plaintext table suitable for stdout.
///
/// Columns: stage source (left, padded) and inferred shape (right).
/// Followed by a summary line listing writable formats.
String renderExplain(ExplainReport report) {
  final buf = StringBuffer();
  var width = 0;
  for (final s in report.stages) {
    if (s.source.length > width) width = s.source.length;
  }
  if (width > 60) width = 60;

  for (final stage in report.stages) {
    buf.write(stage.source.padRight(width));
    buf.write('  : ');
    buf.write(renderShape(stage.shape));
    buf.write('\n');
  }

  if (report.warnings.isNotEmpty) {
    buf.write('\n');
    for (final w in report.warnings) {
      final source = report.stages[w.stageIndex].source.trimLeft();
      buf.write('Warning: ');
      buf.write(source);
      buf.write('\n  ');
      buf.write(w.message);
      buf.write('\n');
    }
  }

  buf.write('\n');
  if (report.writableAs.isNotEmpty) {
    buf.write(
      'Writable as: ${report.writableAs.map((f) => f.name).join(", ")}',
    );
    buf.write('\n');
  }
  if (report.notWritableAs.isNotEmpty) {
    buf.write(
      'Not writable as: ${report.notWritableAs.map((f) => f.name).join(", ")}',
    );
    buf.write('\n');
  }
  return buf.toString();
}
