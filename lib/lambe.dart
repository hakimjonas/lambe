/// Universal query language for structured data.
///
/// Lambé provides a composable query DSL for JSON, YAML, TOML, and HCL, with
/// pipeline operations, property access chains, and filter predicates. Built
/// on Rumil parser combinators with left-recursive grammar support via Warth
/// seed-growth.
///
/// ```dart
/// import 'package:lambe/lambe.dart';
///
/// final name = query('.users[0].name', data);
/// final active = queryString('.users | filter(.active)', jsonString);
/// final host = queryString('.database.host', tomlString, format: Format.toml);
/// ```
library;

import 'package:rumil/rumil.dart';

import 'src/ast.dart';
import 'src/errors.dart';
import 'src/evaluator.dart' as eval_;
import 'src/input.dart';
import 'src/input.dart' as input_;
import 'src/parser.dart' as parser_;

export 'src/ast.dart';
export 'src/errors.dart';
export 'src/input.dart' show Format, detectFormat, sniffFormat, parseInput;
export 'src/output.dart' show OutputFormat, formatOutput, inferSchema;

/// Parse and evaluate a query expression against [data].
///
/// The [data] should be a decoded value (`Map<String, Object?>`,
/// `List<Object?>`, `String`, `num`, `bool`, or `null`).
///
/// Throws [QueryError] on evaluation errors, or if the query fails to parse.
Object? query(String expression, Object? data) {
  final result = parser_.parseQuery(expression);
  return switch (result) {
    Success<ParseError, LamExpr>(:final value) => eval_.evaluate(value, data),
    Partial<ParseError, LamExpr>() =>
      throw QueryError(_formatParseErrors(expression, result.errors)),
    Failure<ParseError, LamExpr>() =>
      throw QueryError(_formatParseErrors(expression, result.errors)),
  };
}

/// Parse an input string in the given [format], then evaluate [expression].
///
/// If [format] is omitted, attempts to detect it from the content.
/// Supports JSON, YAML, and TOML.
///
/// Throws [QueryError] on parse or evaluation errors.
/// Throws [FormatException] if JSON input is malformed.
Object? queryString(String expression, String input, {Format? format}) => query(
  expression,
  input_.parseInput(input, format ?? input_.sniffFormat(input)),
);

/// Parse a JSON string, then evaluate [expression] against it.
///
/// Convenience alias for `queryString(expression, json, format: Format.json)`.
Object? queryJson(String expression, String json) =>
    queryString(expression, json, format: Format.json);

/// Parse a query expression string into a [LamExpr] AST.
///
/// Returns a Rumil [Result] which is [Success], [Partial], or [Failure].
/// Use this when you want to inspect parse errors or reuse a parsed query.
Result<ParseError, LamExpr> parse(String expression) =>
    parser_.parseQuery(expression);

/// Evaluate a pre-parsed [LamExpr] AST against [data].
///
/// Use this when parsing once and evaluating against multiple data values.
/// Throws [QueryError] on evaluation errors.
Object? eval(LamExpr ast, Object? data) => eval_.evaluate(ast, data);

String _formatParseErrors(String expression, List<ParseError> errors) {
  if (errors.isEmpty) return 'parse error';

  final deepest = errors.reduce(
    (a, b) => b.location.offset > a.location.offset ? b : a,
  );
  final offset = deepest.location.offset;
  final col = deepest.location.column;

  final expected = <String>{};
  for (final e in errors) {
    if (e.location.offset != offset) continue;
    switch (e) {
      case final Unexpected u:
        expected.addAll(u.expected);
      case final EndOfInput eoi:
        expected.add(eoi.expected);
      case final CustomError c:
        if (c.message == 'Expected end of input') {
          return 'parse error at column $col: '
              '${_describeLeftover(expression, offset)}\n'
              '  $expression\n'
              '  ${' ' * (col - 1)}^';
        }
        return 'parse error at column $col: ${c.message}\n'
            '  $expression\n'
            '  ${' ' * (col - 1)}^';
    }
  }

  final what =
      expected.isEmpty
          ? 'unexpected input'
          : 'expected ${_joinExpected(expected)}';

  return 'parse error at column $col: $what\n'
      '  $expression\n'
      '  ${' ' * (col - 1)}^';
}

String _describeLeftover(String expression, int offset) {
  final rest = expression.substring(offset).trimLeft();
  if (rest.startsWith('|')) {
    final after = rest.substring(1).trimLeft();
    if (after.isEmpty) return 'unexpected | at end of expression';
    final word = after.split(RegExp(r'[^a-zA-Z_]')).first;
    if (word.isNotEmpty && !parser_.pipeOpNames.contains(word)) {
      final suggestion = _closestMatch(word, parser_.pipeOpNames);
      final hint =
          suggestion != null ? '\n  help: did you mean "$suggestion"?' : '';
      return 'unknown operation "$word" after |$hint';
    }
    return 'unexpected input after |';
  }
  final token = rest.split(RegExp(r'\s')).first;
  if (token.isNotEmpty) return 'unexpected "$token"';
  return 'unexpected input';
}

String? _closestMatch(String input, List<String> candidates) {
  final maxDist = (input.length / 2).ceil().clamp(1, 3);
  String? best;
  var bestDist = maxDist + 1;
  for (final c in candidates) {
    final d = _editDistance(input, c);
    if (d < bestDist) {
      bestDist = d;
      best = c;
    }
  }
  return best;
}

int _editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final prev = List.generate(b.length + 1, (i) => i);
  final curr = List.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      curr[j] = [
        curr[j - 1] + 1,
        prev[j] + 1,
        prev[j - 1] + cost,
      ].reduce((a, b) => a < b ? a : b);
    }
    prev.setAll(0, curr);
  }
  return curr[b.length];
}

String _joinExpected(Set<String> items) {
  final list = items.toList()..sort();
  if (list.length == 1) return list[0];
  if (list.length == 2) return '${list[0]} or ${list[1]}';
  return '${list.sublist(0, list.length - 1).join(', ')}, or ${list.last}';
}
