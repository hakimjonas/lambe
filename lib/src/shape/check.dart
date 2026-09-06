/// Shape-based output format compatibility checker.
///
/// Every [OutputFormat] carries a [ShapeRequirement] describing the root
/// value shapes it can serialize. [canWriteAs] returns [Writable] when a
/// value's inferred [Shape] satisfies the target format's requirement,
/// and [NotWritable] otherwise. A [NotWritable] report carries the
/// mismatch details and a list of [Remediation] query fragments that,
/// when appended to the original query, produce a value the target
/// format accepts.
///
/// Remediations are curated query fragments held as hand-built [LamExpr]
/// constants. Hand-building (rather than parsing source strings) keeps
/// the import graph acyclic — `synthesize.dart` depends on this file,
/// so anything dragged in here is also dragged into `pipe_ops.dart`
/// when [synthesize] is consulted from the spec table.
library;

import '../ast.dart';
import '../output_format.dart';
import 'shape.dart';

/// The shape a given [OutputFormat] requires at its root.
///
/// Sealed hierarchy with concrete subclasses [AnyShape], [MustBeMap],
/// [MustBeList], and [MustBeFlatList].
sealed class ShapeRequirement {
  /// Creates a new [ShapeRequirement]. Use the concrete subclasses.
  const ShapeRequirement();

  /// Whether [shape] satisfies this requirement.
  bool accepts(Shape shape);

  /// Human-readable description of the requirement, suitable for error
  /// messages.
  String describe();
}

/// Accepts any shape. Used by JSON and YAML, which have no root-shape
/// restriction.
final class AnyShape extends ShapeRequirement {
  /// Creates an [AnyShape] requirement.
  const AnyShape();

  @override
  bool accepts(Shape shape) => true;

  @override
  String describe() => 'any value';
}

/// Requires a map at the root. Used by TOML and HCL, whose document-level
/// grammar is a table.
final class MustBeMap extends ShapeRequirement {
  /// Creates a [MustBeMap] requirement.
  const MustBeMap();

  @override
  bool accepts(Shape shape) => shape is SMap || shape is SAny;

  @override
  String describe() => 'a map';

  // Note: does NOT unwrap [SOptional]. An optional root means the
  // value may be absent; TOML/HCL cannot serialize that. Users must
  // materialize with a default before the `--to` step.
}

/// Requires a list at the root, with no constraint on element shape.
///
/// Accepts any [SList], plus [SAny] for unknown shapes. Retained as the
/// generic list-root requirement so future format additions that tolerate
/// any element shape can reuse it; CSV and TSV now use the stricter
/// [MustBeFlatList] because their element shapes must serialize to a
/// single text cell.
final class MustBeList extends ShapeRequirement {
  /// Creates a [MustBeList] requirement.
  const MustBeList();

  @override
  bool accepts(Shape shape) => shape is SList || shape is SAny;

  @override
  String describe() => 'a list';
}

/// Requires a list whose element cells serialize to a single text cell.
/// Used by CSV and TSV.
///
/// Delimited formats project rows onto a flat grid of scalar cells. The
/// serializer supports three element shapes:
/// - `SList<scalar>`: each element is one cell.
/// - `SList<SList<scalar>>`: each inner element is one cell.
/// - `SList<SMap<k1:scalar, k2:scalar, ...>>`: each field is one cell.
///
/// A list-of-maps whose cells hold nested lists or maps has no faithful
/// delimited rendering. Without this stricter requirement, the writer
/// would fall back to Dart's default `toString()` for such cells and
/// silently emit garbage like `"[{key: rumil, value: ^0.6.0}]"`.
///
/// [SAny] is accepted everywhere it appears: when the shape is unknown,
/// the checker cannot prove incompatibility and defers to the runtime
/// guard in the serializer.
final class MustBeFlatList extends ShapeRequirement {
  /// Creates a [MustBeFlatList] requirement.
  const MustBeFlatList();

  @override
  bool accepts(Shape shape) {
    if (shape is SAny) return true;
    if (shape is! SList) return false;
    return _cellShapeIsFlat(shape.element);
  }

  @override
  String describe() => 'a list with scalar cells';

  /// Whether an element shape of the outer list produces only scalar
  /// cells when serialized as a CSV/TSV row.
  ///
  /// [SOptional] is transparent: an optional cell is flat iff its
  /// inner shape is flat. An absent optional renders as an empty
  /// cell, which is always valid.
  static bool _cellShapeIsFlat(Shape elem) => switch (elem) {
    SAny() || SNull() || SBool() || SNum() || SString() => true,
    SList(:final element) => _isScalar(element),
    SMap(:final fields) => fields.values.every(_isScalar),
    SOptional(:final inner) => _cellShapeIsFlat(inner),
  };

  /// Whether [s] is a scalar shape (null, bool, num, string, or unknown).
  ///
  /// `SAny` counts as scalar here: when the shape is unknown, the check
  /// cannot prove incompatibility and defers to the runtime guard.
  /// [SOptional] is transparent; the inner shape decides.
  static bool _isScalar(Shape s) => switch (s) {
    SAny() || SNull() || SBool() || SNum() || SString() => true,
    SList() || SMap() => false,
    SOptional(:final inner) => _isScalar(inner),
  };
}

/// The requirement for each supported [OutputFormat].
///
/// [flattenCells] relaxes the cell-shape requirement for CSV/TSV. When
/// [CellPolicy.json], a list-of-maps or list-of-lists with non-scalar
/// cells is accepted at shape-check time because the writer will
/// JSON-encode those cells inline.
ShapeRequirement requirementFor(
  OutputFormat format, {
  CellPolicy flattenCells = CellPolicy.refuse,
}) => switch (format) {
  OutputFormat.json => const AnyShape(),
  OutputFormat.yaml => const AnyShape(),
  OutputFormat.hocon => const AnyShape(),
  OutputFormat.toml => const MustBeMap(),
  OutputFormat.hcl => const MustBeMap(),
  OutputFormat.csv || OutputFormat.tsv =>
    flattenCells == CellPolicy.json
        ? const MustBeList()
        : const MustBeFlatList(),
};

/// Report returned by [canWriteAs].
///
/// Sealed hierarchy with concrete subclasses [Writable] and
/// [NotWritable].
sealed class ShapeReport {
  /// Creates a new [ShapeReport]. Use the concrete subclasses.
  const ShapeReport();
}

/// The value's shape satisfies the target format's requirement.
final class Writable extends ShapeReport {
  /// Creates a [Writable] report.
  const Writable();
}

/// The value's shape does not satisfy the target format's requirement.
///
/// Carries the target [format], the actual [got] shape, the expected
/// [required], and a non-empty list of [suggestions] the user can append
/// to their query to produce a shape the format accepts. [hints] surface
/// environmental remedies (CLI flags, REPL settings, MCP parameters)
/// that would change the outcome without modifying the query itself.
final class NotWritable extends ShapeReport {
  /// The output format that was requested.
  final OutputFormat format;

  /// The actual shape that was produced.
  final Shape got;

  /// The requirement the format imposes.
  final ShapeRequirement required;

  /// Query-fragment suggestions that would produce a compatible shape.
  final List<Remediation> suggestions;

  /// Environmental guidance for the consumer that would resolve the
  /// mismatch without altering the query. Each [Hint] carries the
  /// invocation-syntax for every supported surface (CLI flag, REPL
  /// command, MCP parameter); surfaces render the form that applies
  /// to them.
  ///
  /// Suggestions modify the query; hints modify the invocation.
  final List<Hint> hints;

  /// Creates a [NotWritable] report.
  const NotWritable({
    required this.format,
    required this.got,
    required this.required,
    required this.suggestions,
    this.hints = const [],
  });
}

/// An environmental remedy: a flag, setting, or parameter change that
/// would resolve a shape mismatch without modifying the query.
///
/// One [Hint] can be rendered as a CLI flag (`--flatten-cells json`),
/// a REPL command (`:flatten-cells json`), or an MCP parameter
/// (`flatten_cells=json`). Consumers pick the form that matches their
/// surface, so the message seen by an end user is never cluttered with
/// the other surfaces' syntax.
final class Hint {
  /// Short human-readable label, for example `"Flatten non-scalar
  /// cells"`. Suitable for menu items or UI chips.
  final String label;

  /// CLI flag form, including value: `"--flatten-cells json"`.
  final String cliFlag;

  /// REPL command form, including value: `":flatten-cells json"`.
  final String replCommand;

  /// MCP tool parameter as a `(name, value)` pair:
  /// `('flatten_cells', 'json')`. Consumers serialize this into their
  /// own tool-argument format.
  final (String, String) mcpParameter;

  /// One-line description of the change's effect, for example
  /// `"Encodes list- or map-valued cells as JSON strings inline."`.
  /// Must read naturally as a sentence after "Or" or "With".
  final String explanation;

  /// Creates a [Hint].
  const Hint({
    required this.label,
    required this.cliFlag,
    required this.replCommand,
    required this.mcpParameter,
    required this.explanation,
  });
}

/// A query fragment that bridges a shape mismatch.
///
/// A [Remediation] is intended to be composed with the user's query via
/// pipe. Given user query `.users` and remediation template `{items: .}`,
/// the composed query is `.users | {items: .}`.
///
/// [display] is what the user sees and pastes. [template] is the AST
/// that actually runs. They are usually identical for the curated
/// remediations defined here, but the two fields are separated so a
/// remediation can surface an intent-level form (such as `as(csv)`)
/// while running a raw fragment (such as `to_entries`). Safe because
/// `as(fmt)` at runtime consults this same curated table and resolves
/// to the raw template.
///
/// Remediations are an internal curated set: the constructor is private
/// and the four canonical templates are hand-built [LamExpr] constants.
/// This keeps `check.dart` independent of the parser, which would
/// otherwise close a `pipe_ops → synthesize → check → parser → pipe_ops`
/// import cycle.
final class Remediation {
  /// Short human-readable label, for example `"Wrap under a key"`.
  final String label;

  /// The query fragment as text. Shown in CLI output, the REPL, or a
  /// web interface, and appended to the user's query via
  /// `$expression | ${display}`.
  ///
  /// Usually identical to [template]'s source. May differ when a
  /// remediation surfaces an intent-level form (e.g. `as(csv)`) while
  /// running a raw fragment (e.g. `to_entries`) underneath.
  final String display;

  /// The query fragment as a [LamExpr]. Composable with a user query
  /// via `applyBridge(user, template)`.
  final LamExpr template;

  /// One-line description of the resulting shape, for example
  /// `"Produces a map with one entry named 'items'."`.
  final String explanation;

  const Remediation._({
    required this.label,
    required this.display,
    required this.template,
    required this.explanation,
  });
}

/// Check whether [value] can be written in [format].
///
/// Returns [Writable] if the value's shape satisfies the format's
/// requirement, otherwise [NotWritable] with suggestions.
///
/// [flattenCells] widens the CSV/TSV element-shape requirement; see
/// [requirementFor].
///
/// Cost is dominated by [shapeOf] on [value], which is bounded by
/// structural depth rather than element count.
ShapeReport canWriteAs(
  Object? value,
  OutputFormat format, {
  CellPolicy flattenCells = CellPolicy.refuse,
}) {
  final shape = shapeOf(value);
  return canWriteShapeAs(shape, format, flattenCells: flattenCells);
}

/// Shape-only variant of [canWriteAs].
///
/// Prefer this when a [Shape] is already available, for example from
/// [inferShape] over a query AST, to avoid re-inferring from a value.
ShapeReport canWriteShapeAs(
  Shape shape,
  OutputFormat format, {
  CellPolicy flattenCells = CellPolicy.refuse,
}) {
  final req = requirementFor(format, flattenCells: flattenCells);
  if (req.accepts(shape)) return const Writable();
  return NotWritable(
    format: format,
    got: shape,
    required: req,
    suggestions: _suggestionsFor(shape, format),
    hints: _hintsFor(shape, format, flattenCells),
  );
}

/// Environmental remedies for a shape/format/policy mismatch.
///
/// Currently one class fires: a CSV/TSV request under the default
/// [CellPolicy.refuse] where the root is already a list, so only the
/// cells are the problem. Switching to [CellPolicy.json] would accept
/// the value as-is. Hints are surfaced via [NotWritable.hints] and
/// rendered into their surface's native form (CLI flag, REPL command,
/// MCP parameter) by each consumer.
List<Hint> _hintsFor(Shape got, OutputFormat format, CellPolicy policy) {
  if (policy != CellPolicy.refuse) return const [];
  if (format != OutputFormat.csv && format != OutputFormat.tsv) {
    return const [];
  }
  if (got is! SList) return const [];
  // At this point the list root is fine; the rejection must be
  // element-level. Flipping to json would accept.
  return const [
    Hint(
      label: 'Flatten non-scalar cells',
      cliFlag: '--flatten-cells json',
      replCommand: ':flatten-cells json',
      mcpParameter: ('flatten_cells', 'json'),
      explanation: 'Encodes list- or map-valued cells as JSON strings inline.',
    ),
  ];
}

List<Remediation> _suggestionsFor(Shape got, OutputFormat format) => switch ((
  got,
  format,
)) {
  // List to a map-root format.
  (SList _, OutputFormat.toml) ||
  (SList _, OutputFormat.hcl) => [_wrapItems(format)],
  // Scalar or null to a map-root format.
  (SString _, OutputFormat.toml) ||
  (SString _, OutputFormat.hcl) ||
  (SNum _, OutputFormat.toml) ||
  (SNum _, OutputFormat.hcl) ||
  (SBool _, OutputFormat.toml) ||
  (SBool _, OutputFormat.hcl) ||
  (SNull _, OutputFormat.toml) ||
  (SNull _, OutputFormat.hcl) => [_wrapValue(format)],
  // Map to a list-root format.
  (SMap _, OutputFormat.csv) ||
  (SMap _, OutputFormat.tsv) => [_toEntriesAsRows(format)],
  // Scalar or null to a list-root format.
  (SString _, OutputFormat.csv) ||
  (SString _, OutputFormat.tsv) ||
  (SNum _, OutputFormat.csv) ||
  (SNum _, OutputFormat.tsv) ||
  (SBool _, OutputFormat.csv) ||
  (SBool _, OutputFormat.tsv) ||
  (SNull _, OutputFormat.csv) ||
  (SNull _, OutputFormat.tsv) => [_wrapValueThenEntries(format)],
  // No curated suggestion for this combination.
  _ => const <Remediation>[],
};

// Curated remediations.
//
// The four canonical template ASTs are hand-built `const` [LamExpr]
// values shared across every format that uses the same bridge. The
// factories below build a per-format `Remediation` from the shared
// AST, setting `display` to `as(<format>)` so the user sees the
// intent form. At runtime `as(<format>)` consults this same table
// and resolves to the raw template, which is why displaying the
// intent form is safe.
//
// Hand-building rather than parsing avoids importing the parser from
// `check.dart` and keeps the import graph acyclic; see the
// [Remediation] doc comment for the full chain.

/// `{items: .}` — wraps the input under a single-entry map.
const LamExpr _wrapItemsAst = ObjConstruct([('items', Identity())]);

/// `{value: .}` — wraps a scalar under a single-entry map.
const LamExpr _wrapValueAst = ObjConstruct([('value', Identity())]);

/// `to_entries` — converts a map to a `[{key, value}, ...]` row list.
const LamExpr _toEntriesAst = BuiltinPipeOp('to_entries', []);

/// `{value: .} | to_entries` — wraps a scalar then projects to a
/// one-row list with a "value" column.
const LamExpr _wrapValueThenEntriesAst = Pipe(
  ObjConstruct([('value', Identity())]),
  BuiltinPipeOp('to_entries', []),
);

Remediation _wrapItems(OutputFormat format) => Remediation._(
  label: 'Wrap under a key',
  display: 'as(${format.name})',
  template: _wrapItemsAst,
  explanation:
      'Wraps the list under a single-entry map '
      '(equivalent to `{items: .}`).',
);

Remediation _wrapValue(OutputFormat format) => Remediation._(
  label: 'Wrap under a key',
  display: 'as(${format.name})',
  template: _wrapValueAst,
  explanation:
      'Wraps the scalar under a single-entry map '
      '(equivalent to `{value: .}`).',
);

Remediation _toEntriesAsRows(OutputFormat format) => Remediation._(
  label: 'Convert entries to rows',
  display: 'as(${format.name})',
  template: _toEntriesAst,
  explanation:
      'Wraps each map entry as a {key, value} row '
      '(equivalent to `to_entries`).',
);

Remediation _wrapValueThenEntries(OutputFormat format) => Remediation._(
  label: 'Wrap as a single-row list',
  display: 'as(${format.name})',
  template: _wrapValueThenEntriesAst,
  explanation:
      'Wraps the scalar as a one-row list with a "value" column '
      '(equivalent to `{value: .} | to_entries`).',
);
