/// Shape-directed synthesis of query-fragment ASTs that bridge a
/// [Shape] to a target [OutputFormat]'s [ShapeRequirement].
///
/// [synthesize] returns the AST fragments from the curated
/// [Remediation] table for a given `(from, target)` pair. Fragments are
/// ordered by curator preference, most preferred first. An empty list
/// means no bridge is needed (the target already accepts [from]) or no
/// curated bridge is defined for this combination; use
/// [canWriteShapeAs] to distinguish the two cases.
library;

import '../ast.dart';
import '../output_format.dart';
import 'check.dart';
import 'shape.dart';

/// AST fragments that, when piped after a query producing [from], yield
/// a value satisfying [target]'s shape requirement.
///
/// Returns an empty list when the target already accepts [from] or when
/// no curated bridge exists for the combination.
List<LamExpr> synthesize(Shape from, OutputFormat target) {
  final report = canWriteShapeAs(from, target);
  return switch (report) {
    Writable() => const <LamExpr>[],
    NotWritable(:final suggestions) => [
      for (final r in suggestions) r.template,
    ],
  };
}

/// Shape-directed synthesis returning full [Remediation] records.
///
/// Equivalent to [synthesize] but exposes [Remediation.display],
/// [Remediation.label], and [Remediation.explanation] for callers that
/// render suggestions to a user, such as CLI prompts or a web UI.
List<Remediation> synthesizeWithLabels(Shape from, OutputFormat target) {
  final report = canWriteShapeAs(from, target);
  return switch (report) {
    Writable() => const <Remediation>[],
    NotWritable(:final suggestions) => suggestions,
  };
}

/// Compose [user]'s query with a [bridge] AST fragment via [Pipe].
///
/// Equivalent to the textual composition `($user) | ($bridge)` but
/// operates on the AST directly, avoiding string-escaping hazards.
LamExpr applyBridge(LamExpr user, LamExpr bridge) => Pipe(user, bridge);
