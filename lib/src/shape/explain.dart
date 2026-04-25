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

/// A full explain report for a query.
final class ExplainReport {
  /// The stages along the pipe backbone, in left-to-right order.
  final List<ExplainStage> stages;

  /// The formats the final shape is writable as.
  final List<OutputFormat> writableAs;

  /// The formats the final shape is *not* writable as.
  final List<OutputFormat> notWritableAs;

  /// Creates an [ExplainReport].
  const ExplainReport({
    required this.stages,
    required this.writableAs,
    required this.notWritableAs,
  });
}

/// Produce an [ExplainReport] for [expr] given [inputShape] as the
/// initial context. Pass [SAny] when the input's shape is unknown.
ExplainReport explain(LamExpr expr, Shape inputShape) {
  final backbone = _flattenPipe(expr);
  final stages = <ExplainStage>[];
  var ctx = inputShape;
  for (var i = 0; i < backbone.length; i++) {
    final piece = backbone[i];
    ctx = inferShape(piece, ctx);
    stages.add(
      ExplainStage(
        source: i == 0 ? _render(piece) : '| ${_render(piece)}',
        shape: ctx,
      ),
    );
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
  );
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
