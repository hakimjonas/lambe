import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('to_number', () {
    test('integer string', () {
      expect(query('to_number', '42'), 42);
    });

    test('float string', () {
      expect(query('to_number', '3.14'), 3.14);
    });

    test('negative number', () {
      expect(query('to_number', '-17'), -17);
    });

    test('pass-through for existing number', () {
      expect(query('to_number', 42), 42);
      expect(query('to_number', 3.14), 3.14);
    });

    test('explicit pipe form', () {
      expect(query('. | to_number', '100'), 100);
    });

    test('chains with arithmetic', () {
      expect(query('to_number + 1', '41'), 42);
    });

    test('chains with sum after map', () {
      expect(query('. | map(to_number) | sum', ['1', '2', '3', '4']), 10);
    });

    test('chains with CSV-like map access', () {
      final csv = <Map<String, Object?>>[
        {'name': 'a', 'count': '5'},
        {'name': 'b', 'count': '7'},
        {'name': 'c', 'count': '3'},
      ];
      expect(query('. | map(.count | to_number) | sum', csv), 15);
    });

    test('non-numeric string throws QueryError', () {
      expect(() => query('to_number', 'hello'), throwsA(isA<QueryError>()));
    });

    test('non-string/non-number throws QueryError', () {
      expect(() => query('to_number', true), throwsA(isA<QueryError>()));
      expect(() => query('to_number', null), throwsA(isA<QueryError>()));
    });
  });

  group('type', () {
    test('string', () {
      expect(query('type', 'hello'), 'string');
    });

    test('integer', () {
      expect(query('type', 42), 'number');
    });

    test('double', () {
      expect(query('type', 3.14), 'number');
    });

    test('boolean true', () {
      expect(query('type', true), 'boolean');
    });

    test('boolean false', () {
      expect(query('type', false), 'boolean');
    });

    test('null', () {
      expect(query('type', null), 'null');
    });

    test('array', () {
      expect(query('type', <Object?>[1, 2, 3]), 'array');
    });

    test('empty array', () {
      expect(query('type', <Object?>[]), 'array');
    });

    test('object', () {
      expect(query('type', <String, Object?>{'a': 1}), 'object');
    });

    test('empty object', () {
      expect(query('type', <String, Object?>{}), 'object');
    });

    test('explicit pipe form', () {
      expect(query('. | type', 'x'), 'string');
    });

    test('chained after field access', () {
      expect(
        query('.name | type', <String, Object?>{'name': 'Alice'}),
        'string',
      );
    });

    test('used in filter predicate', () {
      final items = <Object?>[1, 'two', 3, 'four', 5];
      expect(query('. | filter((. | type) == "number")', items), [1, 3, 5]);
    });

    // Regression: `_pipe` in evaluator.dart used to short-circuit on
    // null inputs unconditionally, so any pipe with null on its left
    // side returned null without consulting the right-hand op. That
    // broke `type`, whose contract is to inspect any context including
    // null and return a string. The fix lets ops named in
    // `nullSafePipeOpNames` (currently just `type`) bypass the
    // short-circuit; these tests pin that null|type and `.missing|type`
    // really do reach the evaluator and produce the documented label.
    test('null | type via Pipe AST returns "null" string, not null', () {
      expect(query('null | type', null), 'null');
      expect(query('null | type', 0), 'null');
    });

    test('chaining a missing field into type returns "null" string', () {
      expect(
        query('.missing | type', <String, Object?>{'a': 1}),
        'null',
      );
    });

    test('null | type | length confirms the result is a string, not null', () {
      // If type returned the JSON null (the bug), `length` would
      // short-circuit and produce null. The string `'null'` has length 4.
      expect(query('null | type | length', null), 4);
    });
  });
}
