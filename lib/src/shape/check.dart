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
/// Remediations are curated query fragments. Each is parsed to an AST at
/// construction so consumers can compose it with a user query without
/// string manipulation.
library;

import 'package:rumil/rumil.dart' show Success;

import '../ast.dart';
import '../output_format.dart';
import '../parser.dart' as parser_;
import 'shape.dart';

/// The shape a given [OutputFormat] requires at its root.
///
/// Sealed hierarchy with concrete subclasses [AnyShape], [MustBeMap], and
/// [MustBeList].
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
}

/// Requires a list at the root. Used by CSV and TSV.
///
/// The serializer supports three list shapes: `list<map>`, `list<list>`,
/// and `list<scalar>`. [accepts] returns true for any list, including
/// the empty list.
final class MustBeList extends ShapeRequirement {
  /// Creates a [MustBeList] requirement.
  const MustBeList();

  @override
  bool accepts(Shape shape) => shape is SList || shape is SAny;

  @override
  String describe() => 'a list';
}

/// The requirement for each supported [OutputFormat].
ShapeRequirement requirementFor(OutputFormat format) => switch (format) {
  OutputFormat.json => const AnyShape(),
  OutputFormat.yaml => const AnyShape(),
  OutputFormat.toml => const MustBeMap(),
  OutputFormat.hcl => const MustBeMap(),
  OutputFormat.csv => const MustBeList(),
  OutputFormat.tsv => const MustBeList(),
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
/// to their query to produce a shape the format accepts.
final class NotWritable extends ShapeReport {
  /// The output format that was requested.
  final OutputFormat format;

  /// The actual shape that was produced.
  final Shape got;

  /// The requirement the format imposes.
  final ShapeRequirement required;

  /// Query-fragment suggestions that would produce a compatible shape.
  final List<Remediation> suggestions;

  /// Creates a [NotWritable] report.
  const NotWritable({
    required this.format,
    required this.got,
    required this.required,
    required this.suggestions,
  });
}

/// A query fragment that bridges a shape mismatch.
///
/// A [Remediation] is intended to be composed with the user's query via
/// pipe. Given user query `.users` and remediation template `{items: .}`,
/// the composed query is `.users | {items: .}`.
///
/// [display] is the human-readable source string, suitable for showing in
/// CLI output, a REPL, or a web interface. [template] is the same source
/// parsed to a [LamExpr], allowing composition through [applyBridge]
/// without string manipulation.
final class Remediation {
  /// Short human-readable label, for example `"Wrap under a key"`.
  final String label;

  /// The query fragment as source text. Always equal to the source that
  /// was parsed to produce [template].
  final String display;

  /// The query fragment parsed to a [LamExpr]. Composable with a user
  /// query via `applyBridge(user, template)`.
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

  /// Parse [source] as a query fragment and build a [Remediation].
  ///
  /// Throws [ArgumentError] if [source] does not parse. This validates
  /// curated templates at construction time so invalid suggestions
  /// cannot be surfaced to users.
  factory Remediation({
    required String label,
    required String source,
    required String explanation,
  }) {
    final result = parser_.parseQuery(source);
    final ast = switch (result) {
      Success(value: final v) => v,
      _ =>
        throw ArgumentError('Remediation template failed to parse: "$source"'),
    };
    return Remediation._(
      label: label,
      display: source,
      template: ast,
      explanation: explanation,
    );
  }
}

/// Check whether [value] can be written in [format].
///
/// Returns [Writable] if the value's shape satisfies the format's
/// requirement, otherwise [NotWritable] with suggestions.
///
/// Cost is dominated by [shapeOf] on [value], which is bounded by
/// structural depth rather than element count.
ShapeReport canWriteAs(Object? value, OutputFormat format) {
  final shape = shapeOf(value);
  return canWriteShapeAs(shape, format);
}

/// Shape-only variant of [canWriteAs].
///
/// Prefer this when a [Shape] is already available, for example from
/// [inferShape] over a query AST, to avoid re-inferring from a value.
ShapeReport canWriteShapeAs(Shape shape, OutputFormat format) {
  final req = requirementFor(format);
  if (req.accepts(shape)) return const Writable();
  return NotWritable(
    format: format,
    got: shape,
    required: req,
    suggestions: _suggestionsFor(shape, format),
  );
}

List<Remediation> _suggestionsFor(Shape got, OutputFormat format) => switch ((
  got,
  format,
)) {
  // List to a map-root format.
  (SList _, OutputFormat.toml) || (SList _, OutputFormat.hcl) => [_wrapItems],
  // Scalar or null to a map-root format.
  (SString _, OutputFormat.toml) ||
  (SString _, OutputFormat.hcl) ||
  (SNum _, OutputFormat.toml) ||
  (SNum _, OutputFormat.hcl) ||
  (SBool _, OutputFormat.toml) ||
  (SBool _, OutputFormat.hcl) ||
  (SNull _, OutputFormat.toml) ||
  (SNull _, OutputFormat.hcl) => [_wrapValue],
  // Map to a list-root format.
  (SMap _, OutputFormat.csv) ||
  (SMap _, OutputFormat.tsv) => [_toEntriesAsRows],
  // Scalar or null to a list-root format.
  (SString _, OutputFormat.csv) ||
  (SString _, OutputFormat.tsv) ||
  (SNum _, OutputFormat.csv) ||
  (SNum _, OutputFormat.tsv) ||
  (SBool _, OutputFormat.csv) ||
  (SBool _, OutputFormat.tsv) ||
  (SNull _, OutputFormat.csv) ||
  (SNull _, OutputFormat.tsv) => [_wrapValueThenEntries],
  // No curated suggestion for this combination.
  _ => const <Remediation>[],
};

// Curated remediations. Not `const` because each constructor runs the
// parser to validate the template.
final Remediation _wrapItems = Remediation(
  label: 'Wrap under a key',
  source: '{items: .}',
  explanation: 'Produces a map with one entry named "items".',
);

final Remediation _wrapValue = Remediation(
  label: 'Wrap under a key',
  source: '{value: .}',
  explanation: 'Produces a map with one entry named "value".',
);

final Remediation _toEntriesAsRows = Remediation(
  label: 'Convert entries to rows',
  source: 'to_entries',
  explanation: 'Produces a list of {key, value} rows.',
);

final Remediation _wrapValueThenEntries = Remediation(
  label: 'Wrap as a single-row list',
  source: '{value: .} | to_entries',
  explanation: 'Produces a one-row list with one column named "value".',
);
