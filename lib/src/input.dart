/// Multi-format input parsing.
library;

import 'package:rumil/rumil.dart';
import 'package:rumil_parsers/rumil_parsers.dart';

import 'errors.dart';

/// Supported input formats.
enum Format {
  /// JSON (RFC 8259).
  json,

  /// YAML (1.2.2 with anchors, aliases, merge keys, block scalars).
  yaml,

  /// TOML (v1.1).
  toml,

  /// HCL (HashiCorp Configuration Language).
  hcl,

  /// XML (W3C 1.0).
  xml,

  /// CSV (RFC 4180, auto-detected dialect).
  csv,

  /// TSV (tab-separated values).
  tsv,
}

/// Parse [input] string in the given [format] to native Dart types.
///
/// Returns `Map<String, Object?>`, `List<Object?>`, `String`, `num`,
/// `bool`, or `null`.
///
/// For CSV/TSV with a header row, returns `List<Map<String, Object?>>` where
/// each row is a map keyed by header names.
Object? parseInput(String input, Format format) => switch (format) {
  Format.json => _parse(parseJson(input), jsonToNative, 'JSON'),
  Format.yaml => _parse(parseYaml(input), yamlToNative, 'YAML'),
  Format.toml => _parse(parseToml(input), tomlDocToNative, 'TOML'),
  Format.hcl => _parse(parseHcl(input), hclDocToNative, 'HCL'),
  Format.xml => _parse(parseXml(input), (doc) => xmlToNative(doc.root), 'XML'),
  Format.csv => _parseDelimited(input, null),
  Format.tsv => _parseDelimited(input, defaultTsvConfig),
};

/// Detect format from a file path's extension.
///
/// Returns `null` if the extension is unrecognized.
Format? detectFormat(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.json')) return Format.json;
  if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return Format.yaml;
  if (lower.endsWith('.toml')) return Format.toml;
  if (lower.endsWith('.tf') || lower.endsWith('.hcl')) return Format.hcl;
  if (lower.endsWith('.xml') ||
      lower.endsWith('.pom') ||
      lower.endsWith('.csproj') ||
      lower.endsWith('.svg')) {
    return Format.xml;
  }
  if (lower.endsWith('.csv')) return Format.csv;
  if (lower.endsWith('.tsv') || lower.endsWith('.tab')) return Format.tsv;
  return null;
}

/// Guess format by sniffing the input content.
///
/// Falls back to [Format.json] if uncertain.
Format sniffFormat(String input) {
  final trimmed = input.trimLeft();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return Format.json;
  if (trimmed.startsWith('<?xml') || trimmed.startsWith('<')) return Format.xml;
  if (trimmed.startsWith('---') || trimmed.contains(': ')) return Format.yaml;
  if (trimmed.contains(' = ') && !trimmed.contains('{')) return Format.toml;
  if (trimmed.contains(' = ') || trimmed.contains(' {')) return Format.hcl;
  return Format.json;
}

/// Parse a [result] from a Rumil parser, converting to native Dart types
/// via [toNative]. Throws [QueryError] on parse failure.
Object? _parse<A>(
  Result<ParseError, A> result,
  Object? Function(A) toNative,
  String formatName,
) => switch (result) {
  Success<ParseError, A>(:final value) => toNative(value),
  Partial<ParseError, A>(:final value) => toNative(value),
  Failure<ParseError, A>() =>
    throw QueryError('$formatName parse error: ${result.errors}'),
};

/// Parse delimited input, auto-detecting dialect if [config] is null.
///
/// If the detected (or provided) dialect has headers, returns
/// `List<Map<String, Object?>>`. Otherwise returns `List<List<String>>`.
Object? _parseDelimited(String input, DelimitedConfig? config) {
  final cfg = config ?? detectDialect(input);
  if (cfg.hasHeader == true) {
    final result = parseDelimitedWithHeaders(input, cfg);
    return switch (result) {
      Success(:final value) => _headersToMaps(value.$1, value.$2),
      Partial(:final value) => _headersToMaps(value.$1, value.$2),
      Failure() => throw QueryError('CSV parse error: ${result.errors}'),
    };
  }
  final result = parseDelimited(input, cfg);
  return switch (result) {
    Success(:final value) => value,
    Partial(:final value) => value,
    Failure() => throw QueryError('CSV parse error: ${result.errors}'),
  };
}

/// Convert header + rows into a list of maps.
List<Map<String, Object?>> _headersToMaps(
  List<String> headers,
  DelimitedDocument rows,
) => [
  for (final row in rows)
    {
      for (var i = 0; i < headers.length && i < row.length; i++)
        headers[i]: row[i],
    },
];
