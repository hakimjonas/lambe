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
          allowed: [
            'json',
            'yaml',
            'toml',
            'hcl',
            'xml',
            'csv',
            'tsv',
            'markdown',
          ],
        )
        ..addOption(
          'to',
          abbr: 't',
          help: 'Output format',
          allowed: ['json', 'yaml', 'toml', 'xml', 'csv', 'tsv', 'hcl'],
        )
        ..addFlag(
          'schema',
          help: 'Show data structure without values',
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
  final String input;
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
    stderr.writeln('Error: no input. Provide a file or pipe data via stdin.');
    stderr.writeln();
    _usage(argParser);
    exit(1);
  } else {
    final buffer = StringBuffer();
    String? line;
    while ((line = stdin.readLineSync()) != null) {
      buffer.writeln(line);
    }
    input = buffer.toString();
  }

  // Determine input format
  final Format format;
  final formatArg = args.option('format');
  if (formatArg != null) {
    format = Format.values.byName(formatArg);
  } else if (filePath != null) {
    format = detectFormat(filePath) ?? sniffFormat(input);
  } else {
    format = sniffFormat(input);
  }

  // Parse input
  final Object? data;
  try {
    data = parseInput(input, format);
  } on FormatException catch (e) {
    stderr.writeln('Error: invalid ${format.name} input: ${e.message}');
    exit(1);
  } on QueryError catch (e) {
    stderr.writeln('Error: $e');
    exit(1);
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

  // Evaluate query
  final Object? result;
  try {
    result = query(expression, data);
  } on QueryError catch (e) {
    stderr.writeln('Error: $e');
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
    stdout.writeln(
      formatOutput(result, outputFormat, pretty: args.flag('pretty')),
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
  stderr.writeln("  lam '.project.dependencies' pom.xml");
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
