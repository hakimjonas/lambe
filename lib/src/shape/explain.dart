/// Shape-trace rendering for the `--explain` CLI flag.
///
/// [explain] walks the pipe backbone of a parsed query, applies
/// [inferShape] at each stage, and returns a report of the shape at
/// each stage together with the set of output formats the final shape
/// can be serialized as. It performs static analysis only and does not
/// evaluate the query. An optional initial [Shape] seeds the trace;
/// pass [SAny] when no input data is available.
library;

import 'dart:convert';

import '../ast.dart';
import '../output_format.dart';
import 'check.dart';
import 'infer.dart';
import 'pipe_ops.dart';
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

/// Category of static-analysis finding surfaced by [explain].
///
/// - [emptyFilter]: a `filter`/`filter_values`/`filter_keys` predicate
///   is provably non-boolean, so the filter always returns empty.
/// - [runtimeRejection]: a pipe op's input shape is provably
///   incompatible with the op (e.g. `filter` on an [SMap]); the query
///   will throw at runtime if reached.
/// - [trivialResult]: a parameterised op (`sort_by`, `group_by`,
///   `map`, `unique_by`) references a field that is provably absent
///   from the element shape. The op runs, but the field access yields
///   null for every element, so the result is trivial (same order,
///   same group, same null). Often a typo but legitimate uses exist,
///   which is why this class is opt-in via [explain]'s
///   `includeTrivial` parameter.
enum WarningKind {
  /// A filter predicate is provably non-boolean.
  emptyFilter,

  /// The op's input shape is provably incompatible; runtime throw.
  runtimeRejection,

  /// The op runs but the result is trivial (opt-in).
  trivialResult,
}

/// A static-analysis finding attached to an explain report.
///
/// Each warning points at a specific [ExplainReport.stages] entry
/// via [stageIndex] and carries a one-line human-readable [message]
/// plus a [kind] classifier for filtering (CLI flag gates
/// [WarningKind.trivialResult], for example, and a JSON consumer
/// might want to surface only [WarningKind.runtimeRejection]).
final class ExplainWarning {
  /// The stage this warning refers to, as an index into
  /// [ExplainReport.stages].
  final int stageIndex;

  /// One-line human-readable message.
  final String message;

  /// The warning category, for filtering and machine-readable output.
  final WarningKind kind;

  /// Creates an [ExplainWarning].
  const ExplainWarning({
    required this.stageIndex,
    required this.message,
    required this.kind,
  });
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

  /// The CSV/TSV cell policy the report was generated under. Default
  /// is [CellPolicy.refuse]; pass [CellPolicy.json] to [explain] to
  /// get writability lists that reflect the widened element-shape
  /// requirement.
  final CellPolicy flattenCells;

  /// Creates an [ExplainReport].
  const ExplainReport({
    required this.stages,
    required this.writableAs,
    required this.notWritableAs,
    this.warnings = const [],
    this.flattenCells = CellPolicy.refuse,
  });
}

/// Produce an [ExplainReport] for [expr] given [inputShape] as the
/// initial context. Pass [SAny] when the input's shape is unknown.
///
/// [flattenCells] widens the CSV/TSV element-shape requirement so the
/// report's writability lists reflect the policy in effect at the
/// caller (CLI `--flatten-cells`, REPL `:flatten-cells`, MCP
/// `flatten_cells`). Default is [CellPolicy.refuse], matching the
/// library's conservative default.
///
/// [includeTrivial] controls whether [WarningKind.trivialResult]
/// findings are emitted. Defaults to `false`; trivial findings are
/// often legitimate (e.g. `sort_by(.missing)` intentionally as a
/// stable no-op sort) and can produce noise. The CLI enables them via
/// `--explain-trivial`. [WarningKind.emptyFilter] and
/// [WarningKind.runtimeRejection] findings are always emitted:
/// empty-filter is almost always a bug, and runtime-rejection means
/// the query will throw.
ExplainReport explain(
  LamExpr expr,
  Shape inputShape, {
  CellPolicy flattenCells = CellPolicy.refuse,
  bool includeTrivial = false,
}) {
  final backbone = _flattenPipe(expr);
  final stages = <ExplainStage>[];
  final warnings = <ExplainWarning>[];
  var prev = inputShape;
  var ctx = inputShape;
  for (var i = 0; i < backbone.length; i++) {
    final piece = backbone[i];

    final emptyFilter = _analyzePredicate(piece, prev);
    if (emptyFilter != null) {
      warnings.add(
        ExplainWarning(
          stageIndex: i,
          message: emptyFilter,
          kind: WarningKind.emptyFilter,
        ),
      );
    }

    final rejection = _analyzeRejection(piece, prev);
    if (rejection != null) {
      warnings.add(
        ExplainWarning(
          stageIndex: i,
          message: rejection,
          kind: WarningKind.runtimeRejection,
        ),
      );
    }

    if (includeTrivial) {
      final trivial = _analyzeTrivial(piece, prev);
      if (trivial != null) {
        warnings.add(
          ExplainWarning(
            stageIndex: i,
            message: trivial,
            kind: WarningKind.trivialResult,
          ),
        );
      }
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
    if (canWriteShapeAs(ctx, fmt, flattenCells: flattenCells) is Writable) {
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
    flattenCells: flattenCells,
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

/// Detect input shapes that the pipe op will reject at runtime.
///
/// Each pipe op has an `accepts(Shape)` predicate in `pipe_ops.dart`.
/// When the input shape is concrete (not [SAny]) and the predicate
/// returns false, the query will throw at runtime. This warning
/// surfaces that statically.
///
/// Returns `null` when [op] is not a pipe op (e.g. an object
/// constructor), when the input shape is [SAny] (cannot prove), or
/// when the op accepts the input shape.
String? _analyzeRejection(LamExpr op, Shape inputShape) {
  if (inputShape is SAny) return null;
  final info = pipeOpInfoFor(op);
  if (info == null) return null;
  if (info.accepts(inputShape)) return null;
  return '${info.name} rejects ${renderShape(inputShape)}; '
      'this will throw at runtime';
}

/// Detect parameterised ops whose argument references a field
/// provably absent from the element shape.
///
/// Applies to `sort_by`, `group_by`, `map`, `unique_by`. The op runs,
/// but because the field access yields null for every element, the
/// result is trivial (identity sort, single group, all-nulls map).
/// Often a typo but legitimate uses exist (stable no-op sort for
/// padding, explicit null projection), which is why this warning is
/// opt-in via `explain(..., includeTrivial: true)`.
///
/// Returns `null` for ops not in this set, for inputs that are not
/// lists (outer shape errors surface as runtime-rejection warnings
/// instead), or when the argument references a field that may exist.
String? _analyzeTrivial(LamExpr op, Shape inputShape) {
  final (argExpr, opName) = switch (op) {
    SortByOp(:final key) => (key, 'sort_by'),
    GroupByOp(:final key) => (key, 'group_by'),
    MapOp(:final transform) => (transform, 'map'),
    UniqueByOp(:final key) => (key, 'unique_by'),
    _ => (null, null),
  };
  if (argExpr == null || opName == null) return null;
  if (inputShape is! SList) return null;
  final missing = _missingFieldPath(argExpr, inputShape.element);
  if (missing == null) return null;
  return '$opName argument $missing does not exist on the element shape; '
      'the result is trivial';
}

/// Render `.a.b.c` if [expr] is a [Field]/[Access] chain whose root
/// resolves to a known [SMap] missing a segment in the chain; otherwise
/// `null`.
///
/// Walks left-to-right along a `Field`/`Access` spine, narrowing the
/// context at each step. As soon as a step lands on a known map whose
/// fields don't include the required name, returns the rendered path up
/// to and including that missing segment. [SAny] anywhere along the
/// path disables the check: unknown context means we cannot prove
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
  if (report.flattenCells != CellPolicy.refuse) {
    buf.write('Cell policy: ${report.flattenCells.name}\n');
  }
  return buf.toString();
}

/// Render an [ExplainReport] as a JSON string for programmatic
/// consumers (agent tooling, build pipelines).
///
/// The payload is a map with keys `stages`, `warnings`, `writable_as`,
/// `not_writable_as`, and `flatten_cells`. Each stage carries its
/// `source` string and a `shape` serialized via [shapeToJson] (a
/// nested `{kind, ...}` tree rather than the `renderShape` text form,
/// so consumers can pattern-match without re-parsing). Each warning
/// carries `stage_index`, `kind` (one of `empty_filter`,
/// `runtime_rejection`, `trivial_result`), and `message`.
String renderExplainJson(ExplainReport report) {
  final payload = <String, Object?>{
    'stages': [
      for (final s in report.stages)
        {'source': s.source, 'shape': shapeToJson(s.shape)},
    ],
    'warnings': [
      for (final w in report.warnings)
        {
          'stage_index': w.stageIndex,
          'kind': _warningKindName(w.kind),
          'message': w.message,
        },
    ],
    'writable_as': [for (final f in report.writableAs) f.name],
    'not_writable_as': [for (final f in report.notWritableAs) f.name],
    'flatten_cells': report.flattenCells.name,
  };
  return const JsonEncoder.withIndent('  ').convert(payload);
}

String _warningKindName(WarningKind k) => switch (k) {
  WarningKind.emptyFilter => 'empty_filter',
  WarningKind.runtimeRejection => 'runtime_rejection',
  WarningKind.trivialResult => 'trivial_result',
};
