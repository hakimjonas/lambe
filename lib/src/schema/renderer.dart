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
    SList(:final element) => {'type': 'array', 'items': _encode(element)},
    SMap(:final fields) => _encodeMap(fields),
    // Unreachable: SOptional was unwrapped above. Present for
    // exhaustive-switch conformance.
    SOptional() => throw StateError('unreachable: SOptional unwrapped above'),
  };
}

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
