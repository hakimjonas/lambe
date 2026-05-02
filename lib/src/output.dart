/// Output formatting: --to, --schema.
library;

import 'dart:convert';

import 'package:rumil_parsers/rumil_parsers.dart';

import 'errors.dart';
import 'output_format.dart';
import 'shape/check.dart';

export 'output_format.dart' show OutputFormat;

/// Format [value] as a string in the given [format].
///
/// For JSON, uses pretty-printing with 2-space indent by default.
/// For YAML, uses block style.
/// For TOML/HCL, requires the root value to be a `Map<String, Object?>`.
/// For CSV/TSV, requires a list of maps, a list of lists, or a list of
/// scalars. For a list of maps, headers are the union of keys across
/// all rows in first-seen order; a row missing a key renders as an
/// empty cell. Every cell value must be a scalar: null, bool, num,
/// or string. List-of-maps or list-of-lists with non-scalar cells
/// throws [OutputShapeError]; a non-scalar cell that slips past shape
/// inference (for example via [SAny]) throws [QueryError] at
/// serialization time.
String formatOutput(Object? value, OutputFormat format, {bool pretty = true}) =>
    switch (format) {
      OutputFormat.json =>
        pretty
            ? const JsonEncoder.withIndent('  ').convert(value)
            : const JsonEncoder().convert(value),
      OutputFormat.yaml => _toYaml(value),
      OutputFormat.toml => _toToml(value),
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
  final report = canWriteAs(value, OutputFormat.toml);
  if (report is NotWritable) throw OutputShapeError(report);
  final map = value as Map<String, Object?>;
  final doc = <String, TomlValue>{
    for (final MapEntry(:key, value: v) in map.entries)
      key: nativeToAst(v, tomlBuilder),
  };
  return serializeToml(doc);
}

String _toCsv(Object? value, String delimiter) {
  final fmt = delimiter == '\t' ? OutputFormat.tsv : OutputFormat.csv;
  final report = canWriteAs(value, fmt);
  if (report is NotWritable) throw OutputShapeError(report);
  final list = value as List<Object?>;
  final config = DelimitedConfig(delimiter: delimiter);
  if (list.isEmpty) return '';

  if (list.first is Map<String, Object?>) {
    final maps = list.cast<Map<String, Object?>>();
    final headers = _unionHeaders(maps);
    final rows = [
      for (final map in maps)
        [
          for (final h in headers)
            map.containsKey(h) ? _scalarCell(map[h], fmt) : '',
        ],
    ];
    return serializeCsvWithHeaders(headers, rows, config: config);
  }

  if (list.first is List) {
    final rows = [
      for (final row in list)
        [for (final cell in row as List) _scalarCell(cell, fmt)],
    ];
    return serializeCsv(rows, config: config);
  }

  return serializeCsv([
    for (final item in list) [_scalarCell(item, fmt)],
  ], config: config);
}

/// Render a single cell for CSV/TSV output, refusing any non-scalar
/// value.
///
/// The shape check in [_toCsv] is the primary defense; this is a
/// belt-and-braces guard for cases where the check was bypassed (for
/// example, a [SAny] shape that the checker could not prove
/// incompatible, or heterogeneous list elements that sampling missed).
/// Throws [QueryError] rather than [OutputShapeError] because by this
/// point the shape check has already passed: reaching here means the
/// shape language was unable to prove the mismatch.
String _scalarCell(Object? cell, OutputFormat fmt) {
  if (cell == null) return '';
  if (cell is num || cell is bool || cell is String) return '$cell';
  throw QueryError(
    '${fmt.name.toUpperCase()} cell must be a scalar, '
    'got ${_describeCellKind(cell)}.',
  );
}

/// Short human-readable kind name for a non-scalar cell value.
///
/// Used by [_scalarCell] to render errors like "got list" instead of
/// "got _GrowableList". Falls back to [Object.runtimeType] for kinds
/// outside List and Map.
String _describeCellKind(Object cell) {
  if (cell is List) return 'list';
  if (cell is Map) return 'map';
  return cell.runtimeType.toString();
}

/// Collect the union of keys across [maps] preserving first-seen order.
///
/// The first map's keys appear first in their insertion order; each
/// subsequent map contributes any keys not already present, in the
/// order they first appear. Rows missing a key render as an empty cell
/// rather than silently dropping the column, symmetric with how the
/// writer refuses non-scalar cells elsewhere.
List<String> _unionHeaders(List<Map<String, Object?>> maps) {
  final seen = <String>{};
  final headers = <String>[];
  for (final map in maps) {
    for (final key in map.keys) {
      if (seen.add(key)) headers.add(key);
    }
  }
  return headers;
}

String _toHcl(Object? value) {
  final report = canWriteAs(value, OutputFormat.hcl);
  if (report is NotWritable) throw OutputShapeError(report);
  final map = value as Map<String, Object?>;
  final doc = <(String, HclValue)>[
    for (final MapEntry(:key, value: v) in map.entries)
      (key, nativeToAst(v, hclBuilder)),
  ];
  return serializeHcl(doc);
}
