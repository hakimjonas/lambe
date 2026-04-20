/// Extracts Lambé query expressions from human-facing docs (AI.md and the MCP
/// server's tool descriptions/instructions) and asserts that each one parses
/// and evaluates without error against a representative fixture.
///
/// If a doc advertises a syntax like `.. | filter(...)` or a feature that
/// was never implemented, this test fails. Prevents doc-drift where examples
/// reference phantom features and AI agents copy them verbatim.
library;

import 'dart:io';

import 'package:lambe/lambe.dart';
import 'package:rumil/rumil.dart';
import 'package:rumil_parsers/rumil_parsers.dart';
import 'package:test/test.dart';

void main() {
  // Fixture broad enough to exercise the examples without requiring each to
  // succeed on the same path — expressions just need to parse and either
  // return a value or a clean QueryError (type mismatch on a field that
  // doesn't exist in this fixture is acceptable; parser errors are not).
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
      {'name': 'w', 'price': 10, 'qty': 2, 'tags': <Object?>['a']},
      {'name': 'g', 'price': 25, 'qty': 1, 'tags': <Object?>['b', 'c']},
    ],
    'config': {
      'database': {'host': 'db', 'port': 5432},
      'required_field': true,
    },
    'version': '1.2.3',
    'replicas': 3,
    'project': {
      'optional-dependencies': {'dev': <Object?>['pytest']},
    },
    'dependencies': <Object?>[
      {'name': 'httpx', 'version': '0.27.0'},
    ],
    'tags': <Object?>['a', 'b'],
  };

  group('AI.md code blocks', () {
    const path = 'AI.md';
    final file = File(path);
    if (!file.existsSync()) {
      test('AI.md exists', () => fail('$path not found'));
      return;
    }
    final exprs = _extractLamExpressions(file.readAsStringSync());
    if (exprs.isEmpty) {
      test('AI.md has lambe examples', () => fail('no examples extracted'));
      return;
    }
    for (final (expr, location) in exprs) {
      test('parses: $expr [$location]', () {
        _expectParsesAndEvals(expr, fixture);
      });
    }
  });

  group('MCP server instructions and tool descriptions', () {
    // The MCP server exposes instruction text and per-tool descriptions that
    // agents consume as ground truth. Extract every embedded query example
    // and ensure each one parses.
    const path = 'bin/mcp_server.dart';
    final file = File(path);
    if (!file.existsSync()) {
      test('mcp_server.dart exists', () => fail('$path not found'));
      return;
    }
    final exprs = _extractDartStringExpressions(file.readAsStringSync());
    if (exprs.isEmpty) {
      test('mcp_server.dart has lambe examples', () {
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

/// Extracts Lambé query expressions from markdown files.
///
/// Looks inside fenced code blocks whose language tag suggests a shell
/// invocation (`bash`, `console`, `sh`) or is a plain code block. Within
/// those blocks, pulls out anything that follows `lam '...'` or is a naked
/// query starting with a dot on its own line.
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

  // Also extract from markdown table cells that contain backticked `lam '...'`
  // invocations (used heavily in AI.md's "Natural Language to Lambë" table).
  for (final match in RegExp(r'`lam[^`]*`').allMatches(md)) {
    final inside = match.group(0)!;
    final expr = _extractExprFromShellLine(
      inside.substring(1, inside.length - 1),
    );
    if (expr != null) out.add((expr, 'table cell'));
  }

  return out;
}

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

/// Pulls the query string out of `lam '...'` or `lam --flag '...'` invocations.
String? _extractExprFromShellLine(String line) {
  final m = RegExp(r"\blam\b[^']*'((?:[^'\\]|\\.)*)'").firstMatch(line);
  if (m == null) return null;
  final raw = m.group(1)!;
  // Unescape any backslash-escaped characters inside the single-quoted string.
  return raw.replaceAll(r'\|', '|').replaceAll(r"\'", "'");
}

/// Extracts Lambé query expressions from Dart string literals in MCP server
/// source. Looks for lines inside single-quoted strings that mention a
/// pipeline or start with a dot — these are the in-instruction examples
/// agents see.
List<(String, String)> _extractDartStringExpressions(String dart) {
  final out = <(String, String)>[];
  // Each continuation line in a description looks like:
  //   '  "..."  — comment'
  // or
  //   '  .something | ...'
  // Match backticked/quoted examples that clearly start with a dot.
  final doubleQuoted = RegExp(r'"((?:\.[^"\\]|\\[.a-z]|[^"\\])+)"');
  for (final match in doubleQuoted.allMatches(dart)) {
    final inner = match.group(1)!;
    // Unescape common Dart string escapes.
    final expr = inner.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
    if (!expr.startsWith('.') && !expr.startsWith('if ')) continue;
    // Skip prose fragments that merely gesture at syntax ("`. | ...`",
    // trailing pipes, open parens).
    final trimmed = expr.trim();
    if (trimmed.endsWith('|') ||
        trimmed.endsWith('...') ||
        trimmed.contains('...')) {
      continue;
    }
    // Skip non-expression content (bare field names used in prose).
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

void _expectParsesAndEvals(String expr, Object? fixture) {
  final parseResult = parse(expr);
  expect(
    parseResult,
    isA<Success<Object?, Object?>>(),
    reason: 'Failed to parse: $expr',
  );
  // Evaluate too. Type errors on fixture fields are OK (examples use various
  // shapes); parse failures and unrecognised ops are not. QueryError is the
  // recognisable type for runtime mismatches and is allowed here.
  try {
    query(expr, fixture);
  } on QueryError {
    // expected for fixture-shape mismatches; doc parse success is what we're
    // verifying
  }
}
