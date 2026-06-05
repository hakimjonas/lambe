/// End-to-end CLI tests that shell out to `dart bin/lam.dart`.
///
/// These cover behaviors that live above the library surface: flag
/// parsing, auto-detection from file extension, mode-combination
/// rejection, stdin streaming, and the stderr/stdout split for hints
/// and errors. Individual library functions are unit-tested in their
/// own files; this file pins the wiring that glues them together.
///
/// Each test runs the real `dart bin/lam.dart` so regressions in the
/// argument parser, the ndjson loop, or the error rendering surface
/// here rather than in a mock.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs `dart bin/lam.dart [args]` with optional [stdinContents] and
/// returns `(exitCode, stdout, stderr)`.
Future<(int, String, String)> _runLam(
  List<String> args, {
  String? stdinContents,
}) async {
  final process = await Process.start('dart', [
    'bin/lam.dart',
    ...args,
  ], workingDirectory: Directory.current.path);

  if (stdinContents != null) {
    process.stdin.add(utf8.encode(stdinContents));
  }
  await process.stdin.close();

  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;
  return (exitCode, await stdoutFuture, await stderrFuture);
}

/// Runs `dart bin/lam.dart` with the given args, feeds [stdinLines]
/// one at a time and waits for the corresponding output line before
/// feeding the next. Returns the output lines in order.
///
/// The deadlock test for streaming: a buffered implementation that
/// holds output until stdin closes will never produce the first
/// output line, so the per-line wait blocks forever and the test
/// times out. A streaming implementation completes one round-trip per
/// line.
///
/// No wall-clock gap is measured. The signal is sequencing:
/// "did N inputs produce N outputs in lockstep, before EOF?"
Future<List<String>> _runLamLockstep(
  List<String> args,
  List<String> stdinLines, {
  Duration perLineTimeout = const Duration(seconds: 10),
}) async {
  final process = await Process.start('dart', [
    'bin/lam.dart',
    ...args,
  ], workingDirectory: Directory.current.path);

  // Hand-rolled async line queue: a list of completers fronts the
  // stream; each output line wakes the next pending reader. Avoids
  // taking on `package:async` for `StreamQueue` just for this test.
  final pending = <Completer<String>>[];
  final buffered = <String>[];
  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (pending.isNotEmpty) {
          pending.removeAt(0).complete(line);
        } else {
          buffered.add(line);
        }
      });

  Future<String> nextLine() {
    if (buffered.isNotEmpty) {
      return Future.value(buffered.removeAt(0));
    }
    final c = Completer<String>();
    pending.add(c);
    return c.future;
  }

  final received = <String>[];
  try {
    for (final line in stdinLines) {
      process.stdin.writeln(line);
      await process.stdin.flush();
      // Block until we get the corresponding output line. If the impl
      // buffers until EOF this throws TimeoutException; the test then
      // fails with a clear "streaming failed" message instead of
      // racing flaky wall-clock assertions.
      received.add(await nextLine().timeout(perLineTimeout));
    }
  } finally {
    await process.stdin.close();
    await sub.cancel();
    await process.exitCode;
  }
  return received;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lambe_cli_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('--ndjson: basic CLI invocation', () {
    test(
      'explicit --ndjson flag evaluates per line, compact JSON out',
      () async {
        final file = File('${tmp.path}/events.ndjson')
          ..writeAsStringSync('{"name":"a","age":30}\n{"name":"b","age":25}\n');
        final (code, out, _) = await _runLam(['--ndjson', '.age', file.path]);
        expect(code, 0);
        expect(out.trim().split('\n'), ['30', '25']);
      },
    );

    test('.ndjson extension auto-enables the mode without the flag', () async {
      final file = File('${tmp.path}/events.ndjson')
        ..writeAsStringSync('{"a":1}\n{"a":2}\n');
      final (code, out, _) = await _runLam(['.a', file.path]);
      expect(code, 0);
      expect(out.trim().split('\n'), ['1', '2']);
    });

    test('.jsonl extension auto-enables the mode without the flag', () async {
      final file = File('${tmp.path}/events.jsonl')
        ..writeAsStringSync('{"a":1}\n{"a":2}\n');
      final (code, out, _) = await _runLam(['.a', file.path]);
      expect(code, 0);
      expect(out.trim().split('\n'), ['1', '2']);
    });

    test('stdin with --ndjson works (piped input)', () async {
      final (code, out, _) = await _runLam([
        '--ndjson',
        '.a',
      ], stdinContents: '{"a":1}\n{"a":2}\n{"a":3}\n');
      expect(code, 0);
      expect(out.trim().split('\n'), ['1', '2', '3']);
    });

    test('empty lines are skipped silently', () async {
      final file = File('${tmp.path}/sparse.ndjson')
        ..writeAsStringSync('{"a":1}\n\n{"a":2}\n   \n{"a":3}\n');
      final (code, out, _) = await _runLam(['.a', file.path]);
      expect(code, 0);
      expect(out.trim().split('\n'), ['1', '2', '3']);
    });
  });

  group('--ndjson: error handling', () {
    test('malformed line fails with line number, exit 1', () async {
      final file = File('${tmp.path}/bad.ndjson')
        ..writeAsStringSync('{"a":1}\nnot json\n{"a":3}\n');
      final (code, _, err) = await _runLam(['.a', file.path]);
      expect(code, 1);
      expect(err, contains('line 2'));
    });

    test('file not found exits 1 with a clear error', () async {
      final (code, _, err) = await _runLam([
        '--ndjson',
        '.a',
        '${tmp.path}/nonexistent.ndjson',
      ]);
      expect(code, 1);
      expect(err, contains('file not found'));
    });
  });

  group('--ndjson: mode combination guards', () {
    test('rejects --ndjson --interactive', () async {
      final file = File('${tmp.path}/x.ndjson')..writeAsStringSync('{}\n');
      final (code, _, err) = await _runLam(['--ndjson', '-i', file.path]);
      expect(code, 1);
      expect(err, contains('--interactive'));
    });

    test('rejects --ndjson --schema', () async {
      final file = File('${tmp.path}/x.ndjson')..writeAsStringSync('{}\n');
      final (code, _, err) = await _runLam(['--ndjson', '--schema', file.path]);
      expect(code, 1);
      expect(err, contains('--schema'));
    });

    test('rejects --ndjson --assert', () async {
      final file = File('${tmp.path}/x.ndjson')..writeAsStringSync('{}\n');
      final (code, _, err) = await _runLam([
        '--ndjson',
        '--assert',
        '.a > 0',
        file.path,
      ]);
      expect(code, 1);
      expect(err, contains('--assert'));
    });

    test('rejects --ndjson --explain', () async {
      final file = File('${tmp.path}/x.ndjson')..writeAsStringSync('{}\n');
      final (code, _, err) = await _runLam([
        '--ndjson',
        '--explain',
        '.a',
        file.path,
      ]);
      expect(code, 1);
      expect(err, contains('--explain'));
    });

    test('rejects --ndjson --to yaml (and other non-json formats)', () async {
      final file = File('${tmp.path}/x.ndjson')..writeAsStringSync('{"a":1}\n');
      final (code, _, err) = await _runLam([
        '--ndjson',
        '--to',
        'yaml',
        '.a',
        file.path,
      ]);
      expect(code, 1);
      expect(err, contains('not supported'));
    });

    test('accepts --ndjson --to json (redundant but explicit)', () async {
      final file = File('${tmp.path}/x.ndjson')..writeAsStringSync('{"a":1}\n');
      final (code, out, _) = await _runLam([
        '--ndjson',
        '--to',
        'json',
        '.a',
        file.path,
      ]);
      expect(code, 0);
      expect(out.trim(), '1');
    });
  });

  group('--ndjson: stdin streaming', () {
    test(
      'lines emitted as they arrive on stdin, not buffered to EOF',
      () async {
        // Streaming property checked via lockstep round-trips:
        //   - send line 1 → read line 1 (must complete before line 2 sent)
        //   - send line 2 → read line 2 (...)
        //   - send line N → read line N
        //   - close stdin
        //
        // A buffered implementation that holds output until stdin
        // closes would deadlock on the first read (no output available
        // until EOF, but EOF doesn't come until we close, which we
        // don't do until all lines are read). The per-line timeout
        // surfaces that as a clean failure with reason text.
        //
        // No wall-clock gaps. Behaviour depends only on whether `lam`
        // flushes per line, which is the actual contract being tested.
        // Reliable under any host load and any CI runner stdio policy
        // — the previous wall-clock-gap assertion was sensitive to
        // both, so it's removed.
        final received = await _runLamLockstep(
          ['--ndjson', '.a'],
          ['{"a":1}', '{"a":2}', '{"a":3}', '{"a":4}'],
        );

        expect(received, ['1', '2', '3', '4']);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('--flatten-cells: CLI error surface', () {
    test(
      'refuse writes CLI-form hint to stderr, not REPL/MCP syntax',
      () async {
        final file = File('${tmp.path}/data.json')
          ..writeAsStringSync('[{"name":"a","tags":["x","y"]}]');
        final (code, _, err) = await _runLam(['--to', 'csv', '.', file.path]);
        expect(code, 1);
        expect(err, contains('--flatten-cells json'));
        // The baked message must not leak other-surface syntax.
        expect(err, isNot(contains(':flatten-cells')));
        expect(err, isNot(contains('flatten_cells=json')));
      },
    );

    test('--flatten-cells json produces CSV with JSON-encoded cells', () async {
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('[{"name":"a","tags":["x","y"]}]');
      final (code, out, _) = await _runLam([
        '--to',
        'csv',
        '--flatten-cells',
        'json',
        '.',
        file.path,
      ]);
      expect(code, 0);
      expect(out, contains('name'));
      expect(out, contains('tags'));
      // JSON-encoded cell, CSV-escaped: "[""x"",""y""]"
      expect(out, contains(r'"[""x"",""y""]"'));
    });

    test(
      '--explain --flatten-cells json widens writable formats and prints footer',
      () async {
        final file = File('${tmp.path}/data.json')
          ..writeAsStringSync('[{"name":"a","tags":["x","y"]}]');
        final (code, out, _) = await _runLam([
          '--explain',
          '--flatten-cells',
          'json',
          '.',
          file.path,
        ]);
        expect(code, 0);
        expect(out, contains('Writable as:'));
        expect(out, contains('csv'));
        expect(out, contains('Cell policy: json'));
      },
    );

    test(
      '--explain without --flatten-cells: no footer, csv NOT writable',
      () async {
        final file = File('${tmp.path}/data.json')
          ..writeAsStringSync('[{"name":"a","tags":["x","y"]}]');
        final (code, out, _) = await _runLam(['--explain', '.', file.path]);
        expect(code, 0);
        expect(out, isNot(contains('Cell policy:')));
        // csv appears under "Not writable as:" in this scenario.
        expect(out, contains('Not writable as:'));
        final notLine = out
            .split('\n')
            .firstWhere((l) => l.startsWith('Not writable as:'));
        expect(notLine, contains('csv'));
      },
    );
  });

  group('--explain: richer warnings', () {
    test('--explain flags runtime-rejection by default', () async {
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('{"users":[]}');
      final (code, out, _) = await _runLam([
        '--explain',
        '. | filter(.x)',
        file.path,
      ]);
      expect(code, 0);
      expect(out, contains('Warning'));
      expect(out, contains('filter rejects'));
      expect(out, contains('throw at runtime'));
    });

    test('--explain does NOT flag trivial-result by default', () async {
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('[{"name":"a","age":30}]');
      final (code, out, _) = await _runLam([
        '--explain',
        '. | sort_by(.missing)',
        file.path,
      ]);
      expect(code, 0);
      expect(out, isNot(contains('result is trivial')));
    });

    test('--explain-trivial enables trivial-result warnings', () async {
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('[{"name":"a","age":30}]');
      final (code, out, _) = await _runLam([
        '--explain-trivial',
        '. | sort_by(.missing)',
        file.path,
      ]);
      expect(code, 0);
      expect(out, contains('Warning'));
      expect(out, contains('sort_by'));
      expect(out, contains('trivial'));
    });

    test('--explain-trivial implies --explain', () async {
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('[{"a":1}]');
      final (code, out, _) = await _runLam([
        '--explain-trivial',
        '.',
        file.path,
      ]);
      expect(code, 0);
      expect(out, contains('Writable as:'));
    });

    test('--explain-json emits a JSON document', () async {
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('{"name":"alice"}');
      final (code, out, _) = await _runLam([
        '--explain-json',
        '.name',
        file.path,
      ]);
      expect(code, 0);
      final parsed = jsonDecode(out.trim()) as Map<String, Object?>;
      expect(
        parsed.keys,
        containsAll([
          'stages',
          'warnings',
          'writable_as',
          'not_writable_as',
          'flatten_cells',
        ]),
      );
    });

    test('--explain-json implies --explain', () async {
      final file = File('${tmp.path}/data.json')..writeAsStringSync('{"a":1}');
      final (code, out, _) = await _runLam(['--explain-json', '.a', file.path]);
      expect(code, 0);
      // Without --explain-json implying --explain, the query would
      // execute and print `1`, not the structured report.
      final parsed = jsonDecode(out.trim());
      expect(parsed, isA<Map<String, Object?>>());
      expect((parsed as Map<String, Object?>).keys, contains('stages'));
    });

    test(
      '--explain-json --explain-trivial: structured warnings include trivial_result',
      () async {
        final file = File('${tmp.path}/data.json')
          ..writeAsStringSync('[{"a":1}]');
        final (code, out, _) = await _runLam([
          '--explain-json',
          '--explain-trivial',
          '. | sort_by(.missing)',
          file.path,
        ]);
        expect(code, 0);
        final parsed = jsonDecode(out.trim()) as Map<String, Object?>;
        final warnings = parsed['warnings'] as List;
        expect(warnings, isNotEmpty);
        final kinds = [
          for (final w in warnings) (w as Map<String, Object?>)['kind'],
        ];
        expect(kinds, contains('trivial_result'));
      },
    );

    test('--ndjson rejects --explain-json (via --explain guard)', () async {
      final file = File('${tmp.path}/x.ndjson')..writeAsStringSync('{}\n');
      final (code, _, err) = await _runLam([
        '--ndjson',
        '--explain-json',
        '.',
        file.path,
      ]);
      expect(code, 1);
      expect(err, contains('--explain'));
    });
  });

  group('--print-shape: JSON Schema output', () {
    test('emits valid JSON Schema for a typical object', () async {
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('{"name":"alice","age":30}');
      final (code, out, _) = await _runLam(['--print-shape', file.path]);
      expect(code, 0);
      // Parse to prove it's valid JSON and has the documented shape.
      final parsed = jsonDecode(out) as Map<String, Object?>;
      expect(parsed['type'], 'object');
      expect(parsed['properties'], isA<Map<String, Object?>>());
      expect(parsed['required'], containsAll(<String>['name', 'age']));
    });

    test('output is round-trippable through --schema input', () async {
      // print-shape data.json > data.schema.json, then running
      // --schema data.schema.json '.' data.json must succeed.
      final dataFile = File('${tmp.path}/data.json')
        ..writeAsStringSync('{"a":1,"b":"x"}');
      final (code1, out, _) = await _runLam(['--print-shape', dataFile.path]);
      expect(code1, 0);

      final schemaFile = File('${tmp.path}/regen.schema.json')
        ..writeAsStringSync(out);
      final (code2, _, err2) = await _runLam([
        '--schema',
        schemaFile.path,
        '.a',
        dataFile.path,
      ]);
      expect(
        code2,
        0,
        reason:
            'print-shape -> schema round-trip should validate '
            'cleanly; stderr was: $err2',
      );
    });

    test('composes with EXPR: shape of evaluated result', () async {
      // `--print-shape '.users' data.json` returns the schema of the
      // users array, not the schema of the whole document. Pre-0.9.0
      // (when this composed) the expression was silently ignored.
      final file = File('${tmp.path}/data.json')..writeAsStringSync(
        '{"users":[{"name":"alice","age":30}],"version":"1.0.0"}',
      );
      final (code, out, _) = await _runLam([
        '--print-shape',
        '.users',
        file.path,
      ]);
      expect(code, 0);
      final parsed = jsonDecode(out) as Map<String, Object?>;
      expect(parsed['type'], 'array');
      // items reflect a user, not the whole doc.
      final items = parsed['items'] as Map<String, Object?>;
      expect(items['type'], 'object');
      final props = items['properties'] as Map<String, Object?>;
      expect(props.keys, containsAll(<String>['name', 'age']));
    });

    test('no expression form unchanged (legacy)', () async {
      // `--print-shape data.json` (single positional that's a file)
      // continues to print the whole-document shape, matching the
      // 0.8.0 -> 0.9.0 contract.
      final file = File('${tmp.path}/data.json')
        ..writeAsStringSync('{"a":1,"b":"x"}');
      final (code, out, _) = await _runLam(['--print-shape', file.path]);
      expect(code, 0);
      final parsed = jsonDecode(out) as Map<String, Object?>;
      expect(parsed['type'], 'object');
      expect(
        (parsed['properties'] as Map<String, Object?>).keys,
        containsAll(<String>['a', 'b']),
      );
    });

    test('EXPR with no data: matches --explain-without-data', () async {
      // `lam --print-shape '.users'` (no file, no piped stdin)
      // infers statically from SAny. Because . | .users on SAny
      // resolves to SAny, the rendered schema is the empty
      // (any-typed) schema.
      final (code, out, _) = await _runLam(['--print-shape', '.users']);
      expect(code, 0);
      // Non-empty output, valid JSON.
      expect(out.trim(), isNotEmpty);
      final parsed = jsonDecode(out);
      expect(parsed, isA<Map<String, Object?>>());
    });

    test('EXPR result is null: schema is the null/empty form', () async {
      // .field-that-does-not-exist evaluates to null; shapeOf(null)
      // is SNull. The renderer must produce valid JSON Schema for
      // that case rather than crashing.
      final file = File('${tmp.path}/data.json')..writeAsStringSync('{"a":1}');
      final (code, out, _) = await _runLam([
        '--print-shape',
        '.missing',
        file.path,
      ]);
      expect(code, 0);
      final parsed = jsonDecode(out);
      expect(parsed, isA<Map<String, Object?>>());
    });

    test('rejects combination with --schema (redundant)', () async {
      final data = File('${tmp.path}/d.json')..writeAsStringSync('{}');
      final schema = File('${tmp.path}/s.json')
        ..writeAsStringSync('{"type":"object"}');
      final (code, _, err) = await _runLam([
        '--print-shape',
        '--schema',
        schema.path,
        data.path,
      ]);
      expect(code, 1);
      expect(err, contains('--print-shape'));
    });
  });

  group('--schema: input schema threading', () {
    test('explicit --schema threads into --explain inputShape', () async {
      final data = File('${tmp.path}/data.json')
        ..writeAsStringSync('{"users":[{"name":"alice","age":30}]}');
      // Schema declares `email` as optional on users.
      final schema = File('${tmp.path}/s.json')..writeAsStringSync(
        '{"type":"object","properties":{"users":{"type":"array","items":'
        '{"type":"object","properties":{"name":{"type":"string"},'
        '"age":{"type":"number"},"email":{"type":"string"}},'
        '"required":["name","age"]}}},"required":["users"]}',
      );
      final (code, out, _) = await _runLam([
        '--schema',
        schema.path,
        '--explain',
        '.users | map(.email)',
        data.path,
      ]);
      expect(code, 0);
      // The explain output should show `email: optional<string>`
      // in the users element shape.
      expect(out, contains('email: optional<string>'));
    });

    test('sibling <data>.schema.json is auto-detected', () async {
      final data = File('${tmp.path}/items.json')
        ..writeAsStringSync('[{"id":"x","n":1}]');
      File('${tmp.path}/items.schema.json').writeAsStringSync(
        '{"type":"array","items":{"type":"object","properties":'
        '{"id":{"type":"string"},"n":{"type":"number"},'
        '"note":{"type":"string"}},"required":["id","n"]}}',
      );
      final (code, out, _) = await _runLam(['--explain', '.', data.path]);
      expect(code, 0);
      // Auto-detected schema adds `note: optional<string>` to element.
      expect(out, contains('note: optional<string>'));
    });

    test('schema disagreement exits 1 with a path-annotated error', () async {
      final data = File('${tmp.path}/d.json')..writeAsStringSync('{"age":30}');
      final schema = File('${tmp.path}/s.json')..writeAsStringSync(
        '{"type":"object","properties":{"age":{"type":"string"}},'
        '"required":["age"]}',
      );
      final (code, _, err) = await _runLam([
        '--schema',
        schema.path,
        '.',
        data.path,
      ]);
      expect(code, 1);
      expect(err, contains('disagreement'));
      expect(err, contains(r'$.age'));
      expect(err, contains('string'));
      expect(err, contains('number'));
    });

    test('schema parse error surfaces a clear diagnostic', () async {
      final data = File('${tmp.path}/d.json')..writeAsStringSync('{}');
      final schema = File('${tmp.path}/bad.json')
        ..writeAsStringSync('{"allOf":[{"type":"object"}]}');
      final (code, _, err) = await _runLam([
        '--schema',
        schema.path,
        '.',
        data.path,
      ]);
      expect(code, 1);
      expect(err, contains('allOf'));
      expect(err, contains('unsupported'));
    });

    test('missing schema file exits 1 with a clear error', () async {
      final data = File('${tmp.path}/d.json')..writeAsStringSync('{}');
      final (code, _, err) = await _runLam([
        '--schema',
        '${tmp.path}/nonexistent.json',
        '.',
        data.path,
      ]);
      expect(code, 1);
      expect(err, contains('schema file not found'));
    });

    test('--ndjson rejects --schema', () async {
      final data = File('${tmp.path}/e.ndjson')..writeAsStringSync('{}\n');
      final schema = File('${tmp.path}/s.json')
        ..writeAsStringSync('{"type":"object"}');
      final (code, _, err) = await _runLam([
        '--ndjson',
        '--schema',
        schema.path,
        '.',
        data.path,
      ]);
      expect(code, 1);
      expect(err, contains('--schema'));
    });
  });

  group('-n / --null-input: input-less queries', () {
    test('-n with literal-list query', () async {
      final (code, out, _) = await _runLam(['-n', '[1,2,3] | unique']);
      expect(code, 0);
      expect(jsonDecode(out), [1, 2, 3]);
    });

    test('-n with identity returns null', () async {
      final (code, out, _) = await _runLam(['-n', '.']);
      expect(code, 0);
      expect(jsonDecode(out), isNull);
    });

    test('-n with field access on null is null (null-propagation)', () async {
      final (code, out, _) = await _runLam(['-n', '.name']);
      expect(code, 0);
      expect(jsonDecode(out), isNull);
    });

    test('--null-input long form works the same', () async {
      final (code, out, _) = await _runLam([
        '--null-input',
        '[1,2,2,3] | unique',
      ]);
      expect(code, 0);
      expect(jsonDecode(out), [1, 2, 3]);
    });

    test('-n without expression errors with missing-query message', () async {
      final (code, _, err) = await _runLam(['-n']);
      expect(code, 1);
      expect(err, contains('missing query expression'));
    });

    test('rejects -n -i', () async {
      final (code, _, err) = await _runLam(['-n', '-i', '.']);
      expect(code, 1);
      expect(err, contains('-n'));
      expect(err, contains('--interactive'));
    });

    test('rejects -n --ndjson', () async {
      final (code, _, err) = await _runLam(['-n', '--ndjson', '.']);
      expect(code, 1);
      expect(err, contains('-n'));
      expect(err, contains('--ndjson'));
    });

    test('rejects -n --schema', () async {
      final schema = File('${tmp.path}/s.json')
        ..writeAsStringSync('{"type":"object"}');
      final (code, _, err) = await _runLam([
        '-n',
        '--schema',
        schema.path,
        '.',
      ]);
      expect(code, 1);
      expect(err, contains('-n'));
      expect(err, contains('--schema'));
    });

    test('rejects -n --assert', () async {
      final (code, _, err) = await _runLam(['-n', '--assert', 'true']);
      expect(code, 1);
      expect(err, contains('-n'));
      expect(err, contains('--assert'));
    });

    test(
      'without -n, no input still errors with the standard message',
      () async {
        // The default footgun catch must stay. `-n` is the explicit
        // opt-in.
        final (code, _, err) = await _runLam(['[1,2,3] | unique']);
        expect(code, 1);
        expect(err, contains('no input'));
      },
    );

    test('-n with sum on a literal list', () async {
      final (code, out, _) = await _runLam(['-n', '[1,2,3] | sum']);
      expect(code, 0);
      expect(jsonDecode(out), 6);
    });
  });

  group('--skill: print embedded SKILL.md', () {
    test('prints YAML-frontmatter header (skill is shaped right)', () async {
      final (code, out, _) = await _runLam(['--skill']);
      expect(code, 0);
      expect(out, startsWith('---\nname: lambe\n'));
    });

    test('output round-trips as a Markdown document', () async {
      // Pipe --skill output back through `lam -f markdown` to confirm
      // the embedded content parses cleanly. The first child of any
      // CommonMark document with a leading H1 should be a heading.
      final (skillCode, skillOut, _) = await _runLam(['--skill']);
      expect(skillCode, 0);

      final (code, out, _) = await _runLam([
        '-f',
        'markdown',
        '.children[0].type',
      ], stdinContents: skillOut);
      expect(code, 0);
      expect(out.trim(), '"heading"');
    });

    test(
      'matches the on-disk .agents/skills/lambe/SKILL.md byte-for-byte',
      () async {
        // Catches the "regenerated _skill.dart wasn't committed" case.
        final source =
            await File('.agents/skills/lambe/SKILL.md').readAsString();
        final (code, out, _) = await _runLam(['--skill']);
        expect(code, 0);
        expect(out, source);
      },
    );
  });

  group('--completions: shell completion scripts', () {
    test('bash script defines the completion and registers it', () async {
      final (code, out, _) = await _runLam(['--completions', 'bash']);
      expect(code, 0);
      expect(out, contains('_lam()'));
      expect(out, contains('complete -F _lam lam'));
      // Enum values for --to are present.
      expect(out, contains('json yaml toml csv tsv hcl'));
    });

    test('zsh script is an autoload #compdef file', () async {
      final (code, out, _) = await _runLam(['--completions', 'zsh']);
      expect(code, 0);
      expect(out, startsWith('#compdef lam'));
      expect(out, contains('_arguments'));
      // Brace forms must sit OUTSIDE quotes so zsh expands them.
      expect(out, contains("{-t,--to}'["));
    });

    test('fish script uses declarative complete lines', () async {
      final (code, out, _) = await _runLam(['--completions', 'fish']);
      expect(code, 0);
      expect(out, contains('complete -c lam'));
      expect(out, contains('-l to -x -a "json yaml toml csv tsv hcl"'));
    });

    test('rejects an unsupported shell', () async {
      final (code, _, err) = await _runLam(['--completions', 'powershell']);
      expect(code, isNonZero);
      expect(err, contains('completions'));
    });

    test(
      'bash output mentions every flag the CLI defines (no drift)',
      () async {
        // Guard against the completion script falling behind the real CLI:
        // every --flag the help text lists must appear in the bash script.
        final (_, help, _) = await _runLam(['--help']);
        final flags =
            RegExp(r'--[a-z][a-z-]+').allMatches(help).map((m) => m[0]).toSet();
        final (code, bash, _) = await _runLam(['--completions', 'bash']);
        expect(code, 0);
        for (final flag in flags) {
          expect(
            bash,
            contains(flag),
            reason: 'completion script is missing $flag',
          );
        }
      },
    );
  });
}
