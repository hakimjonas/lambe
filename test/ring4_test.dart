import 'package:lambe/lambe.dart';
import 'package:rumil/rumil.dart';
import 'package:rumil_expressions/rumil_expressions.dart' show EvalException;
import 'package:test/test.dart';

LamExpr _parse(String input) {
  final result = parse(input);
  return switch (result) {
    Success<ParseError, LamExpr>(:final value) => value,
    Partial<ParseError, LamExpr>(:final value) => value,
    Failure<ParseError, LamExpr>() => fail('Parse failed: ${result.errors}'),
  };
}

void main() {
  final users = [
    {'name': 'Carol', 'age': 45, 'dept': 'eng'},
    {'name': 'Alice', 'age': 25, 'dept': 'eng'},
    {'name': 'Bob', 'age': 35, 'dept': 'sales'},
    {'name': 'Dave', 'age': 30, 'dept': 'sales'},
  ];

  group('sort_by', () {
    test('sort_by(.name)', () {
      final result = query('.users | sort_by(.name)', {'users': users}) as List;
      expect((result[0] as Map)['name'], 'Alice');
      expect((result[1] as Map)['name'], 'Bob');
      expect((result[2] as Map)['name'], 'Carol');
      expect((result[3] as Map)['name'], 'Dave');
    });

    test('sort_by(.age)', () {
      final result = query('.users | sort_by(.age)', {'users': users}) as List;
      expect((result[0] as Map)['name'], 'Alice');
      expect((result[3] as Map)['name'], 'Carol');
    });

    test('parse structure', () {
      final expr = _parse('. | sort_by(.name)');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<SortByOp>());
    });
  });

  group('group_by', () {
    test('group_by(.dept)', () {
      final result =
          query('.users | group_by(.dept)', {'users': users}) as List;
      expect(result, hasLength(2));

      final eng = result.firstWhere((g) => (g as Map)['key'] == 'eng') as Map;
      final sales =
          result.firstWhere((g) => (g as Map)['key'] == 'sales') as Map;

      expect((eng['values'] as List), hasLength(2));
      expect((sales['values'] as List), hasLength(2));
    });

    test('group_by returns {key, values} structure', () {
      final result =
          query('. | group_by(.type)', [
                {'type': 'a', 'v': 1},
                {'type': 'b', 'v': 2},
                {'type': 'a', 'v': 3},
              ])
              as List;

      for (final group in result) {
        final g = group as Map;
        expect(g.containsKey('key'), true);
        expect(g.containsKey('values'), true);
        expect(g['values'], isA<List<Object?>>());
      }
    });

    test('parse structure', () {
      final expr = _parse('. | group_by(.type)');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<GroupByOp>());
    });
  });

  group('unique / unique_by', () {
    test('unique', () {
      expect(query('. | unique', [1, 2, 1, 3, 2]), [1, 2, 3]);
    });

    test('unique preserves order', () {
      expect(query('. | unique', [3, 1, 3, 2, 1]), [3, 1, 2]);
    });

    test('unique on empty', () {
      expect(query('. | unique', <Object?>[]), <Object?>[]);
    });

    test('unique_by(.name)', () {
      final data = [
        {'name': 'Alice', 'age': 25},
        {'name': 'Bob', 'age': 35},
        {'name': 'Alice', 'age': 30},
      ];
      final result = query('. | unique_by(.name)', data) as List;
      expect(result, hasLength(2));
      expect((result[0] as Map)['name'], 'Alice');
      expect((result[0] as Map)['age'], 25); // first occurrence kept
      expect((result[1] as Map)['name'], 'Bob');
    });
  });

  group('flatten', () {
    test('one level', () {
      expect(
        query('. | flatten', [
          [1, 2],
          [3, 4],
        ]),
        [1, 2, 3, 4],
      );
    });

    test('only one level deep', () {
      expect(
        query('. | flatten', [
          1,
          [
            2,
            [3],
          ],
        ]),
        [
          1,
          2,
          [3],
        ],
      );
    });

    test('mixed elements', () {
      expect(
        query('. | flatten', [
          1,
          [2, 3],
          'a',
        ]),
        [1, 2, 3, 'a'],
      );
    });

    test('empty', () {
      expect(query('. | flatten', <Object?>[]), <Object?>[]);
    });
  });

  group('filter_values / map_values / filter_keys', () {
    test('filter_values', () {
      final result = query('. | filter_values(. > 2)', {
        'a': 1,
        'b': 3,
        'c': 5,
      });
      expect(result, {'b': 3, 'c': 5});
    });

    test('map_values', () {
      final result = query('. | map_values(. * 2)', {'a': 1, 'b': 2, 'c': 3});
      expect(result, {'a': 2, 'b': 4, 'c': 6});
    });

    test('filter_keys', () {
      final result = query('. | filter_keys(. != "internal")', {
        'name': 'Alice',
        'internal': 'secret',
        'age': 30,
      });
      expect(result, {'name': 'Alice', 'age': 30});
    });

    test('filter_values on empty map', () {
      expect(
        query('. | filter_values(. > 0)', <String, Object?>{}),
        <String, Object?>{},
      );
    });

    test('map_values on empty map', () {
      expect(
        query('. | map_values(. * 2)', <String, Object?>{}),
        <String, Object?>{},
      );
    });

    test('filter_values on non-map throws', () {
      expect(
        () => query('. | filter_values(. > 0)', [1, 2]),
        throwsA(isA<QueryError>()),
      );
    });
  });

  group('Object construction', () {
    test('explicit keys', () {
      final result = query('{name: .name, years: .age}', {
        'name': 'Alice',
        'age': 25,
      });
      expect(result, {'name': 'Alice', 'years': 25});
    });

    test('shorthand', () {
      final result = query('{name, age}', {'name': 'Alice', 'age': 25});
      expect(result, {'name': 'Alice', 'age': 25});
    });

    test('mixed shorthand and computed', () {
      final result = query('{name, total: .price * .qty}', {
        'name': 'Widget',
        'price': 10,
        'qty': 3,
      });
      expect(result, {'name': 'Widget', 'total': 30});
    });

    test('in map pipeline', () {
      final data = {
        'items': [
          {'name': 'A', 'price': 10, 'qty': 2},
          {'name': 'B', 'price': 5, 'qty': 3},
        ],
      };
      final result =
          query('.items | map({name, total: .price * .qty})', data) as List;
      expect(result[0], {'name': 'A', 'total': 20});
      expect(result[1], {'name': 'B', 'total': 15});
    });

    test('empty object', () {
      expect(query('{}', {'x': 1}), <String, Object?>{});
    });

    test('parse structure', () {
      final expr = _parse('{name, total: .price}');
      expect(expr, isA<ObjConstruct>());
      final obj = expr as ObjConstruct;
      expect(obj.entries, hasLength(2));
      expect(obj.entries[0].$1, 'name');
      expect(obj.entries[0].$2, isA<Field>()); // shorthand
      expect(obj.entries[1].$1, 'total');
      expect(obj.entries[1].$2, isA<Field>()); // explicit
    });
  });

  group('Conditionals', () {
    test('if true then a else b', () {
      expect(
        query('if .age > 30 then "senior" else "junior"', {'age': 45}),
        'senior',
      );
      expect(
        query('if .age > 30 then "senior" else "junior"', {'age': 25}),
        'junior',
      );
    });

    test('in map pipeline', () {
      final data = [
        {'name': 'Alice', 'age': 65},
        {'name': 'Bob', 'age': 25},
      ];
      final result = query(
        '. | map(if .age > 60 then "retired" else "active")',
        data,
      );
      expect(result, ['retired', 'active']);
    });

    test('nested conditional', () {
      expect(
        query('if .x > 10 then "high" else if .x > 5 then "mid" else "low"', {
          'x': 7,
        }),
        'mid',
      );
    });

    test('non-bool condition throws', () {
      expect(
        () => query('if .x then "yes" else "no"', {'x': 42}),
        throwsA(isA<EvalException>()),
      );
    });

    test('parse structure', () {
      final expr = _parse('if .x then .a else .b');
      expect(expr, isA<Conditional>());
      final cond = expr as Conditional;
      expect(cond.condition, isA<Field>());
      expect(cond.then_, isA<Field>());
      expect(cond.else_, isA<Field>());
    });
  });

  group('Ring 4 integration', () {
    test('full pipeline: filter + sort_by + map with object construction', () {
      final data = {
        'employees': [
          {'name': 'Carol', 'salary': 90000, 'dept': 'eng'},
          {'name': 'Alice', 'salary': 120000, 'dept': 'eng'},
          {'name': 'Bob', 'salary': 80000, 'dept': 'sales'},
        ],
      };
      final result =
          query(
                '.employees | filter(.salary > 85000) | sort_by(.name) | map({name, dept})',
                data,
              )
              as List;
      expect(result, [
        {'name': 'Alice', 'dept': 'eng'},
        {'name': 'Carol', 'dept': 'eng'},
      ]);
    });

    test('group_by + map with conditional', () {
      final data = [
        {'type': 'expense', 'amount': 50},
        {'type': 'income', 'amount': 200},
        {'type': 'expense', 'amount': 30},
        {'type': 'income', 'amount': 150},
      ];
      final result =
          query(
                '. | group_by(.type) | map({type: .key, total: .values | map(.amount) | sum})',
                data,
              )
              as List;
      expect(result, hasLength(2));
      // Find the expense group
      final expense =
          result.firstWhere((g) => (g as Map)['type'] == 'expense') as Map;
      expect(expense['total'], 80);
    });

    test('filter_values + map_values on config', () {
      final config = {
        'debug': true,
        'verbose': false,
        'trace': true,
        'quiet': false,
      };
      final enabled = query('. | filter_values(.)', config);
      expect(enabled, {'debug': true, 'trace': true});
    });

    test('unique_by + flatten', () {
      final data = {
        'teams': [
          {
            'members': [
              {'id': 1, 'name': 'Alice'},
              {'id': 2, 'name': 'Bob'},
            ],
          },
          {
            'members': [
              {'id': 2, 'name': 'Bob'},
              {'id': 3, 'name': 'Carol'},
            ],
          },
        ],
      };
      final result = query(
        '.teams | map(.members) | flatten | unique_by(.id) | map(.name) | sort',
        data,
      );
      expect(result, ['Alice', 'Bob', 'Carol']);
    });
  });
}
