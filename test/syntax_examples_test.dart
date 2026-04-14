import 'package:lambe/lambe.dart';
import 'package:rumil_expressions/rumil_expressions.dart' show EvalException;
import 'package:test/test.dart';

/// Tests every example from doc/syntax.md against the shared sample data.
///
/// If an example in the syntax doc fails here, either the doc is wrong or
/// the implementation has regressed. They must stay in sync.
void main() {
  final data = {
    'users': <Object?>[
      {'name': 'Alice', 'age': 25, 'active': true},
      {'name': 'Bob', 'age': 35, 'active': false},
      {'name': 'Carol', 'age': 42, 'active': true},
    ],
    'config': {
      'database': {'host': 'localhost', 'port': 5432},
      'debug': false,
    },
    'version': '1.0.0',
    'tags': <Object?>['api', 'v1', 'stable'],
  };

  group('Identity', () {
    test('. returns the entire document', () {
      expect(query('.', data), data);
    });
  });

  group('Field access', () {
    test('.version', () {
      expect(query('.version', data), '1.0.0');
    });

    test('.config.database.host', () {
      expect(query('.config.database.host', data), 'localhost');
    });

    test('.missing returns null', () {
      expect(query('.missing', data), null);
    });

    test('.missing.nested returns null', () {
      expect(query('.missing.nested', data), null);
    });
  });

  group('Indexing', () {
    test('.users[0]', () {
      expect(query('.users[0]', data), {
        'name': 'Alice',
        'age': 25,
        'active': true,
      });
    });

    test('.users[-1].name', () {
      expect(query('.users[-1].name', data), 'Carol');
    });

    test('.tags[1]', () {
      expect(query('.tags[1]', data), 'v1');
    });

    test('.users[99] returns null', () {
      expect(query('.users[99]', data), null);
    });
  });

  group('Slicing', () {
    test('.tags[0:2]', () {
      expect(query('.tags[0:2]', data), ['api', 'v1']);
    });

    test('.tags[:2]', () {
      expect(query('.tags[:2]', data), ['api', 'v1']);
    });

    test('.tags[1:]', () {
      expect(query('.tags[1:]', data), ['v1', 'stable']);
    });

    test('.tags[:-1]', () {
      expect(query('.tags[:-1]', data), ['api', 'v1']);
    });

    test('.version[0:1] (string slicing)', () {
      expect(query('.version[0:1]', data), '1');
    });
  });

  group('Arithmetic', () {
    test('.users[0].age + 10', () {
      expect(query('.users[0].age + 10', data), 35);
    });

    test('.users[0].age * 2', () {
      expect(query('.users[0].age * 2', data), 50);
    });

    test('.config.database.port % 100', () {
      expect(query('.config.database.port % 100', data), 32);
    });

    test('.missing + 5 throws', () {
      expect(() => query('.missing + 5', data), throwsA(isA<EvalException>()));
    });
  });

  group('Comparison', () {
    test('.users[0].age > 30', () {
      expect(query('.users[0].age > 30', data), false);
    });

    test('.version == "1.0.0"', () {
      expect(query('.version == "1.0.0"', data), true);
    });

    test('.config.debug != true', () {
      expect(query('.config.debug != true', data), true);
    });

    test('.missing > 5 throws', () {
      expect(() => query('.missing > 5', data), throwsA(isA<EvalException>()));
    });

    test('.missing == null', () {
      expect(query('.missing == null', data), true);
    });
  });

  group('Boolean logic', () {
    test('.users[0].active && .users[0].age < 30', () {
      expect(query('.users[0].active && .users[0].age < 30', data), true);
    });

    test('!.config.debug', () {
      expect(query('!.config.debug', data), true);
    });
  });

  group('String literals', () {
    test('filter with string comparison then length', () {
      expect(query('.users | filter(.name == "Alice") | length', data), 1);
    });
  });

  group('String interpolation', () {
    test(r'.users | map("\(.name) is \(.age)")', () {
      expect(query(r'.users | map("\(.name) is \(.age)")', data), [
        'Alice is 25',
        'Bob is 35',
        'Carol is 42',
      ]);
    });
  });

  group('Object construction', () {
    test('.users[0] | {name, age}', () {
      expect(query('.users[0] | {name, age}', data), {
        'name': 'Alice',
        'age': 25,
      });
    });

    test('.users | map({name, senior: .age > 40})', () {
      expect(query('.users | map({name, senior: .age > 40})', data), [
        {'name': 'Alice', 'senior': false},
        {'name': 'Bob', 'senior': false},
        {'name': 'Carol', 'senior': true},
      ]);
    });
  });

  group('Conditionals', () {
    test('.users | map(if .age > 40 then "senior" else "junior")', () {
      expect(
        query('.users | map(if .age > 40 then "senior" else "junior")', data),
        ['junior', 'junior', 'senior'],
      );
    });
  });

  group('Pipelines', () {
    test('.users | filter(.active) | sort_by(.age) | map(.name)', () {
      expect(
        query('.users | filter(.active) | sort_by(.age) | map(.name)', data),
        ['Alice', 'Carol'],
      );
    });

    test('.tags | length > 0 (precedence)', () {
      expect(query('.tags | length > 0', data), true);
    });
  });

  group('filter', () {
    test('.users | filter(.age > 30)', () {
      expect(query('.users | filter(.age > 30) | map(.name)', data), [
        'Bob',
        'Carol',
      ]);
    });

    test('.users | filter(.active && .age < 40)', () {
      expect(query('.users | filter(.active && .age < 40)', data), [
        {'name': 'Alice', 'age': 25, 'active': true},
      ]);
    });
  });

  group('map', () {
    test('.users | map(.name)', () {
      expect(query('.users | map(.name)', data), ['Alice', 'Bob', 'Carol']);
    });

    test('.users | map(.age * 2)', () {
      expect(query('.users | map(.age * 2)', data), [50, 70, 84]);
    });
  });

  group('sort', () {
    test('.tags | sort', () {
      expect(query('.tags | sort', data), ['api', 'stable', 'v1']);
    });
  });

  group('sort_by', () {
    test('.users | sort_by(.name) | map(.name)', () {
      expect(query('.users | sort_by(.name) | map(.name)', data), [
        'Alice',
        'Bob',
        'Carol',
      ]);
    });
  });

  group('group_by', () {
    test('.users | group_by(.active)', () {
      final result = query('.users | group_by(.active)', data) as List<Object?>;
      expect(result, hasLength(2));
      final trueGroup =
          result.firstWhere((g) => (g as Map)['key'] == true) as Map;
      final falseGroup =
          result.firstWhere((g) => (g as Map)['key'] == false) as Map;
      expect((trueGroup['values'] as List).map((u) => (u as Map)['name']), [
        'Alice',
        'Carol',
      ]);
      expect((falseGroup['values'] as List).map((u) => (u as Map)['name']), [
        'Bob',
      ]);
    });
  });

  group('unique', () {
    test('[1, 2, 2, 3, 1] | unique', () {
      expect(query('. | unique', <Object?>[1, 2, 2, 3, 1]), [1, 2, 3]);
    });
  });

  group('unique_by', () {
    test('.users | unique_by(.active) | map(.name)', () {
      expect(query('.users | unique_by(.active) | map(.name)', data), [
        'Alice',
        'Bob',
      ]);
    });
  });

  group('flatten', () {
    test('[[1, 2], [3, 4], [5]] | flatten', () {
      expect(
        query('. | flatten', <Object?>[
          <Object?>[1, 2],
          <Object?>[3, 4],
          <Object?>[5],
        ]),
        [1, 2, 3, 4, 5],
      );
    });
  });

  group('reverse', () {
    test('.tags | reverse', () {
      expect(query('.tags | reverse', data), ['stable', 'v1', 'api']);
    });
  });

  group('keys', () {
    test('.config | keys', () {
      expect(query('.config | keys', data), ['database', 'debug']);
    });

    test('.tags | keys', () {
      expect(query('.tags | keys', data), [0, 1, 2]);
    });
  });

  group('values', () {
    test('.config.database | values', () {
      expect(query('.config.database | values', data), ['localhost', 5432]);
    });
  });

  group('length', () {
    test('.users | length', () {
      expect(query('.users | length', data), 3);
    });

    test('.version | length', () {
      expect(query('.version | length', data), 5);
    });
  });

  group('first, last', () {
    test('.users | first | .name', () {
      expect(query('.users | first | .name', data), 'Alice');
    });

    test('.tags | last', () {
      expect(query('.tags | last', data), 'stable');
    });
  });

  group('sum, avg, min, max', () {
    test('.users | map(.age) | sum', () {
      expect(query('.users | map(.age) | sum', data), 102);
    });

    test('.users | map(.age) | avg', () {
      expect(query('.users | map(.age) | avg', data), 34.0);
    });

    test('.users | map(.age) | min', () {
      expect(query('.users | map(.age) | min', data), 25);
    });

    test('.users | map(.age) | max', () {
      expect(query('.users | map(.age) | max', data), 42);
    });
  });

  group('has', () {
    test('.config | has("database")', () {
      expect(query('.config | has("database")', data), true);
    });

    test('.config | has("missing")', () {
      expect(query('.config | has("missing")', data), false);
    });
  });

  group('to_entries, from_entries', () {
    test('.config.database | to_entries', () {
      expect(query('.config.database | to_entries', data), [
        {'key': 'host', 'value': 'localhost'},
        {'key': 'port', 'value': 5432},
      ]);
    });

    test('[{"key": "a", "value": 1}] | from_entries', () {
      expect(
        query('. | from_entries', <Object?>[
          {'key': 'a', 'value': 1},
        ]),
        {'a': 1},
      );
    });
  });

  group('filter_values', () {
    test('.config.database | filter_values(. == "localhost")', () {
      expect(
        query('.config.database | filter_values(. == "localhost")', data),
        {'host': 'localhost'},
      );
    });
  });

  group('map_values', () {
    test('{"a": 1, "b": 2} | map_values(. * 10)', () {
      expect(query('. | map_values(. * 10)', {'a': 1, 'b': 2}), {
        'a': 10,
        'b': 20,
      });
    });
  });

  group('filter_keys', () {
    test('.config | filter_keys(. != "debug")', () {
      expect(query('.config | filter_keys(. != "debug")', data), {
        'database': {'host': 'localhost', 'port': 5432},
      });
    });
  });

  group('Null propagation', () {
    test('.missing returns null', () {
      expect(query('.missing', data), null);
    });

    test('.missing.nested returns null', () {
      expect(query('.missing.nested', data), null);
    });

    test('.users[99] returns null', () {
      expect(query('.users[99]', data), null);
    });

    test('null | length returns null', () {
      expect(query('. | length', null), null);
    });

    test('null | filter(.x) returns null', () {
      expect(query('. | filter(.x)', null), null);
    });

    test('null + 5 throws', () {
      expect(() => query('.missing + 5', data), throwsA(isA<EvalException>()));
    });

    test('null > 3 throws', () {
      expect(() => query('.missing > 5', data), throwsA(isA<EvalException>()));
    });

    test('if null then 1 else 2 throws', () {
      expect(
        () => query('if .missing then 1 else 2', data),
        throwsA(isA<EvalException>()),
      );
    });
  });
}
