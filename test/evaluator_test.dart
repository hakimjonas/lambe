import 'package:lambe/lambe.dart';
import 'package:rumil_expressions/rumil_expressions.dart' show EvalException;
import 'package:test/test.dart';

void main() {
  group('Identity and field access', () {
    test('. returns context', () {
      expect(query('.', 42), 42);
      expect(query('.', 'hello'), 'hello');
      expect(query('.', null), null);
    });

    test('.name on map', () {
      expect(query('.name', {'name': 'Alice'}), 'Alice');
    });

    test('.missing on map returns null', () {
      expect(query('.missing', {'name': 'Alice'}), null);
    });

    test('.field on non-map throws', () {
      expect(() => query('.name', 42), throwsA(isA<QueryError>()));
    });
  });

  group('Property access chains', () {
    test('.a.b.c', () {
      final data = {
        'a': {
          'b': {'c': 'deep'},
        },
      };
      expect(query('.a.b.c', data), 'deep');
    });

    test('.users[0].name', () {
      final data = {
        'users': [
          {'name': 'Alice'},
          {'name': 'Bob'},
        ],
      };
      expect(query('.users[0].name', data), 'Alice');
    });
  });

  group('Indexing', () {
    test('positive index', () {
      expect(
        query('.items[1]', {
          'items': [10, 20, 30],
        }),
        20,
      );
    });

    test('negative index', () {
      expect(
        query('.items[-1]', {
          'items': [10, 20, 30],
        }),
        30,
      );
    });

    test('index out of bounds returns null', () {
      expect(
        query('.items[5]', {
          'items': [1, 2],
        }),
        null,
      );
    });

    test('index on non-list throws', () {
      expect(() => query('.[0]', {'key': 'val'}), throwsA(isA<QueryError>()));
    });
  });

  group('Arithmetic operators', () {
    test('addition', () {
      expect(query('.a + .b', {'a': 1, 'b': 2}), 3);
    });

    test('multiplication', () {
      expect(query('.price * .qty', {'price': 10, 'qty': 3}), 30);
    });

    test('precedence: a + b * c', () {
      expect(query('.a + .b * .c', {'a': 1, 'b': 2, 'c': 3}), 7);
    });

    test('string concatenation', () {
      expect(query('.a + .b', {'a': 'hello', 'b': ' world'}), 'hello world');
    });

    test('preserves int type', () {
      expect(query('.a + .b', {'a': 2, 'b': 3}), isA<int>());
    });
  });

  group('Comparison operators', () {
    test('> true', () {
      expect(query('.age > 30', {'age': 35}), true);
    });

    test('> false', () {
      expect(query('.age > 30', {'age': 25}), false);
    });

    test('>=', () {
      expect(query('.age >= 30', {'age': 30}), true);
    });

    test('<', () {
      expect(query('.x < .y', {'x': 1, 'y': 2}), true);
    });

    test('==', () {
      expect(query('.name == "Alice"', {'name': 'Alice'}), true);
      expect(query('.name == "Bob"', {'name': 'Alice'}), false);
    });

    test('!=', () {
      expect(query('.x != .y', {'x': 1, 'y': 2}), true);
    });
  });

  group('Boolean operators', () {
    test('&&', () {
      expect(query('.a && .b', {'a': true, 'b': true}), true);
      expect(query('.a && .b', {'a': true, 'b': false}), false);
    });

    test('||', () {
      expect(query('.a || .b', {'a': false, 'b': true}), true);
      expect(query('.a || .b', {'a': false, 'b': false}), false);
    });

    test('!', () {
      expect(query('!.active', {'active': false}), true);
    });
  });

  group('Pipeline: filter', () {
    final users = {
      'users': [
        {'name': 'Alice', 'age': 25, 'active': true},
        {'name': 'Bob', 'age': 35, 'active': true},
        {'name': 'Carol', 'age': 45, 'active': false},
      ],
    };

    test('filter(.age > 30)', () {
      final result = query('.users | filter(.age > 30)', users) as List;
      expect(result, hasLength(2));
      expect((result[0] as Map)['name'], 'Bob');
      expect((result[1] as Map)['name'], 'Carol');
    });

    test('filter(.active)', () {
      final result = query('.users | filter(.active)', users) as List;
      expect(result, hasLength(2));
    });

    test('filter with compound predicate', () {
      final result =
          query('.users | filter(.age > 30 && .active)', users) as List;
      expect(result, hasLength(1));
      expect((result[0] as Map)['name'], 'Bob');
    });
  });

  group('Pipeline: map', () {
    test('map(.name)', () {
      final data = {
        'users': [
          {'name': 'Alice'},
          {'name': 'Bob'},
        ],
      };
      expect(query('.users | map(.name)', data), ['Alice', 'Bob']);
    });

    test('map with arithmetic', () {
      final data = {
        'items': [
          {'price': 10, 'qty': 2},
          {'price': 5, 'qty': 3},
        ],
      };
      expect(query('.items | map(.price * .qty)', data), [20, 15]);
    });
  });

  group('Pipeline: sort, reverse, keys, values, length, first, last', () {
    test('sort', () {
      expect(query('. | sort', [3, 1, 2]), [1, 2, 3]);
    });

    test('reverse', () {
      expect(query('. | reverse', [1, 2, 3]), [3, 2, 1]);
    });

    test('keys on map', () {
      final result = query('. | keys', {'a': 1, 'b': 2});
      expect(result, ['a', 'b']);
    });

    test('values on map', () {
      final result = query('. | values', {'a': 1, 'b': 2});
      expect(result, [1, 2]);
    });

    test('length on list', () {
      expect(query('. | length', [1, 2, 3]), 3);
    });

    test('length on map', () {
      expect(query('. | length', {'a': 1, 'b': 2}), 2);
    });

    test('length on string', () {
      expect(query('. | length', 'hello'), 5);
    });

    test('first', () {
      expect(query('. | first', [10, 20, 30]), 10);
    });

    test('first on empty list', () {
      expect(query('. | first', <Object?>[]), null);
    });

    test('last', () {
      expect(query('. | last', [10, 20, 30]), 30);
    });

    test('last on empty list', () {
      expect(query('. | last', <Object?>[]), null);
    });
  });

  group('Chained pipelines', () {
    test('filter then map then sort', () {
      final data = {
        'users': [
          {'name': 'Carol', 'age': 45},
          {'name': 'Alice', 'age': 25},
          {'name': 'Bob', 'age': 35},
        ],
      };
      final result = query(
        '.users | filter(.age > 30) | map(.name) | sort',
        data,
      );
      expect(result, ['Bob', 'Carol']);
    });
  });

  group('Edge cases', () {
    test('null field returns null, not error', () {
      expect(query('.x', {'x': null}), null);
    });

    test('nested null field', () {
      expect(
        query('.a.b', {
          'a': {'b': null},
        }),
        null,
      );
    });

    test('division by zero returns infinity', () {
      expect(query('.a / .b', {'a': 1, 'b': 0}), double.infinity);
    });

    test('modulo by zero returns NaN', () {
      final result = query('.a % .b', {'a': 1, 'b': 0});
      expect((result as double).isNaN, true);
    });

    test('boolean in arithmetic throws', () {
      expect(() => query('.x + 1', {'x': true}), throwsA(isA<EvalException>()));
    });

    test('string comparison with == works', () {
      expect(query('.a == .b', {'a': 'x', 'b': 'x'}), true);
      expect(query('.a == .b', {'a': 'x', 'b': 'y'}), false);
    });

    test('null equality', () {
      expect(query('.a == null', {'a': null}), true);
      expect(query('.a != null', {'a': 42}), true);
    });

    test('sort on empty list', () {
      expect(query('. | sort', <Object?>[]), <Object?>[]);
    });

    test('filter on empty list', () {
      expect(query('. | filter(.x)', <Object?>[]), <Object?>[]);
    });

    test('map on empty list', () {
      expect(query('. | map(.x)', <Object?>[]), <Object?>[]);
    });

    test('keys on empty map', () {
      expect(query('. | keys', <String, Object?>{}), <Object?>[]);
    });

    test('length on empty string', () {
      expect(query('. | length', ''), 0);
    });

    test('sort mixed types throws', () {
      expect(
        () => query('. | sort', <Object?>[1, 'a']),
        throwsA(isA<EvalException>()),
      );
    });

    test('sort strings', () {
      expect(query('. | sort', ['banana', 'apple', 'cherry']), [
        'apple',
        'banana',
        'cherry',
      ]);
    });

    test('map indexing with string key', () {
      expect(
        query('.data["x"]', {
          'data': {'x': 42},
        }),
        42,
      );
    });

    test('pipeline keyword as field name', () {
      expect(query('.filter', {'filter': 'value'}), 'value');
      expect(query('.sort', {'sort': 123}), 123);
      expect(query('.length', {'length': 99}), 99);
    });

    test('nested pipeline in filter', () {
      final data = {
        'users': [
          {
            'name': 'Alice',
            'tags': <Object?>['admin', 'user'],
          },
          {'name': 'Bob', 'tags': <Object?>[]},
        ],
      };
      final result = query(
        '.users | filter(.tags | length > 0) | map(.name)',
        data,
      );
      expect(result, ['Alice']);
    });

    test('deeply nested access', () {
      expect(
        query('.a.b.c.d.e', {
          'a': {
            'b': {
              'c': {
                'd': {'e': 'deep'},
              },
            },
          },
        }),
        'deep',
      );
    });

    test('mixed index and access chain', () {
      final data = {
        'users': [
          {
            'addresses': [
              {'city': 'Paris'},
              {'city': 'London'},
            ],
          },
        ],
      };
      expect(query('.users[0].addresses[1].city', data), 'London');
    });
  });

  group('End-to-end showpiece', () {
    test('queryJson with filter and map', () {
      final result = queryJson(
        '.users | filter(.age > 30) | map(.name)',
        '{"users":[{"name":"Alice","age":25},{"name":"Bob","age":35}]}',
      );
      expect(result, ['Bob']);
    });
  });
}
