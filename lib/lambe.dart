/// Multi-format query language for structured data.
///
/// Lambé provides a composable query DSL for JSON, YAML, TOML, HCL, CSV, TSV,
/// and Markdown, with pipeline operations, property access chains, and filter
/// predicates. Built on Rumil parser combinators, with operator precedence via
/// the Pratt combinator and postfix chains parsed as a left fold.
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

export 'src/_skill.dart' show lambeSkill;
export 'src/_version.dart' show lambeVersion;
export 'src/ast.dart';
export 'src/errors.dart';
export 'src/input.dart'
    show Format, detectFormat, sniffFormat, parseInput, mdToNative;
export 'src/mcp_payload.dart' show renderMcpShapeErrorPayload;
export 'src/output.dart'
    show OutputFormat, CellPolicy, formatOutput, inferSchema;
export 'src/schema/loader.dart' show mergeSchemaWithData;
export 'src/schema/parser.dart' show parseJsonSchema;
export 'src/schema/renderer.dart' show renderJsonSchema;
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
        SOptional,
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
  // skip normalization. Delegates to parseAst + evaluate so the parse
  // error rendering and the EvalException → QueryError shape are
  // shared, not duplicated.
  final ast = parseAst(expression);
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
///
/// For one-shot use where the expression is a string, see
/// [queryNdjsonString], which parses the expression once and delegates
/// here. Use this AST-taking variant when you've parsed the expression
/// up front (REPL session, bench harness) and want to apply it to many
/// ndjson lines without re-parsing.
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

/// Evaluate [expression] against each non-empty line of [lines]
/// independently as a JSON document.
///
/// Convenience equivalent to parsing [expression] once via [parseAst]
/// and calling [queryNdjson] with the resulting AST. The parse cost is
/// paid once, then amortized across every line. Errors flow through
/// the same `line N:` prefix machinery as [queryNdjson].
///
/// Throws [QueryError] if [expression] fails to parse, or on the first
/// per-line parse or evaluation error. Lazy in [lines]: parsing of
/// [expression] is eager (so syntax errors fire before any line is
/// read), but evaluation per line happens on demand.
Iterable<Object?> queryNdjsonString(Iterable<String> lines, String expression) {
  final ast = parseAst(expression);
  return queryNdjson(lines, ast);
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
/// Already-canonical inputs (`Map<String, Object?>`, `List<Object?>`,
/// scalars) are returned unchanged via an identity-pass check. Non-
/// canonical inputs (e.g. `Map<dynamic, dynamic>` from some third-party
/// JSON decoders) are recursively rebuilt as canonical types.
///
/// Throws [QueryError] if a map has a non-string key.
Object? _normalize(Object? value) {
  if (_isCanonical(value)) return value;
  return _rebuild(value);
}

/// Returns `true` iff [value] already matches the canonical shape the
/// evaluator expects: scalars, `Map<String, Object?>` (recursively), or
/// `List<Object?>` (recursively). The recursive walk short-circuits on
/// the first non-canonical element, so canonical inputs cost one
/// traversal and no allocation.
bool _isCanonical(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return true;
  }
  // Match the same `is List<Object?>` / `is Map<String, Object?>` checks
  // the evaluator and pipe-op specs use, so canonical-by-evaluator-rules
  // inputs always short-circuit here.
  if (value is Map<String, Object?>) {
    for (final v in value.values) {
      if (!_isCanonical(v)) return false;
    }
    return true;
  }
  if (value is List<Object?>) {
    for (final e in value) {
      if (!_isCanonical(e)) return false;
    }
    return true;
  }
  return false;
}

Object? _rebuild(Object? value) {
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

  // Before the verbose "expected ..." fallback, check whether the
  // failure matches a recognisable jq idiom and surface a targeted
  // hint instead. Keeps the error short and actionable for agents
  // trained on jq priors.
  final idiom = _jqIdiomHint(expression, offset);
  if (idiom != null) {
    return _renderParseError(expression, line, col, idiom);
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
      final jqHint = _jqPipeOpHint(word);
      if (jqHint != null) {
        return 'unknown operation "$word" after |\n  help: $jqHint';
      }
      final suggestion = _closestMatch(word, parser_.pipeOpNames);
      final hint =
          suggestion != null ? '\n  help: did you mean "$suggestion"?' : '';
      return 'unknown operation "$word" after |$hint';
    }
    // Word-based dispatch didn't fire (often because the next token
    // starts with a non-identifier char like `@`). Try the
    // idiom-detection pass against the post-pipe content before
    // falling back to the generic message.
    final pipeIdiom = _jqIdiomHint(
      expression,
      expression.length - rest.length + 1,
    );
    if (pipeIdiom != null) return pipeIdiom;
    return 'unexpected input after |';
  }
  final idiom = _jqIdiomHint(expression, offset);
  if (idiom != null) return idiom;
  final token = rest.split(RegExp(r'\s')).first;
  if (token.isNotEmpty) return 'unexpected "$token"';
  return 'unexpected input';
}

/// Hint for a jq pipe-op name that Lambé does not support. Returns null
/// for unknown names.
///
/// Fires when the model wrote `.x | empty` or `.x | select(...)` —
/// jq pipe stages Lambé rejects. The hint points at the Lambé
/// equivalent so the retry lands the right idiom.
String? _jqPipeOpHint(String word) {
  switch (word) {
    case 'select':
      return '`select(pred)` only works inside `filter(...)`; '
          'write `filter(pred)` as the pipe stage instead.';
    case 'empty':
      return '`empty` does not exist in Lambé. '
          'Use `filter(pred)` to drop items that fail a predicate.';
    case 'if':
      return '`if/then/else/end` is not a pipe stage in Lambé. '
          'Use it as an expression inside `map(...)` or `filter(...)`, '
          'or replace it with `filter(pred)`.';
    case 'not':
      return '`not` is a prefix in Lambé: write `!pred`.';
    case 'try':
      return 'Lambé has no exception model. '
          'Use `if`/`else` or shape checks (`has("k")`, '
          '`--print-shape`) instead of `try ... catch`.';
    case 'recurse':
    case 'walk':
      return 'Lambé has no recursive descent. Use explicit paths; '
          'combine `map(...)` and `flatten` for nested fan-out.';
    case 'paths':
    case 'leaf_paths':
      return 'Lambé has no `$word` op. Use `--print-shape` (CLI) or '
          '`lambe_print_shape` (MCP) to see the structure of the data.';
    case 'getpath':
      return '`getpath([...])` is not a lambé op. Lambé paths are '
          'static: write `.users[0].age` instead of '
          '`getpath(["users",0,"age"])`. For dynamic indexing, '
          'compose with `map(...)` over the path components.';
    case 'setpath':
      return '`setpath([...]; v)` is not a lambé op. Lambé does not '
          'mutate input; it produces new values. Construct the new '
          'object with `{...}` literals, or use `map(...)` / '
          '`map_values(...)` to update fields in lists / maps.';
    case 'range':
      return 'Lambé has no `range` generator. Build the list inline '
          '(`[0,1,2,...]`) or pre-compute it; lambé queries are '
          'data-driven, not generator-driven.';
    case 'limit':
    case 'nth':
      return '`$word` is not a lambé op. Use slicing `[:n]` to take a '
          'prefix, `[n:n+1]` to take an index, or `first`/`last` for '
          'the ends.';
    case 'env':
      return 'Lambé has no `env` op (queries are pure; environment '
          'access lives outside the query). Set up the values via the '
          'shell and pipe them in as data.';
    case 'gsub':
    case 'sub':
    case 'test':
    case 'match':
    case 'scan':
    case 'splits':
      return '`$word` is a regex op; lambé treats strings as opaque. '
          'Pipe through `grep` / `sed` / a regex tool before or after '
          '`lam` for regex transforms.';
    case 'tojson':
      return '`tojson` is not a lambé op. Use `as(json)` to bridge to '
          'a JSON-shaped value, or run `lam` with `-t json` (the '
          'default) to serialize the result.';
    case 'fromjson':
      return '`fromjson` is not a lambé op. Lambé parses input by '
          'format on read; for JSON-in-strings, decode upstream of '
          'lambé or use `as(json)` after coercing the wrapping shape.';
    default:
      return null;
  }
}

/// Hint for a jq idiom detected at [offset] in [expression]. Returns
/// null if the surrounding context doesn't match a known pattern.
///
/// Recognises:
/// - `[]` iterate-all (Lambé has no iterate-all; use `map(...)`).
/// - `?` optional suffix (no optional-suffix; filter or shape-check).
/// - `..` recursive descent (no recursive descent; explicit paths).
/// - `select(...)` in non-filter position (only valid inside
///   `filter(...)`).
/// - `empty` keyword (no `empty`; use `filter(pred)`).
/// - `end` from a stranded `if/then/else/end` tail.
/// - `try` / `try ... catch` (Lambé has no exception model).
/// - `recurse`, `walk` (no recursive descent; explicit paths).
/// - `paths`, `leaf_paths` (use `--print-shape` to inspect structure).
/// - `range`, `limit`, `nth` (use slicing or `first`/`last`).
/// - `@csv`, `@tsv`, `@base64` (use `as(csv)` / `as(tsv)`; base64 is
///   not supported).
String? _jqIdiomHint(String expression, int offset) {
  // `.users[]`: parser expected an index expression after `[` and
  // failed on `]`. Detect by: offset points at `]` and the previous
  // non-whitespace char is `[`.
  if (offset < expression.length && expression[offset] == ']') {
    final before = expression.substring(0, offset).trimRight();
    if (before.endsWith('[')) {
      return 'Lambé has no `[]` iterate-all. '
          'Use `map(.)` to fan out, or `map(.field)` to project. '
          'E.g. `.users | map(.name)` not `.users[].name`, '
          '`.items | map(.spec.containers) | flatten | map(.name)` '
          'for nested fan-out.';
    }
  }
  // `.foo?`: `?` immediately after an identifier or bracket.
  if (offset < expression.length && expression[offset] == '?') {
    return 'Lambé has no `?` optional-path suffix. '
        'Use `filter(has("foo")) | .foo`, or check the shape with '
        '`--print-shape` (CLI) / `lambe_print_shape` (MCP) first.';
  }
  // `..`: second `.` with no identifier.
  if (offset < expression.length && expression[offset] == '.') {
    final before = expression.substring(0, offset).trimRight();
    if (before.endsWith('.') && !before.endsWith('..')) {
      return 'Lambé has no `..` recursive descent. '
          'Use explicit paths; combine `map(...)` and `flatten` for '
          'nested fan-out.';
    }
  }
  final rest = expression.substring(offset).trimLeft();
  // `select(...)` in non-filter position. Fires anywhere — inside
  // `map(...)`, at top level, in the middle of a pipeline — since
  // `select` is only valid inside `filter(...)` in Lambé.
  if (rest.startsWith('select(') ||
      rest == 'select' ||
      (rest.startsWith('select') &&
          rest.length >= 7 &&
          !_isIdentChar(rest.codeUnitAt(6)))) {
    return '`select(pred)` is only valid inside `filter(...)` in '
        'Lambé. Replace `map(select(pred))` with `filter(pred)`, and '
        '`map(select(pred) | .field)` with '
        '`filter(pred) | map(.field)`.';
  }
  // `empty` keyword. Similar: may appear inside `map(if ... then ... else empty end)`.
  if (rest.startsWith('empty') &&
      (rest.length == 5 || !_isIdentChar(rest.codeUnitAt(5)))) {
    return 'Lambé has no `empty` keyword. '
        'Drop items with `filter(pred)` instead of '
        '`map(if pred then x else empty end)`.';
  }
  // `end` from a stranded `if/then/else/end`.
  if (rest.startsWith('end') &&
      (rest.length == 3 || !_isIdentChar(rest.codeUnitAt(3)))) {
    return '`if/then/else/end` is an expression in Lambé, not a pipe '
        'stage. Use it inside `map(...)` / `filter(...)`, and drop '
        'the `end` keyword — Lambé terminates `if` at the else branch.';
  }
  // `try` / `try ... catch`. jq's exception model has no lambé
  // analogue.
  if (_atKeyword(rest, 'try')) {
    return 'Lambé has no exception model. '
        'Use `if`/`else` or shape checks (`has("k")`, `--print-shape`) '
        'instead of `try ... catch`.';
  }
  // `recurse`, `walk` — both jq's recursive-descent operators.
  if (_atKeyword(rest, 'recurse') || _atKeyword(rest, 'walk')) {
    return 'Lambé has no recursive descent. Use explicit paths; '
        'combine `map(...)` and `flatten` for nested fan-out.';
  }
  // `paths`, `leaf_paths` — jq's path enumeration. Lambé exposes
  // structure via `--print-shape` instead.
  if (_atKeyword(rest, 'paths') || _atKeyword(rest, 'leaf_paths')) {
    return 'Lambé has no `paths`/`leaf_paths`. Use `--print-shape` '
        '(CLI) or `lambe_print_shape` (MCP) to see the structure of '
        'the data.';
  }
  // `range`, `limit`, `nth` — jq generators / slicing helpers.
  if (_atKeyword(rest, 'range')) {
    return 'Lambé has no `range` generator. Build the list inline '
        '(`[0,1,2,...]`) or pre-compute it; lambé queries are '
        'data-driven, not generator-driven.';
  }
  if (_atKeyword(rest, 'limit') || _atKeyword(rest, 'nth')) {
    final word = _atKeyword(rest, 'limit') ? 'limit' : 'nth';
    return '`$word` is not a lambé op. Use slicing `[:n]` to take a '
        'prefix, `[n:n+1]` to take an index, or `first`/`last` for '
        'the ends.';
  }
  // `@csv` / `@tsv` — jq's format strings. Lambé routes through
  // `as(csv)` / `as(tsv)` instead.
  if (rest.startsWith('@csv') || rest.startsWith('@tsv')) {
    final fmt = rest.startsWith('@csv') ? 'csv' : 'tsv';
    return 'Lambé has no `@$fmt` format string. Use `as($fmt)` to '
        'serialize a list-of-records as $fmt, or `--to $fmt` at the '
        'CLI level.';
  }
  // `@base64` — explicitly unsupported.
  if (rest.startsWith('@base64')) {
    return 'Lambé does not support `@base64` encoding/decoding. '
        'Pre-process the data outside lambé if you need it.';
  }
  // `@uri` — explicitly unsupported.
  if (rest.startsWith('@uri')) {
    return 'Lambé does not support `@uri` URL-encoding. '
        'Pre-process the data outside lambé if you need it.';
  }
  // `@html` / `@sh` / `@json` — other jq format strings.
  if (rest.startsWith('@html') ||
      rest.startsWith('@sh') ||
      rest.startsWith('@json')) {
    final fmt = RegExp(r'^@(\w+)').firstMatch(rest)?.group(1) ?? 'fmt';
    return 'Lambé has no `@$fmt` format string. '
        'Use `as(json)` for JSON shape bridges, `--to <fmt>` for '
        'output formats, or pre-process outside lambé.';
  }
  // `$ENV` / `$NAME` — jq's environment-variable / variable-binding
  // syntax. Lambé queries are pure; no in-query variables.
  if (rest.startsWith(r'$')) {
    return 'Lambé has no variable-binding (`\$NAME`) or environment '
        '(`\$ENV`) syntax. Queries are pure; environment access lives '
        'outside the query. Set up values via the shell, pipe them '
        'as data.';
  }
  // `def` — jq's user-function definition. Lambé is a bounded tree
  // transformer; user-defined functions, recursion, and closures are
  // explicit non-goals (see `doc/non-goals.md`).
  if (_atKeyword(rest, 'def')) {
    return 'Lambé has no `def` user-defined functions. The language is '
        'a bounded tree transformer by design — no `def`, no recursion, '
        'no closures. For computation that needs functions or state, '
        'compose the data outside lambé and pipe it in.';
  }
  return null;
}

/// Whether [rest] begins with [keyword] followed by a non-identifier
/// character (or end-of-string). Mirrors the `select`/`empty`/`end`
/// detection above; centralised here to keep the new cases compact.
bool _atKeyword(String rest, String keyword) {
  if (!rest.startsWith(keyword)) return false;
  if (rest.length == keyword.length) return true;
  return !_isIdentChar(rest.codeUnitAt(keyword.length));
}

bool _isIdentChar(int code) =>
    (code >= 0x30 && code <= 0x39) || // 0-9
    (code >= 0x41 && code <= 0x5a) || // A-Z
    (code >= 0x61 && code <= 0x7a) || // a-z
    code == 0x5f; // _

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
