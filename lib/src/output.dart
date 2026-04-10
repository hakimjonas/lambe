/// Output formatting: --to, --schema.
library;

import 'dart:convert';

import 'package:rumil_parsers/rumil_parsers.dart';

import 'errors.dart';

/// Supported output formats for `--to`.
enum OutputFormat {
  /// JSON output (default).
  json,

  /// YAML output.
  yaml,

  /// TOML output (root must be a map).
  toml,

  /// XML output.
  xml,

  /// CSV output (root must be a list of maps or list of lists).
  csv,

  /// TSV output (tab-separated, same structure as CSV).
  tsv,

  /// HCL output (root must be a map).
  hcl,
}

/// Format [value] as a string in the given [format].
///
/// For JSON, uses pretty-printing with 2-space indent by default.
/// For YAML, uses block style.
/// For TOML/HCL, requires the root value to be a `Map<String, Object?>`.
/// For XML, wraps in a `<root>` element.
/// For CSV/TSV, requires a list of maps (uses keys as headers) or list of lists.
String formatOutput(Object? value, OutputFormat format, {bool pretty = true}) =>
    switch (format) {
      OutputFormat.json =>
        pretty
            ? const JsonEncoder.withIndent('  ').convert(value)
            : const JsonEncoder().convert(value),
      OutputFormat.yaml => _toYaml(value),
      OutputFormat.toml => _toToml(value),
      OutputFormat.xml => _toXml(value),
      OutputFormat.csv => _toCsv(value, ','),
      OutputFormat.tsv => _toCsv(value, '\t'),
      OutputFormat.hcl => _toHcl(value),
    };

/// Infer the structure of [value] without showing actual data.
///
/// Replaces values with type names:
/// - `null` → `"null"`
/// - `true`/`false` → `"boolean"`
/// - `42`, `3.14` → `"number"`
/// - `"hello"` → `"string"`
/// - `[1, 2]` → `["number"]` (schema of first element)
/// - `{a: 1}` → `{a: "number"}`
Object? inferSchema(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return 'boolean';
  if (value is int) return 'number';
  if (value is double) return 'number';
  if (value is String) return 'string';
  if (value is List<Object?>) {
    if (value.isEmpty) return <Object?>[];
    return [inferSchema(value.first)];
  }
  if (value is Map<String, Object?>) {
    return {
      for (final MapEntry(:key, value: entryValue) in value.entries)
        key: inferSchema(entryValue),
    };
  }
  return value.runtimeType.toString();
}

String _toYaml(Object? value) {
  final ast = nativeToAst(value, yamlBuilder);
  return serializeYaml(ast);
}

String _toToml(Object? value) {
  if (value is! Map<String, Object?>) {
    throw QueryError(
      'TOML output requires a map at the root level, got ${value.runtimeType}',
    );
  }
  final doc = <String, TomlValue>{
    for (final MapEntry(:key, value: v) in value.entries)
      key: nativeToAst(v, tomlBuilder),
  };
  return serializeToml(doc);
}

String _toXml(Object? value) {
  final ast = nativeToAst(value, xmlBuilder);
  return serializeXml(ast);
}

String _toCsv(Object? value, String delimiter) {
  final config = DelimitedConfig(delimiter: delimiter);
  if (value is List<Object?>) {
    if (value.isEmpty) return '';

    if (value.first is Map<String, Object?>) {
      final maps = value.cast<Map<String, Object?>>();
      final headers = maps.first.keys.toList();
      final rows = [
        for (final map in maps) [for (final h in headers) '${map[h] ?? ''}'],
      ];
      return serializeCsvWithHeaders(headers, rows, config: config);
    }

    if (value.first is List) {
      final rows = [
        for (final row in value) [for (final cell in row as List) '$cell'],
      ];
      return serializeCsv(rows, config: config);
    }

    return serializeCsv([
      for (final item in value) ['$item'],
    ], config: config);
  }

  throw QueryError('CSV/TSV output requires a list, got ${value.runtimeType}');
}

String _toHcl(Object? value) {
  if (value is! Map<String, Object?>) {
    throw QueryError(
      'HCL output requires a map at the root level, got ${value.runtimeType}',
    );
  }
  final doc = <(String, HclValue)>[
    for (final MapEntry(:key, value: v) in value.entries)
      (key, nativeToAst(v, hclBuilder)),
  ];
  return serializeHcl(doc);
}
