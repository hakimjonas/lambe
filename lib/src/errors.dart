/// Error types for query parsing and evaluation.
library;

import 'output_format.dart';
import 'shape/check.dart';
import 'shape/shape.dart';

/// Error thrown during query evaluation or output serialization.
///
/// Covers type errors, missing fields, out-of-bounds indexing, shape
/// mismatches with output formats, and other runtime failures. Concrete
/// subclasses carry structured information for specific error kinds.
class QueryError implements Exception {
  /// The error message.
  final String message;

  /// Creates a [QueryError] with [message].
  const QueryError(this.message);

  @override
  String toString() => 'QueryError: $message';
}

/// Error thrown when a value's shape is incompatible with a requested
/// output format.
///
/// Carries the structured [report] describing the mismatch and the
/// available remediations. Consumers that inspect the report can render
/// suggestions in their own UI; the inherited [message] provides a
/// rendered text summary for callers that only catch [QueryError].
class OutputShapeError extends QueryError {
  /// The structured shape-mismatch report.
  final NotWritable report;

  /// Creates an [OutputShapeError] from [report].
  OutputShapeError(this.report) : super(_render(report));

  /// The output format that was requested.
  OutputFormat get format => report.format;

  /// The actual shape that was produced.
  Shape get got => report.got;

  /// The requirement the format imposes.
  ShapeRequirement get required => report.required;

  /// Query-fragment suggestions that would produce a compatible shape.
  List<Remediation> get suggestions => report.suggestions;

  static String _render(NotWritable r) {
    final buf = StringBuffer();
    buf.write(r.format.name.toUpperCase());
    buf.write(' output requires ');
    buf.write(r.required.describe());
    buf.write(' at the root, got ');
    buf.write(renderShape(r.got));
    buf.write('.');
    if (r.suggestions.isNotEmpty) {
      buf.write('\nTry appending one of:');
      for (final s in r.suggestions) {
        buf.write('\n  | ');
        buf.write(s.display);
        buf.write('    # ');
        buf.write(s.explanation);
      }
    }
    return buf.toString();
  }
}
