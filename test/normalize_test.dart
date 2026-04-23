import 'package:lambe/lambe.dart';
import 'package:rumil/rumil.dart' show Success;
import 'package:test/test.dart';

/// Tests that `query()` and `eval()` accept data from any Dart source,
/// not just `Map<String, Object?>` / `List<Object?>`.
///
/// Third-party decoders (some YAML parsers, manually constructed literals,
/// data passed through `jsonDecode` and then reshaped) produce maps and
/// lists with dynamic or narrower element types. The public API normalizes
/// these on entry so users get consistent behavior.
void main() {
  group('query accepts Map<dynamic, dynamic>', () {
    test('field access', () {
      final data = <dynamic, dynamic>{'name': 'Alice', 'age': 30};
      expect(query('.name', data), 'Alice');
      expect(query('.age', data), 30);
    });

    test('type op reports object', () {
      final data = <dynamic, dynamic>{'a': 1};
      expect(query('type', data), 'object');
    });

    test('keys and values', () {
      final data = <dynamic, dynamic>{'a': 1, 'b': 2};
      expect(query('keys', data), ['a', 'b']);
      expect(query('values', data), [1, 2]);
    });

    test('has works', () {
      final data = <dynamic, dynamic>{'present': 1};
      expect(query('has("present")', data), true);
      expect(query('has("missing")', data), false);
    });
  });

  group('query accepts List<int> and List<dynamic>', () {
    test('List<int> filter and map', () {
      final data = <int>[1, 2, 3, 4, 5];
      expect(query('. | filter(. > 2) | map(. * 10)', data), [30, 40, 50]);
    });

    test('List<dynamic> of mixed types', () {
      final data = <dynamic>[1, 'two', 3, null, true];
      expect(query('length', data), 5);
      expect(query('. | map(type)', data), [
        'number',
        'string',
        'number',
        'null',
        'boolean',
      ]);
    });

    test('List<String> aggregation', () {
      final data = <String>['a', 'b', 'c'];
      expect(query('length', data), 3);
      expect(query('first', data), 'a');
      expect(query('last', data), 'c');
    });
  });

  group('nested exotic collections normalize recursively', () {
    test('list of dynamic maps', () {
      final data = <dynamic>[
        <dynamic, dynamic>{'n': 1},
        <dynamic, dynamic>{'n': 2},
        <dynamic, dynamic>{'n': 3},
      ];
      expect(query('. | map(.n) | sum', data), 6);
    });

    test('map of list of map', () {
      final data = <dynamic, dynamic>{
        'users': <dynamic>[
          <dynamic, dynamic>{'name': 'Alice'},
          <dynamic, dynamic>{'name': 'Bob'},
        ],
      };
      expect(query('.users | map(.name)', data), ['Alice', 'Bob']);
    });

    test('deeply nested dynamic structure', () {
      final data = <dynamic, dynamic>{
        'a': <dynamic, dynamic>{
          'b': <dynamic>[
            <dynamic, dynamic>{'c': 42},
          ],
        },
      };
      expect(query('.a.b[0].c', data), 42);
    });
  });

  group('non-string map keys', () {
    test('integer key throws QueryError', () {
      final data = <dynamic, dynamic>{1: 'one', 2: 'two'};
      expect(() => query('.', data), throwsA(isA<QueryError>()));
    });

    test('null key throws QueryError', () {
      final data = <dynamic, dynamic>{null: 'x'};
      expect(() => query('.', data), throwsA(isA<QueryError>()));
    });

    test('nested non-string key is detected', () {
      final data = <String, Object?>{
        'outer': <dynamic, dynamic>{99: 'bad'},
      };
      expect(() => query('.outer', data), throwsA(isA<QueryError>()));
    });
  });

  group('primitives pass through', () {
    test('string', () {
      expect(query('length', 'hello'), 5);
    });

    test('integer', () {
      expect(query('type', 42), 'number');
    });

    test('bool', () {
      expect(query('type', true), 'boolean');
    });

    test('null', () {
      expect(query('type', null), 'null');
    });
  });

  group('eval() normalizes too', () {
    test('pre-parsed AST with exotic data', () {
      final parsed = parse('.name');
      final ast = switch (parsed) {
        Success(:final value) => value,
        _ => throw StateError('parse failed'),
      };
      final data = <dynamic, dynamic>{'name': 'Bob'};
      expect(eval(ast, data), 'Bob');
    });
  });
}
