/// Output formatting: --to, --schema.
library;

import 'dart:convert';

import 'package:rumil_parsers/rumil_parsers.dart';

import 'errors.dart';
import 'output_format.dart';
import 'shape/check.dart';

export 'output_format.dart' show OutputFormat, CellPolicy, outputFormatNames;

/// Format [value] as a string in the given [format].
///
/// For JSON, uses pretty-printing with 2-space indent by default.
/// For YAML, uses block style.
/// For TOML/HCL, requires the root value to be a `Map<String, Object?>`.
/// For CSV/TSV, requires a list of maps, a list of lists, or a list of
/// scalars. For a list of maps, headers are the union of keys across
/// all rows in first-seen order; a row missing a key renders as an
/// empty cell.
///
/// Cell handling in CSV/TSV is governed by [flattenCells]. With the
/// default [CellPolicy.refuse], every cell value must be a scalar:
/// null, bool, num, or string. Non-scalar cells throw [OutputShapeError]
/// from the shape check, or [QueryError] from the writer's defensive
/// guard if the shape check was too lossy to prove incompatibility.
/// With [CellPolicy.json], non-scalar cells are encoded as JSON
/// strings inline; the shape check widens to accept any list at the
/// root.
String formatOutput(
  Object? value,
  OutputFormat format, {
  bool pretty = true,
  CellPolicy flattenCells = CellPolicy.refuse,
}) => switch (format) {
  OutputFormat.json =>
    pretty
        ? const JsonEncoder.withIndent('  ').convert(value)
        : const JsonEncoder().convert(value),
  OutputFormat.yaml => _toYaml(value),
  OutputFormat.toml => _toToml(value),
  OutputFormat.csv => _toCsv(value, ',', flattenCells),
  OutputFormat.tsv => _toCsv(value, '\t', flattenCells),
  OutputFormat.hcl => _toHcl(value),
  OutputFormat.hocon => _toHocon(value, pretty: pretty),
};

/// Serialize [value] as HOCON.
///
/// Every JSON document is valid HOCON, so v1 emits the standard JSON
/// form (pretty by default) — byte-for-byte what `serializeHocon`
/// produces for the same value (2-space indent, identical escaping).
/// The shape check treats HOCON like JSON ([AnyShape], see
/// `requirementFor`). When HOCON-specific serialization (bare keys,
/// `key { … }` blocks) lands in rumil_parsers, this delegates to it
/// instead.
String _toHocon(Object? value, {required bool pretty}) =>
    pretty
        ? const JsonEncoder.withIndent('  ').convert(value)
        : const JsonEncoder().convert(value);

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

String _toCsv(Object? value, String delimiter, CellPolicy policy) {
  final fmt = delimiter == '\t' ? OutputFormat.tsv : OutputFormat.csv;
  final report = canWriteAs(value, fmt, flattenCells: policy);
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
            map.containsKey(h) ? _cell(map[h], fmt, policy) : '',
        ],
    ];
    return serializeCsvWithHeaders(headers, rows, config: config);
  }

  if (list.first is List) {
    final rows = [
      for (final row in list)
        [for (final cell in row as List) _cell(cell, fmt, policy)],
    ];
    return serializeCsv(rows, config: config);
  }

  return serializeCsv([
    for (final item in list) [_cell(item, fmt, policy)],
  ], config: config);
}

/// Render a single cell for CSV/TSV output.
///
/// Under [CellPolicy.refuse], non-scalar cells throw [QueryError]. The
/// shape check in [_toCsv] is the primary defense; this is a
/// belt-and-braces guard for cases where the check was bypassed (for
/// example, a [SAny] shape that the checker could not prove
/// incompatible, or heterogeneous list elements that sampling missed).
/// Throws [QueryError] rather than [OutputShapeError] because by this
/// point the shape check has already passed: reaching here means the
/// shape language was unable to prove the mismatch.
///
/// Under [CellPolicy.json], non-scalar cells are JSON-encoded inline
/// as compact strings, and the writer never throws for shape reasons.
String _cell(Object? cell, OutputFormat fmt, CellPolicy policy) {
  if (cell == null) return '';
  if (cell is num || cell is bool || cell is String) return '$cell';
  if (policy == CellPolicy.json) return const JsonEncoder().convert(cell);
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
String _describeCellKind(Object cell) => switch (cell) {
  List() => 'list',
  Map() => 'map',
  _ => cell.runtimeType.toString(),
};

/// Collect the union of keys across [maps] preserving first-seen order.
///
/// The first map's keys appear first in their insertion order; each
/// subsequent map contributes any keys not already present, in the
/// order they first appear. Rows missing a key render as an empty cell
/// rather than silently dropping the column, symmetric with how the
/// writer refuses non-scalar cells elsewhere.
///
/// Implementation note: Dart's default `Set<String>{}` is a
/// `LinkedHashSet`, which preserves insertion order. One pass adds
/// every key; iteration yields the first-seen ordering. No parallel
/// "seen" tracking required.
List<String> _unionHeaders(List<Map<String, Object?>> maps) {
  final headers = <String>{};
  for (final map in maps) {
    headers.addAll(map.keys);
  }
  return headers.toList();
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
