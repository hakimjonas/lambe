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
      throw QueryError('Parse error: ${result.errors}'),
    Failure<ParseError, LamExpr>() =>
      throw QueryError('Parse error: ${result.errors}'),
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
