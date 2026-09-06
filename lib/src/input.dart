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

  /// CSV (RFC 4180, auto-detected dialect).
  csv,

  /// TSV (tab-separated values).
  tsv,

  /// CommonMark Markdown.
  markdown,
}

/// Names of all supported input formats, derived from [Format.values].
///
/// Single source of truth for CLI option validation, MCP schema enums,
/// and any other surface that enumerates formats. Never hardcode the
/// list again; adding a [Format] value propagates automatically.
List<String> formatNames() => [for (final f in Format.values) f.name];

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
  Format.csv => _parseDelimited(input, null),
  Format.tsv => _parseDelimited(input, _detectTsvDialect(input)),
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
  if (lower.endsWith('.csv')) return Format.csv;
  if (lower.endsWith('.tsv') || lower.endsWith('.tab')) return Format.tsv;
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
    return Format.markdown;
  }
  return null;
}

/// TOML table header: `[section]` or array-of-tables `[[section]]`,
/// occupying a whole line.
final RegExp _tomlTableHeader = RegExp(r'^\[[A-Za-z0-9_\.\-]+\]\s*(#.*)?$');
final RegExp _tomlTableArrayHeader = RegExp(
  r'^\[\[[A-Za-z0-9_\.\-]+\]\]\s*(#.*)?$',
);

/// A TOML/HCL-style assignment: `key = value` or a quoted key. Key
/// characters stop before whitespace so prose like "This is: a test"
/// does not match.
final RegExp _configAssignment = RegExp(
  r'''^["']?[A-Za-z_][A-Za-z0-9_\.\-]*["']?\s*[:=]''',
);

/// A TOML-only assignment (TOML has no `key:` form).
final RegExp _tomlAssignment = RegExp(
  r'''^["']?[A-Za-z0-9_][A-Za-z0-9_\.\-]*["']?\s*=''',
);

/// An HCL block opener: a line whose last significant character is
/// `{` (optionally followed by a trailing comment). TOML inline
/// tables close on the same line, so they never match.
final RegExp _hclBlockOpen = RegExp(r'''\{(\s*#.*|\s*//.*)?$''');

/// Guess format by sniffing the input content.
///
/// Falls back to [Format.json] if uncertain.
Format sniffFormat(String input) {
  final trimmed = input.trimLeft();
  if (trimmed.isEmpty) return Format.json;

  // Leading `[` is ambiguous: a TOML table header and a JSON array
  // both start with one. Commit to TOML only when the first line is a
  // well-formed table header followed by TOML-looking content.
  if (trimmed.startsWith('[') && _looksLikeTomlTableDoc(trimmed)) {
    return Format.toml;
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return Format.json;
  if (trimmed.startsWith('---')) return Format.yaml;

  // Leading comment lines carry no format signal: `# comment` above a
  // config body is documentation, not a Markdown heading. Classify by
  // what follows the comments; a document that is all comments (or
  // whose body is prose) is Markdown.
  if (trimmed.startsWith('#')) {
    final body = _stripLeadingCommentLines(trimmed);
    if (body.isNotEmpty && _looksLikeConfig(body)) {
      return _sniffBody(body);
    }
    return Format.markdown;
  }

  return _sniffBody(trimmed);
}

/// Classify comment-free configuration content.
Format _sniffBody(String text) {
  if (text.contains(': ')) return Format.yaml;
  if (text.contains(' = ')) {
    // A line that opens a block (`{` at end of line) is HCL block
    // syntax. A same-line inline table (`x = { a = 1 }`) closes on the
    // line it opens, which is TOML syntax, not HCL.
    return _hasBlockOpen(text) ? Format.hcl : Format.toml;
  }
  if (text.contains(' {')) return Format.hcl;
  if (text.startsWith('- ') || text.startsWith('* ')) {
    return Format.markdown;
  }
  return Format.json;
}

/// True when [text] starts with a TOML table header and carries
/// TOML-looking content after it. A bare bracket line with no follow-up
/// (`[2026]`) stays with JSON, where it is a valid one-element array.
bool _looksLikeTomlTableDoc(String text) {
  final lines = text.split('\n');
  final first = lines.first.trimRight();
  if (!_tomlTableHeader.hasMatch(first) &&
      !_tomlTableArrayHeader.hasMatch(first)) {
    return false;
  }
  if (lines.length == 1) return false;
  return lines.skip(1).any((line) {
    final l = line.trim();
    if (l.isEmpty || l.startsWith('#')) return false;
    return _tomlTableHeader.hasMatch(l) ||
        _tomlTableArrayHeader.hasMatch(l) ||
        _tomlAssignment.hasMatch(l);
  });
}

/// Drop leading blank and full-line `#` comment lines.
String _stripLeadingCommentLines(String text) {
  final lines = text.split('\n');
  var i = 0;
  while (i < lines.length) {
    final l = lines[i].trim();
    if (l.isEmpty || l.startsWith('#')) {
      i++;
      continue;
    }
    break;
  }
  return i == 0 ? text : lines.skip(i).join('\n');
}

/// True when any content line of [text] looks like a configuration
/// assignment (`key =`, `key:`, or a `[table]` header).
bool _looksLikeConfig(String text) {
  for (final line in text.split('\n')) {
    final l = line.trim();
    if (l.isEmpty || l.startsWith('#')) continue;
    if (_tomlTableHeader.hasMatch(l)) return true;
    if (_tomlTableArrayHeader.hasMatch(l)) return true;
    if (_configAssignment.hasMatch(l)) return true;
  }
  return false;
}

/// True when any line of [text] ends with an open-block `{`.
bool _hasBlockOpen(String text) =>
    text.split('\n').any((line) => _hclBlockOpen.hasMatch(line.trimRight()));

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

/// Detect a TSV dialect by reusing [detectDialect]'s header and quote
/// inference, but force the tab delimiter.
///
/// The file extension (or explicit `Format.tsv`) is the strongest signal
/// that fields are tab-separated; `detectDialect` would otherwise be free
/// to pick `,` or `;` if the sample is ambiguous. Header detection still
/// runs because TSV's documented model matches CSV: a header row produces
/// `List<Map<String, Object?>>`.
DelimitedConfig _detectTsvDialect(String input) {
  final detected = detectDialect(input);
  return DelimitedConfig(
    delimiter: '\t',
    quote: detected.quote,
    hasHeader: detected.hasHeader,
  );
}

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
///
/// Uses [parseMarkdownWithFrontmatter] so a leading `---` YAML
/// frontmatter block is detected and surfaced as a sibling
/// `frontmatter` field on the document, instead of being absorbed into
/// the body as prose. Files without frontmatter parse identically to
/// the previous [parseMarkdown]-only path.
Object? _parseMd(String input) {
  final result = parseMarkdownWithFrontmatter(input);
  return switch (result) {
    Success(:final value) => mdToNativeWithFrontmatter(value),
    Partial(:final value) => mdToNativeWithFrontmatter(value),
    Failure() => throw QueryError('Markdown parse error: ${result.errors}'),
  };
}

/// Convert a [MarkdownDocument] (Markdown body + optional YAML
/// frontmatter) into queryable native Dart types.
///
/// When frontmatter is absent the result matches [mdToNative]
/// byte-for-byte — `{type: 'document', children: [...]}`. When present,
/// a sibling `frontmatter` key carries the parsed YAML as native Dart
/// values (maps, lists, scalars), addressable via the usual lambë path
/// access (e.g. `.frontmatter.title`).
///
/// Frontmatter is decoded via rumil_parsers' [yamlToNative], which
/// resolves YAML anchors and aliases before flattening — so a
/// frontmatter block that happens to use them (rare but valid)
/// queries identically to inline-only YAML.
Map<String, Object?> mdToNativeWithFrontmatter(MarkdownDocument doc) {
  final body = mdToNative(doc.document);
  final fm = doc.frontmatter;
  if (fm == null) return body as Map<String, Object?>;
  return {
    'type': 'document',
    'frontmatter': yamlToNative(fm),
    'children': (body as Map<String, Object?>)['children'],
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
