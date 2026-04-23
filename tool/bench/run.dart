/// Runs the completer benchmark across scenarios and sizes.
///
/// Each (scenario, size) pair is run in a fresh subprocess so RSS
/// measurements reflect only that scenario's peak memory, not accumulated
/// heap from earlier runs.
///
/// Usage: dart run tool/bench/run.dart [--tag <label>]
///
/// Writes results to `bench-results-<tag>-<timestamp>.json` and prints a
/// human-readable table to stdout.
library;

import 'dart:convert';
import 'dart:io';

const _scenarios = ['simple', 'sort_by', 'group_by', 'unique', 'nested'];
const _sizes = [1000, 10000, 100000, 1000000];
const _iterations = 30;

Future<void> main(List<String> args) async {
  var tag = 'run';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--tag' && i + 1 < args.length) {
      tag = args[i + 1];
    }
  }

  final results = <Map<String, Object?>>[];

  stdout.writeln(
    '${'scenario'.padRight(10)} '
    '${'size'.padLeft(8)} '
    '${'median_us'.padLeft(12)} '
    '${'p99_us'.padLeft(12)} '
    '${'rss_delta'.padLeft(14)}',
  );
  stdout.writeln('-' * 62);

  for (final scenario in _scenarios) {
    for (final size in _sizes) {
      final result = await Process.run('dart', [
        'run',
        'tool/bench/completer_bench.dart',
        scenario,
        '$size',
        '$_iterations',
      ]);
      if (result.exitCode != 0) {
        stderr.writeln('$scenario @ $size failed: ${result.stderr}');
        continue;
      }
      final line = (result.stdout as String).trim().split('\n').last;
      final parsed = jsonDecode(line) as Map<String, Object?>;
      results.add(parsed);

      stdout.writeln(
        '${scenario.padRight(10)} '
        '${size.toString().padLeft(8)} '
        '${(parsed['median_us'] as int).toString().padLeft(12)} '
        '${(parsed['p99_us'] as int).toString().padLeft(12)} '
        '${_fmtBytes(parsed['rss_delta_bytes'] as int).padLeft(14)}',
      );
    }
  }

  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final outFile = File('bench-results-$tag-$stamp.json');
  outFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'tag': tag,
      'timestamp': stamp,
      'iterations_per_run': _iterations,
      'results': results,
    }),
  );
  stdout.writeln('\nFull results written to ${outFile.path}');
}

String _fmtBytes(int bytes) {
  if (bytes.abs() < 1024) return '${bytes}B';
  if (bytes.abs() < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
  if (bytes.abs() < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}G';
}
