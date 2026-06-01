/// CLI entry point for the Lambë query language.
///
/// Usage:
///   `lam 'expression' [file]`
///   `cat data.json | lam 'expression'`
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:lambe/lambe.dart';

import 'repl.dart' show runRepl;
import 'schema_io.dart';

void main(List<String> arguments) {
  final argParser =
      ArgParser()
        ..addFlag(
          'pretty',
          abbr: 'p',
          defaultsTo: true,
          help: 'Pretty-print output',
        )
        ..addFlag('raw', abbr: 'r', help: 'Output raw strings without quotes')
        ..addOption(
          'format',
          abbr: 'f',
          help: 'Input format',
          allowed: ['json', 'yaml', 'toml', 'hcl', 'csv', 'tsv', 'markdown'],
        )
        ..addOption(
          'to',
          abbr: 't',
          help: 'Output format',
          allowed: ['json', 'yaml', 'toml', 'csv', 'tsv', 'hcl'],
        )
        ..addOption(
          'flatten-cells',
          help:
              'CSV/TSV policy for non-scalar cells. '
              'refuse (default) rejects them; json encodes them as '
              'JSON strings inline.',
          allowed: ['refuse', 'json'],
          defaultsTo: 'refuse',
        )
        ..addOption(
          'schema',
          help:
              'Path to a JSON Schema subset file. Threads the declared '
              'shape through inference and explain. If omitted, a '
              'sibling <datafile>.schema.json is used when present.',
        )
        ..addFlag(
          'print-shape',
          help:
              'Print the inferred shape of the data as a JSON Schema. '
              'Renames the 0.8.0 --schema flag with the same meaning.',
          negatable: false,
        )
        ..addFlag(
          'explain',
          help: 'Show shape trace of the query (static analysis, no execution)',
          negatable: false,
        )
        ..addFlag(
          'explain-trivial',
          help:
              'Include trivial-result warnings in the explain report '
              '(sort_by/group_by/map/unique_by on a missing field). '
              'Implies --explain.',
          negatable: false,
        )
        ..addFlag(
          'explain-json',
          help:
              'Emit the explain report as JSON instead of the text table. '
              'Implies --explain.',
          negatable: false,
        )
        ..addFlag(
          'assert',
          help: 'Assert expression is true (exit 1 if false)',
          negatable: false,
        )
        ..addFlag(
          'interactive',
          abbr: 'i',
          help: 'Interactive REPL mode',
          negatable: false,
        )
        ..addFlag(
          'ndjson',
          help:
              'Treat input as ndjson/jsonl: one JSON document per line, '
              'evaluated independently. One result per line on stdout.',
          negatable: false,
        )
        ..addFlag(
          'null-input',
          abbr: 'n',
          help:
              'Run the query against null context with no input. Useful '
              'for value computations: `lam -n \'[1,2,3] | unique\'`.',
          negatable: false,
        )
        ..addFlag(
          'skill',
          help:
              'Print the embedded agent SKILL.md to stdout and exit. '
              'Useful for installing the skill into a tooling-agnostic '
              'agent skills directory: `lam --skill > .agents/skills/lambe/SKILL.md`.',
          negatable: false,
        )
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  final ArgResults args;
  try {
    args = argParser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    stderr.writeln();
    _usage(argParser);
    exit(1);
  }

  if (args.flag('help')) {
    _usage(argParser);
    return;
  }

  // --skill: print the embedded SKILL.md and exit. Filesystem-free so
  // it works in any environment (pub-installed, AOT, future WASM CLI),
  // and lets agent harnesses install the skill with a single command:
  //   `lam --skill > .agents/skills/lambe/SKILL.md`
  if (args.flag('skill')) {
    stdout.write(lambeSkill);
    return;
  }

  // --print-shape mode: no expression needed, just file.
  final isPrintShapeMode = args.flag('print-shape');
  final schemaPath = args.option('schema');
  final isAssertMode = args.flag('assert');
  final isInteractive = args.flag('interactive');
  // --explain-trivial and --explain-json imply --explain, so enable
  // explain mode if any of the three is set.
  final explainTrivial = args.flag('explain-trivial');
  final explainJson = args.flag('explain-json');
  final isExplainMode = args.flag('explain') || explainTrivial || explainJson;
  var isNdjsonMode = args.flag('ndjson');
  final nullInput = args.flag('null-input');

  // -n / --null-input combinations. The flag's purpose is "run the
  // query against null with no input"; combinations that take input
  // (REPL, ndjson, schema validation, assert) are nonsensical.
  if (nullInput) {
    if (isInteractive) {
      stderr.writeln('Error: -n cannot be combined with --interactive.');
      exit(1);
    }
    if (isNdjsonMode) {
      stderr.writeln('Error: -n cannot be combined with --ndjson.');
      exit(1);
    }
    if (schemaPath != null) {
      stderr.writeln('Error: -n cannot be combined with --schema.');
      exit(1);
    }
    if (isAssertMode) {
      stderr.writeln('Error: -n cannot be combined with --assert.');
      exit(1);
    }
  }

  final rest = args.rest;
  if (rest.isEmpty && !isPrintShapeMode && !isInteractive) {
    // 0.8 → 0.9 migration: --schema took a data file in 0.8 and printed
    // its shape. In 0.9 it takes a JSON Schema file (the shape printer
    // moved to --print-shape). When the argument looks like data, point
    // the user at the new flag instead of the generic usage dump.
    if (schemaPath != null && _looksLikeDataFile(schemaPath)) {
      stderr.writeln('Error: missing query expression.');
      stderr.writeln(
        '  hint: --schema is now for declaring a JSON Schema (renamed '
        'from 0.8.0).',
      );
      stderr.writeln('  To inspect data shape use: lam --print-shape <file>');
      exit(1);
    }
    stderr.writeln('Error: missing query expression.');
    stderr.writeln();
    _usage(argParser);
    exit(1);
  }

  // Interactive mode with no file and terminal stdin → no data source
  if (isInteractive && rest.isEmpty && stdin.hasTerminal) {
    stderr.writeln('Error: interactive mode requires a data file.');
    stderr.writeln('Usage: lam -i <file>');
    exit(1);
  }

  final int fileArgIndex;
  if (isInteractive && rest.length == 1) {
    fileArgIndex = 0;
  } else if (isPrintShapeMode && rest.length == 1) {
    // --print-shape is overloaded: a single positional may be either
    // a file (legacy form: `lam --print-shape data.json`) or an
    // expression (compose form: `lam --print-shape '.users'` with
    // piped or no data). Disambiguate by file existence — if rest[0]
    // names an existing file, treat it as the file; otherwise treat
    // it as an expression. The collision case (a file whose name
    // happens to be a valid lambë expression like `.users`) is
    // vanishingly unlikely; plain identifier filenames aren't valid
    // queries either.
    fileArgIndex = File(rest[0]).existsSync() ? 0 : 1;
  } else {
    fileArgIndex = 1;
  }
  // The expression sits at rest[0] when fileArgIndex isn't 0; when
  // fileArgIndex == 0 the user gave a file but no expression, so the
  // identity expression is the right default.
  final expression = (rest.isNotEmpty && fileArgIndex != 0) ? rest[0] : '.';

  // Auto-enable ndjson mode when the file extension suggests it, even
  // without an explicit --ndjson flag. Consistent with the existing
  // format auto-detection convention for .csv, .yaml, etc.
  if (!isNdjsonMode && rest.length > fileArgIndex) {
    final fpath = rest[fileArgIndex].toLowerCase();
    if (fpath.endsWith('.ndjson') ||
        fpath.endsWith('.jsonl') ||
        fpath.endsWith('.jsonlines')) {
      isNdjsonMode = true;
    }
  }

  if (isNdjsonMode) {
    if (isInteractive) {
      stderr.writeln('Error: --ndjson cannot be combined with --interactive.');
      exit(1);
    }
    if (isPrintShapeMode) {
      stderr.writeln('Error: --ndjson cannot be combined with --print-shape.');
      exit(1);
    }
    if (schemaPath != null) {
      stderr.writeln('Error: --ndjson cannot be combined with --schema.');
      exit(1);
    }
    if (isAssertMode) {
      stderr.writeln('Error: --ndjson cannot be combined with --assert.');
      exit(1);
    }
    if (isExplainMode) {
      stderr.writeln('Error: --ndjson cannot be combined with --explain.');
      exit(1);
    }
    final toArg = args.option('to');
    if (toArg != null && toArg != 'json') {
      stderr.writeln(
        'Error: --ndjson emits one compact JSON document per line; '
        '--to $toArg is not supported.',
      );
      exit(1);
    }
    _runNdjson(argParser, expression, rest, fileArgIndex);
    return;
  }
  String? input;
  String? filePath;

  if (rest.length > fileArgIndex) {
    filePath = rest[fileArgIndex];
    final file = File(filePath);
    if (!file.existsSync()) {
      stderr.writeln('Error: file not found: $filePath');
      exit(1);
    }
    input = file.readAsStringSync();
  } else if (stdin.hasTerminal) {
    // `--explain` and `--print-shape` perform static analysis and can
    // run without input — `--print-shape EXPR` falls back to inferring
    // from SAny, mirroring the explain-without-data flow. `-n` is the
    // explicit "run against null" opt-in. Every other mode requires
    // a file argument or piped stdin.
    if (!isExplainMode && !isPrintShapeMode && !nullInput) {
      stderr.writeln('Error: no input. Provide a file or pipe data via stdin.');
      stderr.writeln();
      _usage(argParser);
      exit(1);
    }
  } else {
    final buffer = StringBuffer();
    String? line;
    while ((line = stdin.readLineSync()) != null) {
      buffer.writeln(line);
    }
    // Empty stdin in static-analysis modes (--explain, --print-shape)
    // and explicit null-input mode (-n): treat as "no data" rather
    // than trying to parse the empty string as JSON. This matches the
    // no-stdin branch's contract.
    if (buffer.isEmpty) {
      if (isExplainMode || isPrintShapeMode || nullInput) {
        input = null;
      } else {
        // Empty piped stdin in evaluation mode is the same footgun as
        // a missing file argument: surface the "no input" message
        // rather than confusing the user with a JSON parse error on
        // the empty string.
        stderr.writeln(
          'Error: no input. Provide a file or pipe data via stdin.',
        );
        stderr.writeln();
        _usage(argParser);
        exit(1);
      }
    } else {
      input = buffer.toString();
    }
  }

  // Determine input format (only relevant when we have input).
  Format? format;
  final formatArg = args.option('format');
  if (input != null) {
    if (formatArg != null) {
      format = Format.values.byName(formatArg);
    } else if (filePath != null) {
      format = detectFormat(filePath) ?? sniffFormat(input);
    } else {
      format = sniffFormat(input);
    }
  }

  // Parse input if we have any.
  Object? data;
  if (input != null && format != null) {
    try {
      data = parseInput(input, format);
    } on FormatException catch (e) {
      stderr.writeln('Error: invalid ${format.name} input: ${e.message}');
      exit(1);
    } on QueryError catch (e) {
      stderr.writeln('Error: ${e.message}');
      exit(1);
    }
  }

  // -i interactive mode: start REPL
  if (isInteractive) {
    if (!stdin.hasTerminal) {
      stderr.writeln('Error: interactive mode requires a terminal.');
      stderr.writeln('Hint: use lam -i <file> without piping stdin.');
      exit(1);
    }
    final toArg = args.option('to');
    final outputFmt =
        toArg != null ? OutputFormat.values.byName(toArg) : OutputFormat.json;
    runRepl(data, format: outputFmt);
    return;
  }

  // --print-shape mode: emit the inferred shape as JSON Schema.
  // Composes with the query expression — `lam --print-shape '.users'
  // data.json` prints the shape of the result of evaluating `.users`,
  // not the whole document. With no expression, prints the document
  // shape (the legacy 0.8.0 form). Without data, falls back to
  // inferShape against SAny — same as `--explain` without data.
  if (isPrintShapeMode) {
    if (schemaPath != null) {
      stderr.writeln(
        'Error: --print-shape prints the inferred shape of the data; '
        '--schema has nothing to contribute.',
      );
      exit(1);
    }
    // No expression: print the document shape directly.
    final hasExpression = rest.isNotEmpty && fileArgIndex != 0;
    if (!hasExpression) {
      final shape = data == null ? const SAny() : shapeOf(data);
      stdout.writeln(renderJsonSchema(shape));
      return;
    }
    final LamExpr ast;
    try {
      ast = parseAst(expression);
    } on QueryError catch (e) {
      stderr.writeln('Error: ${e.message}');
      exit(1);
    }
    final Shape resultShape;
    if (data == null) {
      // Mirror --explain-without-data: infer shape statically against
      // the empty-prior SAny. The user gets the static shape of the
      // query, the same answer --explain would give.
      resultShape = inferShape(ast, const SAny());
    } else {
      try {
        final result = evaluateAst(ast, data);
        resultShape = shapeOf(result);
      } on QueryError catch (e) {
        stderr.writeln('Error: ${e.message}');
        exit(1);
      }
    }
    stdout.writeln(renderJsonSchema(resultShape));
    return;
  }

  // --explain mode: static shape trace, no execution
  if (isExplainMode) {
    final LamExpr ast;
    try {
      ast = parseAst(expression);
    } on QueryError catch (e) {
      stderr.writeln('Error: ${e.message}');
      exit(1);
    }
    // Initial shape: schema when provided (explicit or auto-detected
    // sibling), merged with shapeOf(data). Falls back to SAny / data
    // shape when no schema is available.
    final dataShape = data == null ? const SAny() : shapeOf(data);
    final Shape inputShape;
    try {
      final schema = loadSchemaForData(
        explicitSchemaPath: schemaPath,
        dataPath:
            data != null && rest.length > fileArgIndex
                ? rest[fileArgIndex]
                : null,
      );
      inputShape =
          schema == null ? dataShape : mergeSchemaWithData(schema, dataShape);
    } on QueryError catch (e) {
      stderr.writeln('Error: ${e.message}');
      exit(1);
    }
    final cellPolicy = CellPolicy.values.byName(args.option('flatten-cells')!);
    final report = explain(
      ast,
      inputShape,
      flattenCells: cellPolicy,
      includeTrivial: explainTrivial,
    );
    if (explainJson) {
      stdout.writeln(renderExplainJson(report));
    } else {
      stdout.write(renderExplain(report));
    }
    return;
  }

  // If a schema is in effect, validate it against the data before
  // evaluating. mergeSchemaWithData throws on concrete-type
  // disagreement; this gives structural validation as a side effect
  // of --schema.
  if (data != null) {
    try {
      final schema = loadSchemaForData(
        explicitSchemaPath: schemaPath,
        dataPath: rest.length > fileArgIndex ? rest[fileArgIndex] : null,
      );
      if (schema != null) {
        mergeSchemaWithData(schema, shapeOf(data));
      }
    } on QueryError catch (e) {
      stderr.writeln('Error: ${e.message}');
      exit(1);
    }
  }

  // The parsed AST is retained so that, if serialization later hits an
  // OutputShapeError, a chosen remediation can be composed with it via
  // applyBridge without re-parsing.
  final LamExpr queryAst;
  try {
    queryAst = parseAst(expression);
  } on QueryError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }
  Object? result;
  try {
    result = evaluateAst(queryAst, data);
  } on QueryError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }

  // --assert mode: check bool and exit
  if (isAssertMode) {
    if (result == true) {
      exit(0);
    } else if (result == false) {
      stderr.writeln('Assertion failed.');
      exit(1);
    } else {
      stderr.writeln(
        'Error: --assert expression must return a boolean, got ${result.runtimeType}',
      );
      exit(1);
    }
  }

  // Output
  final toArg = args.option('to');
  if (toArg != null) {
    final outputFormat = OutputFormat.values.byName(toArg);
    final cellPolicy = CellPolicy.values.byName(args.option('flatten-cells')!);
    _writeWithBridge(
      result,
      outputFormat,
      pretty: args.flag('pretty'),
      queryAst: queryAst,
      data: data,
      flattenCells: cellPolicy,
    );
  } else if (args.flag('raw') && result is String) {
    stdout.writeln(result);
  } else {
    final encoder =
        args.flag('pretty')
            ? const JsonEncoder.withIndent('  ')
            : const JsonEncoder();
    stdout.writeln(encoder.convert(result));
  }
}

/// Write [result] as [fmt]. On [OutputShapeError] with an interactive
/// terminal, prompts the user to apply one of the available
/// remediations. Non-interactive invocations print the error and exit
/// with status 1.
void _writeWithBridge(
  Object? result,
  OutputFormat fmt, {
  required bool pretty,
  required LamExpr queryAst,
  required Object? data,
  required CellPolicy flattenCells,
}) {
  try {
    stdout.writeln(
      formatOutput(result, fmt, pretty: pretty, flattenCells: flattenCells),
    );
    return;
  } on OutputShapeError catch (e) {
    if (!(stdin.hasTerminal && stdout.hasTerminal)) {
      stderr.writeln('Error: ${e.message}');
      _writeHintsCli(e.hints);
      exit(1);
    }
    final choice = _promptForRemediation(e);
    if (choice == null) {
      stderr.writeln('Error: ${e.message}');
      _writeHintsCli(e.hints);
      exit(1);
    }
    // Re-evaluate with the chosen bridge applied to the user's AST,
    // then serialize. A failure here is not re-prompted: curated
    // bridges are verified at load, so any error at this point is
    // surfaced directly.
    final bridged = applyBridge(queryAst, choice.template);
    try {
      final Object? newResult = evaluateAst(bridged, data);
      stdout.writeln(
        formatOutput(
          newResult,
          fmt,
          pretty: pretty,
          flattenCells: flattenCells,
        ),
      );
    } on QueryError catch (e2) {
      stderr.writeln('Error applying "${choice.display}": ${e2.message}');
      exit(1);
    }
  } on QueryError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }
}

/// Render [hints] in CLI form to stderr, one per line, after the
/// shape-error message. Silent when no hints are present.
void _writeHintsCli(List<Hint> hints) {
  for (final h in hints) {
    stderr.writeln('Or pass ${h.cliFlag}: ${h.explanation}');
  }
}

/// Interactive prompt for the remediations carried by an
/// [OutputShapeError].
///
/// Prints the numbered suggestions, reads a line from stdin, and
/// returns the chosen [Remediation]. Returns `null` if the user enters
/// `q`, a blank line, EOF, or an index outside the valid range.
Remediation? _promptForRemediation(OutputShapeError err) {
  stdout.writeln(err.message);
  for (final h in err.hints) {
    stdout.writeln('Or pass ${h.cliFlag}: ${h.explanation}');
  }
  stdout.writeln();
  stdout.writeln('Apply a bridge?');
  for (var i = 0; i < err.suggestions.length; i++) {
    final s = err.suggestions[i];
    stdout.writeln('  [${i + 1}] | ${s.display}    # ${s.explanation}');
  }
  stdout.writeln('  [q] cancel');
  stdout.write('> ');
  final line = stdin.readLineSync()?.trim() ?? '';
  if (line.isEmpty || line == 'q' || line == 'Q') return null;
  final pick = int.tryParse(line);
  if (pick == null || pick < 1 || pick > err.suggestions.length) {
    stderr.writeln('Unknown selection: "$line"');
    return null;
  }
  return err.suggestions[pick - 1];
}

/// Handle `--ndjson` mode: evaluate the query against each non-empty
/// line of input independently, emit one compact JSON document per
/// line.
///
/// File input is read eagerly into a list of lines (sufficient for
/// typical ndjson files). Stdin is read line by line, so `tail -f |
/// lam --ndjson` works as expected. On the first line that fails to
/// parse or evaluate, writes the error with line number to stderr and
/// exits 1; subsequent lines are not evaluated. Fail-fast matches the
/// single-document CLI's semantics and jq's default behavior.
void _runNdjson(
  ArgParser argParser,
  String expression,
  List<String> rest,
  int fileArgIndex,
) {
  final LamExpr queryAst;
  try {
    queryAst = parseAst(expression);
  } on QueryError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }

  Iterable<String> lines;
  if (rest.length > fileArgIndex) {
    final filePath = rest[fileArgIndex];
    final file = File(filePath);
    if (!file.existsSync()) {
      stderr.writeln('Error: file not found: $filePath');
      exit(1);
    }
    lines = file.readAsLinesSync();
  } else if (stdin.hasTerminal) {
    stderr.writeln('Error: --ndjson needs a file argument or piped stdin.');
    stderr.writeln();
    _usage(argParser);
    exit(1);
  } else {
    // Lazy stdin reader so `tail -f app.log | lam --ndjson ...` emits
    // each line's result as soon as it arrives, not after EOF. The
    // iterable completes when readLineSync returns null (pipe closed).
    lines = _stdinLines();
  }

  try {
    for (final result in queryNdjson(lines, queryAst)) {
      stdout.writeln(const JsonEncoder().convert(result));
    }
  } on QueryError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }
}

/// Lazy iterable over stdin lines, terminating at EOF.
Iterable<String> _stdinLines() sync* {
  String? line;
  while ((line = stdin.readLineSync()) != null) {
    yield line!;
  }
}

/// True if [path] has a data-format extension (`.json`, `.yaml`, etc.)
/// rather than the `*.schema.json` JSON-Schema convention. Used by the
/// 0.8 → 0.9 migration hint: `--schema /path/to/data.json` is almost
/// certainly stale shell history from when `--schema` printed shapes
/// (now `--print-shape`).
bool _looksLikeDataFile(String path) {
  final lower = path.toLowerCase();
  // *.schema.json is the canonical JSON Schema filename — not data.
  if (lower.endsWith('.schema.json')) return false;
  const dataExts = [
    '.json',
    '.ndjson',
    '.jsonl',
    '.jsonlines',
    '.yaml',
    '.yml',
    '.toml',
    '.tf',
    '.hcl',
    '.csv',
    '.tsv',
    '.md',
    '.markdown',
    '.proto',
  ];
  for (final ext in dataExts) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}

/// Print usage information to stderr.
void _usage(ArgParser parser) {
  stderr.writeln('Usage: lam [options] <expression> [file]');
  stderr.writeln('       lam -i <file>');
  stderr.writeln();
  stderr.writeln('Examples:');
  stderr.writeln("  lam '.name' data.json");
  stderr.writeln("  lam '.database.host' config.toml");
  stderr.writeln("  lam '.resource' main.tf");
  stderr.writeln("  cat data.yaml | lam '.users | filter(.age > 30)'");
  stderr.writeln("  lam --to yaml '.config' data.json");
  stderr.writeln("  lam --to csv '.users | map({name, age})' data.json");
  stderr.writeln("  lam '.[] | filter(.age > 30)' users.csv");
  stderr.writeln(
    "  lam '.children | filter(.type == \"heading\") | map(.level)' README.md",
  );
  stderr.writeln('  lam --schema data.json');
  stderr.writeln('  lam --assert \'.version != "0.0.0"\' pubspec.yaml');
  stderr.writeln('  lam -i data.json');
  stderr.writeln();
  stderr.writeln(parser.usage);
}
