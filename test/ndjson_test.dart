/// Tests for [queryNdjson]: per-line evaluation of JSON documents.
///
/// Properties to pin:
///   1. Each non-empty line is evaluated independently; no state bleeds
///      across lines.
///   2. Empty and whitespace-only lines are skipped silently.
///   3. A parse error on any line throws [QueryError] with a `line N:`
///      prefix and stops iteration there (fail-fast, matching the
///      single-document CLI's semantics).
///   4. An evaluation error is surfaced the same way.
///   5. Lazy iteration: earlier results are produced before later
///      lines are parsed, so a failing line does not prevent the
///      already-yielded results from being consumed.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('queryNdjson: basic evaluation', () {
    test('one line, one result', () {
      final ast = parseAst('.name');
      final results = queryNdjson(['{"name": "alice"}'], ast).toList();
      expect(results, ['alice']);
    });

    test('three lines, three results, in order', () {
      final ast = parseAst('.age');
      final results =
          queryNdjson([
            '{"name": "alice", "age": 30}',
            '{"name": "bob", "age": 25}',
            '{"name": "carol", "age": 45}',
          ], ast).toList();
      expect(results, [30, 25, 45]);
    });

    test('per-line evaluation is independent', () {
      // A query that would fail on an aggregate tree but succeeds on
      // individual lines proves no accidental aggregation.
      final ast = parseAst('.x');
      final results = queryNdjson(['{"x": 1}', '{"x": 2}'], ast).toList();
      expect(results, [1, 2]);
    });

    test('filter predicate returning booleans', () {
      final ast = parseAst('.age > 28');
      final results =
          queryNdjson([
            '{"age": 30}',
            '{"age": 25}',
            '{"age": 45}',
          ], ast).toList();
      expect(results, [true, false, true]);
    });
  });

  group('queryNdjson: skipping empty lines', () {
    test('empty strings are skipped', () {
      final ast = parseAst('.a');
      final results = queryNdjson(['{"a": 1}', '', '{"a": 2}'], ast).toList();
      expect(results, [1, 2]);
    });

    test('whitespace-only lines are skipped', () {
      final ast = parseAst('.a');
      final results =
          queryNdjson(['{"a": 1}', '   ', '\t', '{"a": 2}'], ast).toList();
      expect(results, [1, 2]);
    });

    test('all empty lines produces no results (but does not error)', () {
      final ast = parseAst('.a');
      final results = queryNdjson(['', '   ', '\t'], ast).toList();
      expect(results, isEmpty);
    });
  });

  group('queryNdjson: error handling', () {
    test('parse error annotates line number', () {
      final ast = parseAst('.a');
      expect(
        () => queryNdjson(['{"a": 1}', 'not json'], ast).toList(),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('line 2'),
          ),
        ),
      );
    });

    test('evaluation error annotates line number', () {
      // Arithmetic on null throws at evaluation; `.age + 5` on a line
      // without age fails.
      final ast = parseAst('.age + 5');
      expect(
        () => queryNdjson(['{"age": 30}', '{"name": "bob"}'], ast).toList(),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('line 2'),
          ),
        ),
      );
    });

    test('line numbers count empty lines too', () {
      final ast = parseAst('.a');
      // Bad input on line 3 of source, still reported as line 3.
      expect(
        () => queryNdjson(['{"a": 1}', '', 'bad'], ast).toList(),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('line 3'),
          ),
        ),
      );
    });
  });

  group('queryNdjson: laziness', () {
    test('yields earlier results before hitting a later error', () {
      final ast = parseAst('.a');
      final it =
          queryNdjson(['{"a": 1}', '{"a": 2}', 'bad line'], ast).iterator;

      expect(it.moveNext(), isTrue);
      expect(it.current, 1);
      expect(it.moveNext(), isTrue);
      expect(it.current, 2);
      expect(it.moveNext, throwsA(isA<QueryError>()));
    });

    test('only consumes as many lines as are pulled', () {
      final ast = parseAst('.a');
      // Line 3 is malformed; if we only pull two, we never see the
      // error.
      final results =
          queryNdjson([
            '{"a": 1}',
            '{"a": 2}',
            'malformed',
          ], ast).take(2).toList();
      expect(results, [1, 2]);
    });
  });

  group('queryNdjson: complex queries per line', () {
    test('pipe chain works per-line', () {
      final ast = parseAst('.users | filter(.active) | map(.name)');
      final results =
          queryNdjson([
            '{"users": [{"name": "a", "active": true}, {"name": "b", "active": false}]}',
            '{"users": [{"name": "c", "active": true}]}',
          ], ast).toList();
      expect(results, [
        ['a'],
        ['c'],
      ]);
    });

    test('object construction per line', () {
      final ast = parseAst('{name, senior: .age > 65}');
      final results =
          queryNdjson([
            '{"name": "alice", "age": 30}',
            '{"name": "carol", "age": 70}',
          ], ast).toList();
      expect(results, [
        {'name': 'alice', 'senior': false},
        {'name': 'carol', 'senior': true},
      ]);
    });
  });

  group('queryNdjsonString: string-expression convenience', () {
    test('parses once, applies to every line', () {
      final results =
          queryNdjsonString([
            '{"name": "alice"}',
            '{"name": "bob"}',
          ], '.name').toList();
      expect(results, ['alice', 'bob']);
    });

    test('expression syntax error throws QueryError', () {
      expect(
        () => queryNdjsonString(['{"a": 1}'], '.a |').toList(),
        throwsA(isA<QueryError>()),
      );
    });

    test('per-line errors carry line number', () {
      expect(
        () => queryNdjsonString(['{"a": 1}', 'not json'], '.a').toList(),
        throwsA(
          predicate((e) => e is QueryError && e.message.contains('line 2')),
        ),
      );
    });
  });
}
