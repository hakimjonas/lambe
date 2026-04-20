/// Pipeline ops as bare expressions with implicit `.` input.
///
/// `has("k")` parses as sugar for `. | has("k")`, `length` for `. | length`,
/// and so on. Covers standalone ops, ops inside `map` / `filter`, and
/// surrounding contexts (object shorthand, field access, arithmetic) that
/// must continue to resolve in favour of the existing `_atom` alternatives.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('Bare pipeline ops', () {
    test('has() at the root', () {
      expect(query('has("users")', {'users': <Object?>[]}), true);
      expect(query('has("missing")', {'users': <Object?>[]}), false);
    });

    test('length on a list', () {
      expect(query('length', <Object?>[1, 2, 3]), 3);
    });

    test('length on a map', () {
      expect(query('length', {'a': 1, 'b': 2}), 2);
    });

    test('keys on a map', () {
      expect(query('keys', {'a': 1, 'b': 2}), <Object?>['a', 'b']);
    });

    test('sum on a list of numbers', () {
      expect(query('sum', <Object?>[1, 2, 3]), 6);
    });

    test('first on a list', () {
      expect(query('first', <Object?>[1, 2, 3]), 1);
    });

    test('parameterized op: filter at root', () {
      expect(
        query('filter(. > 2)', <Object?>[1, 2, 3, 4]),
        <Object?>[3, 4],
      );
    });
  });

  group('Bare ops inside map', () {
    final data = {
      'users': <Object?>[
        {'email': 'a@x'},
        {'name': 'b'},
      ],
      'lists': <Object?>[
        [1, 2],
        [3, 4, 5],
      ],
    };

    test('map(has("k"))', () {
      expect(query('.users | map(has("email"))', data), [true, false]);
    });

    test('map(length)', () {
      expect(query('.lists | map(length)', data), [2, 3]);
    });

    test('filter(has("k"))', () {
      expect(query('.users | filter(has("email"))', data), [
        {'email': 'a@x'},
      ]);
    });

    test('filter with op + comparison', () {
      expect(query('.lists | filter(length > 2)', data), [
        [3, 4, 5],
      ]);
    });
  });

  group('Bare ops in arithmetic and conditionals', () {
    test('length + 1', () {
      expect(query('length + 1', [1, 2, 3]), 4);
    });

    test('if length > 0 then ... else ...', () {
      expect(query('if length > 0 then "some" else "none"', []), 'none');
      expect(query('if length > 0 then "some" else "none"', [1]), 'some');
    });

    test('string interpolation with bare op', () {
      expect(query(r'"count: \(length)"', [1, 2, 3]), 'count: 3');
    });
  });

  group('Existing constructs still win over op keywords', () {
    test('object shorthand {length} reads field', () {
      expect(
        query('{length}', {'length': 42, 'other': 1}),
        {'length': 42},
      );
    });

    test('object shorthand {keys, values} reads fields', () {
      expect(
        query('{keys, values}', {'keys': 1, 'values': 2}),
        {'keys': 1, 'values': 2},
      );
    });

    test('.length field access still works', () {
      expect(query('.length', {'length': 42}), 42);
    });

    test('.users.length as nested field', () {
      expect(
        query('.users.length', {
          'users': {'length': 5},
        }),
        5,
      );
    });
  });

  group('Bare op equivalence with `. | op`', () {
    test('has', () {
      final d = {'x': 1};
      expect(query('has("x")', d), query('. | has("x")', d));
    });

    test('length on map', () {
      final d = {'x': 1, 'y': 2};
      expect(query('length', d), query('. | length', d));
    });

    test('parameterized inside map', () {
      final d = <Object?>[
        [1, 2],
        [3],
      ];
      expect(query('map(length)', d), query('map(. | length)', d));
    });
  });
}
