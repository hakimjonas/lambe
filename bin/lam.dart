/// CLI entry point for the Lambé query language.
///
/// Usage:
///   `lam 'expression' [file]`
///   `cat data.json | lam 'expression'`
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:lambe/lambe.dart';
import 'package:lambe/src/repl.dart' show runRepl;

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
        ..addFlag(
          'schema',
          help: 'Show data structure without values',
          negatable: false,
        )
        ..addFlag(
          'explain',
          help: 'Show shape trace of the query (static analysis, no execution)',
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

  // --schema mode: no expression needed, just file
  final isSchemaMode = args.flag('schema');
  final isAssertMode = args.flag('assert');
  final isInteractive = args.flag('interactive');
  final isExplainMode = args.flag('explain');

  final rest = args.rest;
  if (rest.isEmpty && !isSchemaMode && !isInteractive) {
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

  final expression = rest.isNotEmpty ? rest[0] : '.';
  final fileArgIndex =
      (isSchemaMode || isInteractive) && rest.length == 1 ? 0 : 1;
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
    // `--explain` performs static analysis and can run without input.
    // Every other mode requires a file argument or piped stdin.
    if (!isExplainMode) {
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
    input = buffer.toString();
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

  // --schema mode: show structure and exit
  if (isSchemaMode) {
    final schema = inferSchema(data);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(schema));
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
    final inputShape = data == null ? const SAny() : shapeOf(data);
    final cellPolicy = CellPolicy.values.byName(args.option('flatten-cells')!);
    final report = explain(ast, inputShape, flattenCells: cellPolicy);
    stdout.write(renderExplain(report));
    return;
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
      exit(1);
    }
    final choice = _promptForRemediation(e);
    if (choice == null) {
      stderr.writeln('Error: ${e.message}');
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

/// Interactive prompt for the remediations carried by an
/// [OutputShapeError].
///
/// Prints the numbered suggestions, reads a line from stdin, and
/// returns the chosen [Remediation]. Returns `null` if the user enters
/// `q`, a blank line, EOF, or an index outside the valid range.
Remediation? _promptForRemediation(OutputShapeError err) {
  stdout.writeln(err.message);
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
