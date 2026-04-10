import 'package:lambe/lambe.dart';
import 'package:rumil_expressions/rumil_expressions.dart' show EvalException;
import 'package:test/test.dart';

/// Tests for the "absence propagates, type errors throw" principle.
///
/// Navigation operations (field access, indexing, pipeline) propagate null.
/// Computation operations (arithmetic, comparison, conditionals) throw on null.
void main() {
  group('Field access propagates null', () {
    test('.a on {} returns null', () {
      expect(query('.a', <String, Object?>{}), null);
    });

    test('.a.b on {} propagates null', () {
      expect(query('.a.b', <String, Object?>{}), null);
    });

    test('.a.b.c on {a: {}} propagates null', () {
      expect(query('.a.b.c', {'a': <String, Object?>{}}), null);
    });

    test('.a.b on {a: null} propagates null', () {
      expect(query('.a.b', {'a': null}), null);
    });

    test('.a.b.c.d deep null propagation', () {
      expect(query('.a.b.c.d', <String, Object?>{}), null);
    });
  });

  group('Indexing propagates null', () {
    test('null target returns null', () {
      expect(query('.missing[0]', <String, Object?>{}), null);
    });

    test('out of bounds returns null', () {
      expect(
        query('.items[5]', {
          'items': [1, 2],
        }),
        null,
      );
    });

    test('negative out of bounds returns null', () {
      expect(
        query('.items[-5]', {
          'items': [1, 2],
        }),
        null,
      );
    });

    test('index on empty list returns null', () {
      expect(query('.items[0]', {'items': <Object?>[]}), null);
    });

    test('chained: null target then index', () {
      expect(query('.missing[0].name', <String, Object?>{}), null);
    });
  });

  group('Pipeline propagates null', () {
    test('null | length returns null', () {
      expect(query('.missing | length', <String, Object?>{}), null);
    });

    test('null | keys returns null', () {
      expect(query('.missing | keys', <String, Object?>{}), null);
    });

    test('null | filter returns null', () {
      expect(query('.missing | filter(.x)', <String, Object?>{}), null);
    });

    test('null | map returns null', () {
      expect(query('.missing | map(.x)', <String, Object?>{}), null);
    });

    test('null | sort returns null', () {
      expect(query('.missing | sort', <String, Object?>{}), null);
    });

    test('null | sum returns null', () {
      expect(query('.missing | sum', <String, Object?>{}), null);
    });

    test('null | first returns null', () {
      expect(query('.missing | first', <String, Object?>{}), null);
    });

    test('null | sort_by returns null', () {
      expect(query('.missing | sort_by(.x)', <String, Object?>{}), null);
    });

    test('null | group_by returns null', () {
      expect(query('.missing | group_by(.x)', <String, Object?>{}), null);
    });

    test('null | unique returns null', () {
      expect(query('.missing | unique', <String, Object?>{}), null);
    });

    test('null | flatten returns null', () {
      expect(query('.missing | flatten', <String, Object?>{}), null);
    });

    test('null | filter_values returns null', () {
      expect(query('.missing | filter_values(.)', <String, Object?>{}), null);
    });

    test('null | map_values returns null', () {
      expect(query('.missing | map_values(.)', <String, Object?>{}), null);
    });

    test('chained pipeline propagates null through', () {
      expect(
        query('.missing | filter(.x) | map(.y) | sort', <String, Object?>{}),
        null,
      );
    });
  });

  group('Computation throws on null (type errors)', () {
    test('null + 1 throws', () {
      expect(
        () => query('.a + 1', <String, Object?>{}),
        throwsA(isA<EvalException>()),
      );
    });

    test('1 + null throws', () {
      expect(
        () => query('1 + .a', <String, Object?>{}),
        throwsA(isA<EvalException>()),
      );
    });

    test('null > 5 throws', () {
      expect(
        () => query('.a > 5', <String, Object?>{}),
        throwsA(isA<EvalException>()),
      );
    });

    test('null && true throws', () {
      expect(
        () => query('.a && true', <String, Object?>{}),
        throwsA(isA<EvalException>()),
      );
    });

    test('-null throws', () {
      expect(
        () => query('-.a', <String, Object?>{}),
        throwsA(isA<EvalException>()),
      );
    });

    test('if null then throws', () {
      expect(
        () => query('if .a then 1 else 2', <String, Object?>{}),
        throwsA(isA<EvalException>()),
      );
    });
  });

  group('Null in real-world patterns', () {
    test('sparse data: access missing nested field', () {
      final data = {
        'users': [
          {
            'name': 'Alice',
            'address': {'city': 'London'},
          },
          {'name': 'Bob'}, // no address
        ],
      };
      expect(query('.users[0].address.city', data), 'London');
      expect(query('.users[1].address.city', data), null);
    });

    test('filter with null fields: only matches truthy', () {
      final data = [
        {'name': 'Alice', 'active': true},
        {'name': 'Bob', 'active': false},
        {'name': 'Carol'}, // no active field
      ];
      final result = query('. | filter(.active)', data) as List;
      expect(result, hasLength(1));
      expect((result[0] as Map)['name'], 'Alice');
    });

    test('map over sparse data produces nulls', () {
      final data = [
        {'name': 'Alice', 'email': 'a@x.com'},
        {'name': 'Bob'},
      ];
      expect(query('. | map(.email)', data), ['a@x.com', null]);
    });

    test('optional chaining pattern: .config.db.host', () {
      expect(query('.config.db.host', <String, Object?>{}), null);
      expect(
        query('.config.db.host', {
          'config': {
            'db': {'host': 'localhost'},
          },
        }),
        'localhost',
      );
    });
  });
}
