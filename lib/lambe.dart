/// Multi-format query language for structured data.
///
/// Lambé provides a composable query DSL for JSON, YAML, TOML, HCL, CSV, TSV,
/// and Markdown, with pipeline operations, property access chains, and filter
/// predicates. Built on Rumil parser combinators with left-recursive grammar
/// support via Warth seed-growth.
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
import 'package:rumil_expressions/rumil_expressions.dart' show EvalException;

import 'src/ast.dart';
import 'src/errors.dart';
import 'src/evaluator.dart' as eval_;
import 'src/input.dart';
import 'src/input.dart' as input_;
import 'src/parser.dart' as parser_;

export 'src/_version.dart' show lambeVersion;
export 'src/ast.dart';
export 'src/errors.dart';
export 'src/input.dart'
    show Format, detectFormat, sniffFormat, parseInput, mdToNative;
export 'src/mcp_payload.dart' show renderMcpShapeErrorPayload;
export 'src/output.dart'
    show OutputFormat, CellPolicy, formatOutput, inferSchema;
export 'src/shape/shape.dart'
    show
        Shape,
        SAny,
        SNull,
        SBool,
        SNum,
        SString,
        SList,
        SMap,
        shapeOf,
        renderShape,
        shapeToJson;
export 'src/shape/check.dart'
    show
        ShapeRequirement,
        AnyShape,
        MustBeMap,
        MustBeList,
        MustBeFlatList,
        requirementFor,
        ShapeReport,
        Writable,
        NotWritable,
        Remediation,
        Hint,
        canWriteAs,
        canWriteShapeAs;
export 'src/shape/explain.dart'
    show
        ExplainReport,
        ExplainStage,
        ExplainWarning,
        WarningKind,
        explain,
        renderExplain,
        renderExplainJson;
export 'src/shape/infer.dart' show inferShape;
export 'src/shape/pipe_ops.dart'
    show
        PipeOpInfo,
        PipeOpParseKind,
        acceptsInputShape,
        inferPipeOpShape,
        pipeOpInfoFor,
        pipeOpInfoForName,
        pipeOpNames,
        pipeOpSpecs;
export 'src/shape/synthesize.dart'
    show synthesize, synthesizeWithLabels, applyBridge;

/// Parse and evaluate a query expression against [data].
///
/// The [data] may be any JSON-shaped value. Maps and lists with non-canonical
/// element types (e.g. `Map<dynamic, dynamic>` from some third-party decoders)
/// are normalized to `Map<String, Object?>` and `List<Object?>` before
/// evaluation. Map keys that are not strings throw [QueryError].
///
/// Throws [QueryError] on evaluation errors, or if the query fails to parse.
Object? query(String expression, Object? data) =>
    evaluateAst(parseAst(expression), data);

/// Parse an expression string to its [LamExpr] AST.
///
/// Throws [QueryError] on parse failure. Exposed so callers that want to
/// compose ASTs (e.g. applying a [Remediation.template] via [applyBridge])
/// can reuse the same parse path as [query].
LamExpr parseAst(String expression) {
  final result = parser_.parseQuery(expression);
  return switch (result) {
    Success<ParseError, LamExpr>(:final value) => value,
    Partial<ParseError, LamExpr>() =>
      throw QueryError(_formatParseErrors(expression, result.errors)),
    Failure<ParseError, LamExpr>() =>
      throw QueryError(_formatParseErrors(expression, result.errors)),
  };
}

/// Evaluate a parsed [ast] against [data].
///
/// Performs the same data normalization as [query]. Throws [QueryError]
/// on evaluation errors.
Object? evaluateAst(LamExpr ast, Object? data) {
  try {
    return eval_.evaluate(ast, _normalize(data));
  } on EvalException catch (e) {
    throw QueryError(e.message);
  }
}

/// Parse an input string in the given [format], then evaluate [expression].
///
/// If [format] is omitted, attempts to detect it from the content.
///
/// Throws [QueryError] on parse or evaluation errors.
/// Throws [FormatException] if JSON input is malformed.
Object? queryString(String expression, String input, {Format? format}) {
  final data = input_.parseInput(input, format ?? input_.sniffFormat(input));
  // parseInput produces canonical Map<String, Object?> / List<Object?> trees;
  // skip normalization.
  final result = parser_.parseQuery(expression);
  final ast = switch (result) {
    Success<ParseError, LamExpr>(:final value) => value,
    Partial<ParseError, LamExpr>() =>
      throw QueryError(_formatParseErrors(expression, result.errors)),
    Failure<ParseError, LamExpr>() =>
      throw QueryError(_formatParseErrors(expression, result.errors)),
  };
  try {
    return eval_.evaluate(ast, data);
  } on EvalException catch (e) {
    throw QueryError(e.message);
  }
}

/// Parse a JSON string, then evaluate [expression] against it.
///
/// Convenience alias for `queryString(expression, json, format: Format.json)`.
Object? queryJson(String expression, String json) =>
    queryString(expression, json, format: Format.json);

/// Evaluate [ast] against each non-empty line of [lines] independently
/// as a JSON document.
///
/// Each line is parsed as JSON, normalized, and evaluated in isolation.
/// No state is shared between lines; each line sees a fresh context.
/// Empty or whitespace-only lines are skipped silently.
///
/// A parse or evaluation error on any line throws [QueryError] with a
/// `line N:` prefix and stops iteration; subsequent lines are not
/// evaluated. This is the same fail-fast semantics `lam` uses at the
/// CLI. Callers that want per-line error isolation should iterate
/// their own lines and call [evaluateAst] per line with their own
/// exception handling.
///
/// Lazy: returns an [Iterable] that evaluates on demand. Safe to use
/// over large inputs as long as individual lines fit in memory.
Iterable<Object?> queryNdjson(Iterable<String> lines, LamExpr ast) sync* {
  var lineNum = 0;
  for (final raw in lines) {
    lineNum++;
    final line = raw.trim();
    if (line.isEmpty) continue;
    final Object? data;
    try {
      data = input_.parseInput(line, Format.json);
    } on QueryError catch (e) {
      throw QueryError('line $lineNum: ${e.message}');
    }
    try {
      yield eval_.evaluate(ast, data);
    } on EvalException catch (e) {
      throw QueryError('line $lineNum: ${e.message}');
    } on QueryError catch (e) {
      throw QueryError('line $lineNum: ${e.message}');
    }
  }
}

/// Parse a query expression string into a [LamExpr] AST.
///
/// Returns a Rumil [Result] which is [Success], [Partial], or [Failure].
/// Use this when you want to inspect parse errors or reuse a parsed query.
Result<ParseError, LamExpr> parse(String expression) =>
    parser_.parseQuery(expression);

/// Evaluate a pre-parsed [LamExpr] AST against [data].
///
/// Use this when parsing once and evaluating against multiple data values.
/// [data] is normalized on entry (see [query] for details).
/// Throws [QueryError] on evaluation errors.
Object? eval(LamExpr ast, Object? data) {
  try {
    return eval_.evaluate(ast, _normalize(data));
  } on EvalException catch (e) {
    throw QueryError(e.message);
  }
}

/// Normalize [value] into the canonical shape the evaluator expects.
///
/// Recursively converts any `Map` into `Map<String, Object?>` and any `List`
/// into `List<Object?>`, regardless of original element type parameters.
/// Canonical collections from `parseInput`, `jsonDecode`, and hand-written
/// typed literals round-trip through this cheaply (one traversal, no per-
/// value reconstruction of scalars).
///
/// Throws [QueryError] if a map has a non-string key.
Object? _normalize(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is List) {
    return <Object?>[for (final e in value) _normalize(e)];
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw QueryError('Map key must be a string, got ${key.runtimeType}');
      }
      result[key] = _normalize(entry.value);
    }
    return result;
  }
  return value;
}

String _formatParseErrors(String expression, List<ParseError> errors) {
  if (errors.isEmpty) return 'parse error';

  if (expression.trim().isEmpty) {
    return 'parse error: expression is empty';
  }

  final deepest = errors.reduce(
    (a, b) => b.location.offset > a.location.offset ? b : a,
  );
  final offset = deepest.location.offset;
  final line = deepest.location.line;
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
          return _renderParseError(
            expression,
            line,
            col,
            _describeLeftover(expression, offset),
          );
        }
        return _renderParseError(expression, line, col, c.message);
    }
  }

  final what =
      expected.isEmpty
          ? 'unexpected input'
          : 'expected ${_joinExpected(expected)}';
  return _renderParseError(expression, line, col, what);
}

/// Render a parse-error message with a line-aware source excerpt and
/// caret.
///
/// Single-line expressions produce a jq-style three-line block: the
/// `parse error` header, the source indented by two spaces, and a
/// caret under column [col]. Multi-line expressions extend this with
/// the previous line (if any) and the next line (if any), to give a
/// reader enough context to locate the error without reprinting the
/// full query. Line numbers are prefixed to every context line so the
/// offending line stays unambiguous.
String _renderParseError(String expression, int line, int col, String message) {
  final lines = _splitLines(expression);
  final idx = line - 1;
  final gutterWidth = '${lines.length}'.length;
  final buf = StringBuffer('parse error at line $line, column $col: $message');

  String prefix(int lineNo) => '  ${'$lineNo'.padLeft(gutterWidth)} | ';

  if (idx - 1 >= 0) {
    buf.write('\n${prefix(line - 1)}${lines[idx - 1]}');
  }
  buf.write('\n${prefix(line)}${lines[idx]}');
  buf.write('\n${' ' * prefix(line).length}${' ' * (col - 1)}^');
  if (idx + 1 < lines.length) {
    buf.write('\n${prefix(line + 1)}${lines[idx + 1]}');
  }
  return buf.toString();
}

/// Split [source] into lines without trailing newline characters.
///
/// Handles `\n`, `\r\n`, and a trailing newline. Returns `['']` for an
/// empty source so callers can safely index.
List<String> _splitLines(String source) {
  if (source.isEmpty) return const [''];
  final lines = source.split(RegExp(r'\r?\n'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines.isEmpty ? const [''] : lines;
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
