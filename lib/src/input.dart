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

  /// CommonMark Markdown.
  markdown,
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
  Format.markdown => _parseMd(input),
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
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
    return Format.markdown;
  }
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
  if (trimmed.startsWith('#') ||
      trimmed.startsWith('- ') ||
      trimmed.startsWith('* ')) {
    return Format.markdown;
  }
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

/// Parse CommonMark Markdown into queryable native Dart types.
Object? _parseMd(String input) {
  final result = parseMarkdown(input);
  return switch (result) {
    Success(:final value) => mdToNative(value),
    Partial(:final value) => mdToNative(value),
    Failure() => throw QueryError('Markdown parse error: ${result.errors}'),
  };
}

/// Convert an [MdDocument] into queryable native Dart types.
///
/// Every node becomes a map with a `type` discriminator. Container nodes
/// include a `children` list; leaf nodes carry their content directly.
Object? mdToNative(MdDocument doc) => {
  'type': 'document',
  'children': doc.children.map(_nodeToNative).toList(),
};

Object? _nodeToNative(MdNode node) => switch (node) {
  MdDocument(:final children) => {
    'type': 'document',
    'children': children.map(_nodeToNative).toList(),
  },
  MdHeading(:final level, :final children) => {
    'type': 'heading',
    'level': level,
    'children': children.map(_nodeToNative).toList(),
  },
  MdParagraph(:final children) => {
    'type': 'paragraph',
    'children': children.map(_nodeToNative).toList(),
  },
  MdBlockquote(:final children) => {
    'type': 'blockquote',
    'children': children.map(_nodeToNative).toList(),
  },
  MdList(:final ordered, :final start, :final tight, :final items) => {
    'type': 'list',
    'ordered': ordered,
    if (start != null) 'start': start,
    'tight': tight,
    'items': items.map(_nodeToNative).toList(),
  },
  MdListItem(:final children) => {
    'type': 'list_item',
    'children': children.map(_nodeToNative).toList(),
  },
  MdCodeBlock(:final language, :final code) => {
    'type': 'code_block',
    if (language != null) 'language': language,
    'code': code,
  },
  MdHtmlBlock(:final html) => {'type': 'html_block', 'html': html},
  MdThematicBreak() => {'type': 'thematic_break'},
  MdText(:final text) => {'type': 'text', 'text': text},
  MdEmphasis(:final children) => {
    'type': 'emphasis',
    'children': children.map(_nodeToNative).toList(),
  },
  MdStrong(:final children) => {
    'type': 'strong',
    'children': children.map(_nodeToNative).toList(),
  },
  MdLink(:final href, :final title, :final children) => {
    'type': 'link',
    'href': href,
    if (title != null) 'title': title,
    'children': children.map(_nodeToNative).toList(),
  },
  MdImage(:final src, :final alt, :final title) => {
    'type': 'image',
    'src': src,
    'alt': alt,
    if (title != null) 'title': title,
  },
  MdCode(:final code) => {'type': 'code', 'code': code},
  MdHtmlInline(:final html) => {'type': 'html_inline', 'html': html},
  MdHardBreak() => {'type': 'hard_break'},
  MdSoftBreak() => {'type': 'soft_break'},
};

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
