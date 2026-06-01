/// Extracts Lambë query expressions from human-facing docs (AGENTS.md
/// and the MCP server's tool descriptions and instructions), then asserts
/// each one parses against a representative fixture.
///
/// Guards against doc drift where examples reference features the parser
/// does not implement. LLM-drafted examples are especially prone to this
/// (they autocomplete idioms from jq/XPath).
library;

import 'dart:io';

import 'package:lambe/lambe.dart';
import 'package:rumil/rumil.dart';
import 'package:rumil_parsers/rumil_parsers.dart';
import 'package:test/test.dart';

void main() {
  final fixture = <String, Object?>{
    'database': {'host': 'localhost', 'port': 5432},
    'users': <Object?>[
      {
        'name': 'Alice',
        'age': 34,
        'active': true,
        'role': 'admin',
        'email': 'alice@example.com',
        'dept': 'eng',
        'verified': true,
      },
      {
        'name': 'Bob',
        'age': 28,
        'active': false,
        'role': 'viewer',
        'dept': 'ops',
        'verified': false,
      },
      {
        'name': 'Carol',
        'age': 45,
        'active': true,
        'role': 'editor',
        'dept': 'eng',
        'verified': true,
      },
    ],
    'items': <Object?>[
      {
        'name': 'w',
        'price': 10,
        'qty': 2,
        'tags': <Object?>['a'],
      },
      {
        'name': 'g',
        'price': 25,
        'qty': 1,
        'tags': <Object?>['b', 'c'],
      },
    ],
    'config': {
      'database': {'host': 'db', 'port': 5432},
      'required_field': true,
    },
    'version': '1.2.3',
    'replicas': 3,
    'project': {
      'optional-dependencies': {
        'dev': <Object?>['pytest'],
      },
    },
    'dependencies': <Object?>[
      {'name': 'httpx', 'version': '0.27.0'},
    ],
    'tags': <Object?>['a', 'b'],
  };

  group('AGENTS.md code blocks', () {
    const path = 'AGENTS.md';
    final file = File(path);
    if (!file.existsSync()) {
      test('AGENTS.md exists', () => fail('$path not found'));
      return;
    }
    final exprs = _extractLamExpressions(file.readAsStringSync());
    if (exprs.isEmpty) {
      test('AGENTS.md has lambë examples', () => fail('no examples extracted'));
      return;
    }
    for (final (expr, location) in exprs) {
      test('parses: $expr [$location]', () {
        _expectParsesAndEvals(expr, fixture);
      });
    }
  });

  group('MCP server instructions and tool descriptions', () {
    const path = 'bin/mcp_server.dart';
    final file = File(path);
    if (!file.existsSync()) {
      test('mcp_server.dart exists', () => fail('$path not found'));
      return;
    }
    final exprs = _extractDartStringExpressions(file.readAsStringSync());
    if (exprs.isEmpty) {
      test('mcp_server.dart has lambë examples', () {
        fail('no examples extracted');
      });
      return;
    }
    for (final (expr, location) in exprs) {
      test('parses: $expr [$location]', () {
        _expectParsesAndEvals(expr, fixture);
      });
    }
  });
}

/// Extracts `lam '...'` invocations from fenced code blocks and inline
/// backticked table cells in the given Markdown source.
///
/// Fenced blocks are restricted to shell-flavoured languages (`bash`, `sh`,
/// `console`, or untagged). Every matched expression is returned with a
/// location tag for test-name reporting.
List<(String, String)> _extractLamExpressions(String md) {
  final result = parseMarkdown(md);
  final doc = switch (result) {
    Success(:final value) || Partial(:final value) => mdToNative(value),
    Failure() => null,
  };
  if (doc is! Map<String, Object?>) return [];
  final out = <(String, String)>[];
  _walkForCodeBlocks(doc, (block) {
    final lang = block['language'] as String?;
    final code = (block['code'] as String?) ?? '';
    if (lang != null && lang != 'bash' && lang != 'sh' && lang != 'console') {
      return;
    }
    for (final line in code.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final expr = _extractExprFromShellLine(trimmed);
      if (expr != null) out.add((expr, 'code block'));
    }
  });

  for (final match in RegExp(r'`lam[^`]*`').allMatches(md)) {
    final inside = match.group(0)!;
    final expr = _extractExprFromShellLine(
      inside.substring(1, inside.length - 1),
    );
    if (expr != null) out.add((expr, 'table cell'));
  }

  return out;
}

/// Walks the Markdown AST and invokes [visit] on every `code_block` node.
void _walkForCodeBlocks(
  Object? node,
  void Function(Map<String, Object?>) visit,
) {
  if (node is Map<String, Object?>) {
    if (node['type'] == 'code_block') visit(node);
    for (final child in (node['children'] as List<Object?>? ?? const [])) {
      _walkForCodeBlocks(child, visit);
    }
    for (final item in (node['items'] as List<Object?>? ?? const [])) {
      _walkForCodeBlocks(item, visit);
    }
  } else if (node is List<Object?>) {
    for (final item in node) {
      _walkForCodeBlocks(item, visit);
    }
  }
}

/// Pulls the query string out of a `lam '...'` or `lam --flag '...'` call.
///
/// Returns `null` if the line does not contain a recognisable invocation.
String? _extractExprFromShellLine(String line) {
  final m = RegExp(r"\blam\b[^']*'((?:[^'\\]|\\.)*)'").firstMatch(line);
  if (m == null) return null;
  final raw = m.group(1)!;
  return raw.replaceAll(r'\|', '|').replaceAll(r"\'", "'");
}

/// Extracts Lambë query expressions from double-quoted Dart string literals.
///
/// Targets the tool descriptions and instruction text in `bin/mcp_server.dart`,
/// where embedded examples appear as nested `"..."` within outer `'...'`
/// description strings. Filters out prose fragments that merely gesture at
/// syntax (trailing `|`, `...` ellipses, bare field names).
List<(String, String)> _extractDartStringExpressions(String dart) {
  final out = <(String, String)>[];
  final doubleQuoted = RegExp(r'"((?:\.[^"\\]|\\[.a-z]|[^"\\])+)"');
  for (final match in doubleQuoted.allMatches(dart)) {
    final inner = match.group(1)!;
    final expr = inner.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
    if (!expr.startsWith('.') && !expr.startsWith('if ')) continue;
    final trimmed = expr.trim();
    if (trimmed.endsWith('|') ||
        trimmed.endsWith('...') ||
        trimmed.contains('...')) {
      continue;
    }
    if (!trimmed.contains('|') &&
        !trimmed.contains('[') &&
        !trimmed.contains('(') &&
        !RegExp(r'\.\w').hasMatch(trimmed)) {
      continue;
    }
    out.add((trimmed, 'mcp string'));
  }
  return out;
}

/// Asserts [expr] parses. Evaluation errors from fixture-shape mismatches
/// are tolerated: the test's purpose is to catch parse failures, which
/// indicate phantom features or typos in docs.
void _expectParsesAndEvals(String expr, Object? fixture) {
  final parseResult = parse(expr);
  expect(
    parseResult,
    isA<Success<Object?, Object?>>(),
    reason: 'Failed to parse: $expr',
  );
  try {
    query(expr, fixture);
  } on QueryError {
    // Fixture-shape mismatches are not failures here.
  }
}
