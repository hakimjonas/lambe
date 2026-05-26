/// Render a [Shape] as a JSON Schema subset document.
///
/// Output is the input format [parseJsonSchema] accepts: a JSON
/// object with `type`, and (for containers) `properties`/`required`
/// or `items`. [SOptional] inside an [SMap] becomes a missing entry
/// in `required`; [SOptional] at other positions is flattened (there
/// is no standard JSON Schema representation for a nullable/optional
/// non-field position — the inner shape is rendered).
///
/// Round-trip guarantee: for any `Shape` produced by
/// [parseJsonSchema], `parseJsonSchema(renderJsonSchema(s)) == s`.
library;

import 'dart:convert';

import '../shape/shape.dart';

/// Render [shape] as a pretty-printed JSON Schema string.
///
/// Pretty-prints with 2-space indent by default. For a compact form
/// suitable for embedding in another JSON payload (e.g. an MCP tool
/// response), pass `pretty: false`.
///
/// ### Lossy positions
///
/// [SOptional] inside [SMap] encodes faithfully (missing entry in
/// `required`) and round-trips through [parseJsonSchema].
///
/// [SOptional] anywhere else — at the root, inside a list's
/// `element`, or nested — is **flattened to its inner shape**. Our
/// JSON Schema subset has no idiom for "optional at this position,"
/// so the optionality signal is dropped. Callers composing shapes
/// via inference (for example, a query result whose outermost shape
/// is [SOptional]) should be aware: the rendered schema does not
/// preserve the "may be absent" information.
///
/// Shapes produced by [parseJsonSchema] only put [SOptional] inside
/// [SMap] fields, so the round-trip invariant holds for those.
String renderJsonSchema(Shape shape, {bool pretty = true}) {
  final payload = _encode(shape);
  final encoder =
      pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
  return encoder.convert(payload);
}

Map<String, Object?> _encode(Shape shape) {
  // Top-level SOptional has no standard JSON Schema spelling in our
  // subset. Flatten: a user who called renderJsonSchema on an
  // SOptional<T> gets the JSON Schema for T. This is the same
  // behavior as `renderShape` which shows `optional<T>` but
  // parseJsonSchema has no way to re-parse that syntax.
  final concrete = shape is SOptional ? shape.inner : shape;
  return switch (concrete) {
    // JSON Schema convention: {} accepts any value. The parser
    // mirrors this by treating an empty object (no `type`) as SAny,
    // so the round-trip holds.
    SAny() => const <String, Object?>{},
    SNull() => {'type': 'null'},
    SBool() => {'type': 'boolean'},
    SNum() => {'type': 'number'},
    SString() => {'type': 'string'},
    SList(:final element, :final sampledKinds) => {
      'type': 'array',
      'items': _encode(element),
      // SList(SAny()) means "this list contained heterogeneous or
      // unknown elements" — `shapeOf` collapses to SAny when it can't
      // narrow the element type. Surface the hint so users know the
      // schema reflects sampling, not a guarantee. The lambé schema
      // parser ignores unknown keywords (per JSON Schema's
      // extensibility convention for metadata), so this round-trips
      // safely.
      //
      // When `sampledKinds` is populated, the heterogeneity was
      // observed (mixed types in the sample) — list the distinct
      // shapes so users see what's actually there. When it's null,
      // the list was empty or shape-inference widened structurally
      // without an observable sample (e.g. via static query analysis).
      if (element is SAny)
        'description':
            sampledKinds != null && sampledKinds.isNotEmpty
                ? 'sampled: ${_describeKinds(sampledKinds)} (heterogeneous)'
                : 'sampled, may be heterogeneous',
    },
    SMap(:final fields) => _encodeMap(fields),
    // Unreachable: SOptional was unwrapped above. Present for
    // exhaustive-switch conformance.
    SOptional() => throw StateError('unreachable: SOptional unwrapped above'),
  };
}

/// Render a list of distinct sampled shapes as a comma-separated word
/// list for the heterogeneous-list description string. Maps each
/// [Shape] to a short human-readable name (number, string, list, ...);
/// nested container shapes collapse to their kind without recursion.
String _describeKinds(List<Shape> kinds) => kinds.map(_kindName).join(', ');

String _kindName(Shape s) => switch (s) {
  SNull() => 'null',
  SBool() => 'boolean',
  SNum() => 'number',
  SString() => 'string',
  SList() => 'array',
  SMap() => 'object',
  SOptional() => 'optional',
  SAny() => 'any',
};

Map<String, Object?> _encodeMap(Map<String, Shape> fields) {
  final properties = <String, Object?>{};
  final required = <String>[];
  for (final MapEntry(:key, :value) in fields.entries) {
    if (value is SOptional) {
      properties[key] = _encode(value.inner);
    } else {
      properties[key] = _encode(value);
      required.add(key);
    }
  }
  final result = <String, Object?>{
    'type': 'object',
    if (properties.isNotEmpty) 'properties': properties,
    if (required.isNotEmpty) 'required': required,
  };
  return result;
}
