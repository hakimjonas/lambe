/// Lambé REPL - interactive query exploration.
///
/// Provides an interactive read-eval-print loop for exploring structured data.
/// Supports tab completion on field names and pipeline operations, multi-line
/// input via `\` continuation or unclosed brackets, and REPL commands
/// prefixed with `:`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rumil/rumil.dart';

import '../lambe.dart';
import 'completer.dart';
import 'readline.dart';

/// Run the interactive REPL with [data].
///
/// Reads queries from the terminal, evaluates them against [data], and
/// prints results. The [format] controls the default output format.
///
/// Supports REPL commands (`:schema`, `:to`, `:load`, etc.), tab completion,
/// history navigation, and multi-line input.
void runRepl(Object? data, {OutputFormat format = OutputFormat.json}) {
  stdout.writeln('lambe v0.1.0 - type :help for commands, :q to quit');
  stdout.writeln('Data loaded: ${_briefDescription(data)}');
  stdout.writeln();

  var currentData = data;
  var outputFormat = format;
  var pretty = true;
  var raw = false;

  final history = _loadHistory();
  final rl = ReadLine(
    complete: (text, cursor) => complete(text, cursor, currentData),
    history: history,
  );

  for (;;) {
    final input = _readMultiLine(rl, history);
    if (input == null) break;

    final trimmed = input.trim();
    if (trimmed.isEmpty) continue;

    if (trimmed.startsWith(':')) {
      final parts = trimmed.substring(1).split(RegExp(r'\s+'));
      final command = parts.first;
      final arg = parts.length > 1 ? parts.skip(1).join(' ') : null;

      switch (command) {
        case 'schema':
          stdout.writeln(
            const JsonEncoder.withIndent(
              '  ',
            ).convert(inferSchema(currentData)),
          );

        case 'to' when arg != null:
          final fmt =
              OutputFormat.values.where((f) => f.name == arg).firstOrNull;
          if (fmt != null) {
            outputFormat = fmt;
            stdout.writeln('Output format: ${fmt.name}');
          } else {
            stderr.writeln(
              'Unknown format: $arg (use json, yaml, toml, xml, csv, tsv, hcl)',
            );
          }

        case 'to':
          stderr.writeln('Usage: :to <json|yaml|toml|xml|csv>');

        case 'raw':
          raw = !raw;
          stdout.writeln('Raw output: ${raw ? "on" : "off"}');

        case 'pretty':
          pretty = !pretty;
          stdout.writeln('Pretty-printing: ${pretty ? "on" : "off"}');

        case 'load' when arg != null:
          final loaded = _loadFile(arg);
          if (loaded != null) {
            currentData = loaded;
            stdout.writeln('Data loaded: ${_briefDescription(currentData)}');
          }

        case 'load':
          stderr.writeln('Usage: :load <file>');

        case 'help' || 'h':
          _printHelp();

        case 'quit' || 'q':
          return;

        case 'history':
          for (final (i, entry) in history.indexed) {
            stdout.writeln('  ${i + 1}: $entry');
          }

        default:
          stderr.writeln(
            'Unknown command: :$command - type :help for available commands',
          );
      }
      continue;
    }

    final stopwatch = Stopwatch()..start();
    try {
      final result = query(trimmed, currentData);
      stopwatch.stop();
      final elapsed = stopwatch.elapsedMilliseconds;

      final output = _formatResult(
        result,
        outputFormat,
        pretty: pretty,
        raw: raw,
      );
      if (elapsed >= 100) {
        stdout.writeln('[${elapsed}ms] $output');
      } else {
        stdout.writeln(output);
      }
    } on QueryError catch (e) {
      stderr.writeln('Error: ${e.message}');
    } on Exception catch (e) {
      stderr.writeln('Error: $e');
    }
  }
}

/// Read a possibly multi-line expression from [rl].
///
/// Returns `null` on EOF. Continues reading when the input ends with `\`
/// or has unclosed brackets. Adds the complete assembled query to [history]
/// (with deduplication).
String? _readMultiLine(ReadLine rl, List<String> history) {
  final first = rl('lambe> ');
  if (first == null) return null;
  if (first.isEmpty) return '';
  final lines = [first];
  while (_needsContinuation(lines.join('\n'))) {
    final next = rl('...> ');
    if (next == null || next.isEmpty) break;
    lines.add(next);
  }

  final result = lines
      .map((l) {
        final trimmed = l.trimRight();
        return trimmed.endsWith('\\')
            ? trimmed.substring(0, trimmed.length - 1).trimRight()
            : l;
      })
      .join(' ');

  if (result.trim().isNotEmpty) {
    if (history.isEmpty || history.last != result) {
      history.add(result);
      _saveHistory(history);
    }
  }

  return result;
}

/// Check if [text] needs continuation (trailing `\` or unclosed brackets).
///
/// Uses the actual Rumil parser: a [Partial] result from [parse] means
/// `.recover()` fired on a missing bracket - the expression is incomplete.
/// This handles strings, interpolation, and all syntax correctly.
bool _needsContinuation(String text) {
  if (text.trimRight().endsWith('\\')) return true;
  final cleaned = text.replaceAll(RegExp(r'\\\n'), ' ');
  return parse(cleaned) is Partial;
}

/// Path to the history file.
final String _historyPath = '${Platform.environment['HOME']}/.lambe_history';

/// Maximum number of history entries to persist.
const _maxHistory = 500;

/// Load history from `~/.lambe_history`, returning an empty list on error.
List<String> _loadHistory() {
  try {
    final file = File(_historyPath);
    if (!file.existsSync()) return [];
    return file.readAsLinesSync().where((l) => l.isNotEmpty).toList();
  } on Exception {
    return [];
  }
}

/// Save [history] to `~/.lambe_history`, keeping the last [_maxHistory] entries.
void _saveHistory(List<String> history) {
  try {
    final entries =
        history.length > _maxHistory
            ? history.sublist(history.length - _maxHistory)
            : history;
    File(_historyPath).writeAsStringSync('${entries.join('\n')}\n');
  } on Exception {
    // ignore
  }
}

String _formatResult(
  Object? result,
  OutputFormat format, {
  required bool pretty,
  required bool raw,
}) {
  if (raw && result is String) return result;

  if (result is List<Object?> && result.length > 10) {
    final truncated = result.sublist(0, 10);
    final rest = result.length - 10;
    return '${_encode(truncated, format, pretty: pretty)}\n... and $rest more';
  }

  return _encode(result, format, pretty: pretty);
}

String _encode(Object? value, OutputFormat format, {required bool pretty}) {
  if (format != OutputFormat.json) {
    return formatOutput(value, format, pretty: pretty);
  }
  if (stdout.hasTerminal && pretty) {
    return _colorJson(value, 0);
  }
  final encoder =
      pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
  return encoder.convert(value);
}

const _reset = '\x1b[0m';
const _dim = '\x1b[2m';
const _cyan = '\x1b[36m';
const _green = '\x1b[32m';
const _yellow = '\x1b[33m';
const _magenta = '\x1b[35m';
const _red = '\x1b[31m';

/// Render [value] as colorized, pretty-printed JSON.
String _colorJson(Object? value, int depth) {
  if (value == null) return '$_red${null}$_reset';
  if (value is bool) return '$_magenta$value$_reset';
  if (value is num) return '$_yellow$value$_reset';
  if (value is String) return '$_green${jsonEncode(value)}$_reset';

  final indent = '  ' * (depth + 1);
  final closingIndent = '  ' * depth;

  if (value is List<Object?>) {
    if (value.isEmpty) return '$_dim[]$_reset';
    final items = value
        .map((e) => '$indent${_colorJson(e, depth + 1)}')
        .join('$_dim,$_reset\n');
    return '$_dim[$_reset\n$items\n$closingIndent$_dim]$_reset';
  }

  if (value is Map<String, Object?>) {
    if (value.isEmpty) return '$_dim{}$_reset';
    final entries = value.entries
        .map(
          (e) =>
              '$indent$_cyan${jsonEncode(e.key)}$_reset'
              '$_dim:$_reset '
              '${_colorJson(e.value, depth + 1)}',
        )
        .join('$_dim,$_reset\n');
    return '$_dim{$_reset\n$entries\n$closingIndent$_dim}$_reset';
  }

  return jsonEncode(value);
}

String _briefDescription(Object? data) {
  if (data is Map<String, Object?>) {
    final count = data.length;
    final lists = <String>[
      for (final MapEntry(:key, :value) in data.entries)
        if (value is List<Object?>) '${value.length} $key',
    ];
    final fieldWord = 'field${count == 1 ? '' : 's'}';
    if (lists.isEmpty) return '{$count $fieldWord}';
    return '{$count $fieldWord, ${lists.take(3).join(', ')}}';
  }
  if (data is List<Object?>) {
    return '[${data.length} item${data.length == 1 ? '' : 's'}]';
  }
  if (data is String) return 'string (${data.length} chars)';
  if (data is num) return '$data';
  if (data is bool) return '$data';
  return 'null';
}

Object? _loadFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Error: file not found: $path');
    return null;
  }
  try {
    final input = file.readAsStringSync();
    final fmt = detectFormat(path) ?? sniffFormat(input);
    return parseInput(input, fmt);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    return null;
  } on QueryError catch (e) {
    stderr.writeln('Error: ${e.message}');
    return null;
  }
}

void _printHelp() {
  stdout.writeln('Commands:');
  stdout.writeln('  :schema         Show data structure');
  stdout.writeln(
    '  :to <format>    Set output format (json, yaml, toml, xml, csv)',
  );
  stdout.writeln('  :raw            Toggle raw string output');
  stdout.writeln('  :pretty         Toggle pretty-printing');
  stdout.writeln('  :load <file>    Load a different data file');
  stdout.writeln('  :history        Show query history');
  stdout.writeln('  :help           Show this help');
  stdout.writeln('  :quit, :q       Exit');
  stdout.writeln();
  stdout.writeln('Shortcuts: Tab for completion, Up/Down for history');
}
