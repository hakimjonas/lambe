/// Benchmarks the REPL completer against progressively larger data.
///
/// Run via `tool/bench/run.sh` which spawns this for each scenario in a
/// fresh process so RSS deltas measure only that scenario's work.
///
/// Usage: `dart run tool/bench/completer_bench.dart SCENARIO SIZE [ITERS]`
///
/// - `SCENARIO`: one of `sort_by`, `group_by`, `unique`, `simple`, `nested`
/// - `SIZE`: number of records
/// - `ITERS`: number of completion calls to time (default 30)
///
/// Prints a single JSON line with timing and RSS measurements.
library;

import 'dart:convert';
import 'dart:io';

import 'package:lambe/src/completer.dart' as lam_completer;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: completer_bench.dart <scenario> <size> [iterations]',
    );
    exit(2);
  }
  final scenario = args[0];
  final size = int.parse(args[1]);
  final iterations = args.length > 2 ? int.parse(args[2]) : 30;

  final (data, queryAtCursor, cursorPos) = _buildScenario(scenario, size);

  final rssBefore = ProcessInfo.currentRss;

  // Warm up (one run so JIT stabilizes and amortized allocations settle).
  lam_completer.complete(queryAtCursor, cursorPos, data);

  final times = <int>[];
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    lam_completer.complete(queryAtCursor, cursorPos, data);
    sw.stop();
    times.add(sw.elapsedMicroseconds);
  }

  final rssAfter = ProcessInfo.currentRss;

  final sorted = List<int>.of(times)..sort();
  final median = sorted[sorted.length ~/ 2];
  final p99 =
      sorted[(sorted.length * 0.99).floor().clamp(0, sorted.length - 1)];

  stdout.writeln(
    jsonEncode({
      'scenario': scenario,
      'size': size,
      'iterations': iterations,
      'times_us': times,
      'min_us': sorted.first,
      'median_us': median,
      'p99_us': p99,
      'max_us': sorted.last,
      'rss_before_bytes': rssBefore,
      'rss_after_bytes': rssAfter,
      'rss_delta_bytes': rssAfter - rssBefore,
    }),
  );
}

/// Build the (data, cursor_text, cursor_position) tuple for a scenario.
///
/// The cursor sits right after a `.` so the completer needs to compute
/// the shape of the value at that point.
(Object?, String, int) _buildScenario(String scenario, int size) {
  switch (scenario) {
    case 'sort_by':
      // Completer must understand the shape after sorting a list of maps.
      // sort_by is O(N log N) if the completer actually runs the sort.
      return (
        _users(size),
        '.users | sort_by(.age) | .[0].',
        '.users | sort_by(.age) | .[0].'.length,
      );
    case 'group_by':
      // group_by is one of the most expensive ops (bucket + copy).
      return (
        _usersWithDepts(size),
        '.users | group_by(.dept) | .[0].values[0].',
        '.users | group_by(.dept) | .[0].values[0].'.length,
      );
    case 'unique':
      // unique now canonicalizes every element as JSON — O(N * depth).
      return (
        _users(size),
        '.users | unique | .[0].',
        '.users | unique | .[0].'.length,
      );
    case 'simple':
      // Control: completer does minimal work, just reads shape of first user.
      return (_users(size), '.users | .[0].', '.users | .[0].'.length);
    case 'nested':
      // Deeply nested structure (5 levels). Tests recursive shape extraction.
      return (
        _nested(size),
        '.deep.items | .[0].inner.',
        '.deep.items | .[0].inner.'.length,
      );
    default:
      stderr.writeln('Unknown scenario: $scenario');
      exit(2);
  }
}

/// A list of `size` users with uniform shape.
Map<String, Object?> _users(int size) => {
  'users': [
    for (var i = 0; i < size; i++)
      {
        'name': 'User$i',
        'age': 20 + (i % 60),
        'email': 'user$i@example.com',
        'active': i % 3 != 0,
      },
  ],
};

/// Users with a department field for group_by.
Map<String, Object?> _usersWithDepts(int size) => {
  'users': [
    for (var i = 0; i < size; i++)
      {
        'name': 'User$i',
        'age': 20 + (i % 60),
        'dept': ['eng', 'sales', 'ops', 'hr'][i % 4],
        'active': i % 3 != 0,
      },
  ],
};

/// A nested structure: {deep: {items: [{inner: {...}}, ...]}}.
Map<String, Object?> _nested(int size) => {
  'deep': {
    'items': [
      for (var i = 0; i < size; i++)
        {
          'id': i,
          'inner': {
            'name': 'Item$i',
            'value': i * 10,
            'tags': ['a', 'b', 'c'],
          },
        },
    ],
  },
};
