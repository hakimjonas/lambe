/// Completer benchmark runner.
///
/// Runs the completer benchmark across a matrix of scenarios and input
/// sizes, in fresh subprocesses so RSS measurements reflect each
/// scenario's peak memory alone. Each `(scenario, size)` pair is
/// repeated across N processes (`--runs N`, default 5); the reported
/// value is the median of the per-run medians, which suppresses the
/// per-process noise floor and makes small regressions visible.
///
/// Usage:
///   dart run tool/bench/run.dart [--tag <label>] [--aot] [--runs N]
///
/// `--aot` runs the ahead-of-time compiled binary at
/// `tool/bench/completer_bench.aot` (which must be built first via
/// `dart compile exe`). Without the flag, the benchmark is launched
/// via `dart run` and includes JIT warmup.
///
/// Results are written to `bench-results-<tag>-<timestamp>.json` and
/// summarised on stdout.
library;

import 'dart:convert';
import 'dart:io';

const _scenarios = ['simple', 'sort_by', 'group_by', 'unique', 'nested'];
const _sizes = [1000, 10000, 100000, 1000000];
const _iterations = 30;

Future<void> main(List<String> args) async {
  var tag = 'run';
  var useAot = false;
  var runs = 5;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--tag' && i + 1 < args.length) {
      tag = args[i + 1];
    }
    if (args[i] == '--aot') {
      useAot = true;
    }
    if (args[i] == '--runs' && i + 1 < args.length) {
      runs = int.parse(args[i + 1]);
    }
  }

  const aotBin = 'tool/bench/completer_bench.aot';
  if (useAot && !File(aotBin).existsSync()) {
    stderr.writeln(
      'AOT binary not found at $aotBin.\n'
      'Build it first with:\n'
      '  dart compile exe tool/bench/completer_bench.dart -o $aotBin',
    );
    exit(1);
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
      // Each sample is the median over _iterations hot-loop
      // measurements inside a single fresh process.
      final perRunMedians = <int>[];
      final perRunP99s = <int>[];
      final perRunRssDeltas = <int>[];
      var failed = false;

      for (var run = 0; run < runs; run++) {
        final ProcessResult result;
        if (useAot) {
          result = await Process.run(aotBin, [
            scenario,
            '$size',
            '$_iterations',
          ]);
        } else {
          result = await Process.run('dart', [
            'run',
            'tool/bench/completer_bench.dart',
            scenario,
            '$size',
            '$_iterations',
          ]);
        }
        if (result.exitCode != 0) {
          stderr.writeln('$scenario @ $size run $run failed: ${result.stderr}');
          failed = true;
          break;
        }
        final line = (result.stdout as String).trim().split('\n').last;
        final parsed = jsonDecode(line) as Map<String, Object?>;
        perRunMedians.add(parsed['median_us'] as int);
        perRunP99s.add(parsed['p99_us'] as int);
        perRunRssDeltas.add(parsed['rss_delta_bytes'] as int);
      }
      if (failed) continue;

      // The reported values are the medians of the per-run series.
      // Medians for p99 and RSS delta prevent a single GC outlier from
      // dominating the summary.
      final medianOfMedians = _median(perRunMedians);
      final medianP99 = _median(perRunP99s);
      final medianRssDelta = _median(perRunRssDeltas);

      final summary = <String, Object?>{
        'scenario': scenario,
        'size': size,
        'runs': runs,
        'iterations_per_run': _iterations,
        'median_us': medianOfMedians,
        'p99_us': medianP99,
        'rss_delta_bytes': medianRssDelta,
        'run_medians_us': perRunMedians,
        'run_p99s_us': perRunP99s,
        'run_rss_deltas_bytes': perRunRssDeltas,
      };
      results.add(summary);

      stdout.writeln(
        '${scenario.padRight(10)} '
        '${size.toString().padLeft(8)} '
        '${medianOfMedians.toString().padLeft(12)} '
        '${medianP99.toString().padLeft(12)} '
        '${_fmtBytes(medianRssDelta).padLeft(14)}',
      );
    }
  }

  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final outFile = File('bench-results-$tag-$stamp.json');
  outFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'tag': tag,
      'timestamp': stamp,
      'runs_per_config': runs,
      'iterations_per_run': _iterations,
      'results': results,
    }),
  );
  stdout.writeln('\nFull results written to ${outFile.path}');
}

int _median(List<int> xs) {
  final sorted = List<int>.of(xs)..sort();
  return sorted[sorted.length ~/ 2];
}

String _fmtBytes(int bytes) {
  if (bytes.abs() < 1024) return '${bytes}B';
  if (bytes.abs() < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
  if (bytes.abs() < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}G';
}
