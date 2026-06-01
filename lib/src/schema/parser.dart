/// Parser for a JSON Schema subset that maps to Lambë [Shape].
///
/// Accepts four keywords:
/// - `type` (string): `"null"`, `"boolean"`, `"number"`, `"integer"`,
///   `"string"`, `"array"`, or `"object"`.
/// - `properties` (object, only meaningful when `type` is `"object"`):
///   field name → nested schema.
/// - `items` (schema, only meaningful when `type` is `"array"`): the
///   element schema.
/// - `required` (array of strings, only meaningful when `type` is
///   `"object"`): listed properties are required; others become
///   [SOptional].
///
/// Rejects structural combinators, value-level constraints, and
/// references with a clear per-keyword error. Unknown keywords are
/// ignored (JSON Schema's extensibility convention for metadata like
/// `description` or `title`).
library;

import 'package:rumil/rumil.dart';
import 'package:rumil_parsers/rumil_parsers.dart';

import '../errors.dart';
import '../shape/shape.dart';

/// Parse a JSON Schema subset [source] into a [Shape].
///
/// Throws [QueryError] on JSON parse error, on unsupported schema
/// features, or on schemas that do not describe a shape.
Shape parseJsonSchema(String source) {
  final parseResult = parseJson(source);
  final json = switch (parseResult) {
    Success<ParseError, JsonValue>(:final value) => value,
    Partial<ParseError, JsonValue>(:final value) => value,
    Failure<ParseError, JsonValue>(:final errors) =>
      throw QueryError(
        'schema: invalid JSON (${errors.firstOrNull?.toString() ?? "parse failed"})',
      ),
  };
  return _schema(json, path: r'$');
}

Shape _schema(JsonValue node, {required String path}) {
  if (node is! JsonObject) {
    throw QueryError(
      'schema at $path: expected a JSON object describing a shape, '
      'got ${_kindOf(node)}',
    );
  }
  _rejectUnsupportedKeywords(node, path: path);

  final typeValue = node.fields['type'];
  if (typeValue == null) {
    // Empty-object convention: {} accepts any value. Round-trips
    // with [renderJsonSchema] on SAny.
    if (node.fields.isEmpty) return const SAny();
    throw QueryError(
      'schema at $path: missing "type" keyword. A schema must declare '
      'a type such as "null", "boolean", "number", "string", "array", '
      'or "object".',
    );
  }
  if (typeValue is! JsonString) {
    throw QueryError(
      'schema at $path: "type" must be a string, got ${_kindOf(typeValue)}',
    );
  }

  switch (typeValue.value) {
    case 'null':
      return const SNull();
    case 'boolean':
      return const SBool();
    case 'number':
    case 'integer':
      return const SNum();
    case 'string':
      return const SString();
    case 'array':
      return _array(node, path: path);
    case 'object':
      return _object(node, path: path);
    default:
      throw QueryError(
        'schema at $path: unsupported type "${typeValue.value}". '
        'Supported: null, boolean, number, integer, string, array, object.',
      );
  }
}

Shape _array(JsonObject node, {required String path}) {
  final items = node.fields['items'];
  if (items == null) return const SList(SAny());
  return SList(_schema(items, path: '$path.items'));
}

Shape _object(JsonObject node, {required String path}) {
  final props = node.fields['properties'];
  final required = _requiredList(node.fields['required'], path: path);

  if (props == null) return const SMap(<String, Shape>{});
  if (props is! JsonObject) {
    throw QueryError(
      'schema at $path: "properties" must be a JSON object, '
      'got ${_kindOf(props)}',
    );
  }

  final fields = <String, Shape>{};
  for (final MapEntry(:key, :value) in props.fields.entries) {
    final inner = _schema(value, path: '$path.properties.$key');
    fields[key] = required.contains(key) ? inner : SOptional(inner);
  }
  return SMap(fields);
}

Set<String> _requiredList(JsonValue? node, {required String path}) {
  if (node == null) {
    // No `required`: JSON Schema's default is "no properties are
    // required." Every property becomes SOptional.
    return const <String>{};
  }
  if (node is! JsonArray) {
    throw QueryError(
      'schema at $path: "required" must be an array of strings, '
      'got ${_kindOf(node)}',
    );
  }
  final names = <String>{};
  for (var i = 0; i < node.elements.length; i++) {
    final el = node.elements[i];
    if (el is! JsonString) {
      throw QueryError(
        'schema at $path: "required[$i]" must be a string, '
        'got ${_kindOf(el)}',
      );
    }
    names.add(el.value);
  }
  return names;
}

/// Keywords that are part of JSON Schema but have no mapping to
/// Lambë's shape system. Each is rejected with a targeted error so the
/// user sees exactly which feature is unsupported.
const _rejectedKeywords = <String, String>{
  // Value-level constraints — out of scope. Lambë is a shape system,
  // not a validator.
  'minimum': 'value-level constraints are not supported',
  'maximum': 'value-level constraints are not supported',
  'exclusiveMinimum': 'value-level constraints are not supported',
  'exclusiveMaximum': 'value-level constraints are not supported',
  'multipleOf': 'value-level constraints are not supported',
  'minLength': 'value-level constraints are not supported',
  'maxLength': 'value-level constraints are not supported',
  'pattern': 'value-level constraints are not supported',
  'format': 'value-level constraints are not supported',
  'minItems': 'value-level constraints are not supported',
  'maxItems': 'value-level constraints are not supported',
  'uniqueItems': 'value-level constraints are not supported',
  'minProperties': 'value-level constraints are not supported',
  'maxProperties': 'value-level constraints are not supported',
  'const': 'value-level constraints are not supported',
  'enum': 'value-level constraints are not supported',
  // Structural combinators — out of scope. Lambë's shape ADT is
  // unions-free by design.
  'allOf': 'structural combinators are not supported',
  'oneOf': 'structural combinators are not supported',
  'anyOf': 'structural combinators are not supported',
  'not': 'structural combinators are not supported',
  // Conditionals — would require a constraint solver, not a shape
  // system.
  'if': 'conditional schemas are not supported',
  'then': 'conditional schemas are not supported',
  'else': 'conditional schemas are not supported',
  'dependencies': 'conditional schemas are not supported',
  'dependentRequired': 'conditional schemas are not supported',
  'dependentSchemas': 'conditional schemas are not supported',
  // References — schemas are single-file in 0.9.0.
  '\$ref': 'schema references (\$ref) are not supported',
  '\$defs': 'schema references (\$ref) are not supported',
  'definitions': 'schema references (\$ref) are not supported',
  // Extra object constraints — out of scope.
  'additionalProperties': 'additionalProperties is not supported',
  'patternProperties': 'patternProperties is not supported',
  'propertyNames': 'propertyNames is not supported',
};

void _rejectUnsupportedKeywords(JsonObject node, {required String path}) {
  for (final key in node.fields.keys) {
    final reason = _rejectedKeywords[key];
    if (reason != null) {
      throw QueryError('schema at $path: "$key" is unsupported — $reason.');
    }
  }
}

String _kindOf(JsonValue v) => switch (v) {
  JsonNull() => 'null',
  JsonBool() => 'bool',
  JsonInt() || JsonDouble() => 'number',
  JsonString() => 'string',
  JsonArray() => 'array',
  JsonObject() => 'object',
};
