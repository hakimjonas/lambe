import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

/// Tests that `unique`, `unique_by`, and `group_by` use structural equality
/// on collection-valued keys.
///
/// Dart's native `==` on Map and List is reference equality, so without a
/// canonical-key strategy, `unique` on `[{a:1}, {a:1}]` would return both
/// entries. These tests pin down the correct structural behavior.
void main() {
  group('unique on structurally-equal collections', () {
    test('maps with identical fields deduplicate', () {
      expect(
        query('unique', [
          <String, Object?>{'a': 1},
          <String, Object?>{'a': 1},
          <String, Object?>{'a': 2},
        ]),
        [
          <String, Object?>{'a': 1},
          <String, Object?>{'a': 2},
        ],
      );
    });

    test('lists with identical elements deduplicate', () {
      expect(
        query('unique', <Object?>[
          <Object?>[1, 2],
          <Object?>[1, 2],
          <Object?>[3, 4],
        ]),
        [
          [1, 2],
          [3, 4],
        ],
      );
    });

    test('nested maps deduplicate', () {
      expect(
        query('unique', <Object?>[
          <String, Object?>{
            'outer': <String, Object?>{'inner': 'x'},
          },
          <String, Object?>{
            'outer': <String, Object?>{'inner': 'x'},
          },
          <String, Object?>{
            'outer': <String, Object?>{'inner': 'y'},
          },
        ]),
        [
          {
            'outer': {'inner': 'x'},
          },
          {
            'outer': {'inner': 'y'},
          },
        ],
      );
    });

    test('key order does not affect equality', () {
      expect(
        query('unique', <Object?>[
          <String, Object?>{'a': 1, 'b': 2},
          <String, Object?>{'b': 2, 'a': 1},
        ]),
        [
          {'a': 1, 'b': 2},
        ],
      );
    });

    test('primitives still deduplicate', () {
      expect(query('unique', [1, 2, 1, 3, 2]), [1, 2, 3]);
      expect(query('unique', ['a', 'b', 'a']), ['a', 'b']);
    });
  });

  group('unique_by with collection-valued keys', () {
    test('dedup by list-valued key', () {
      expect(
        query('. | unique_by(.tag) | map(.v)', <Object?>[
          <String, Object?>{
            'tag': <Object?>['a', 'b'],
            'v': 1,
          },
          <String, Object?>{
            'tag': <Object?>['a', 'b'],
            'v': 2,
          },
          <String, Object?>{
            'tag': <Object?>['c'],
            'v': 3,
          },
        ]),
        [1, 3],
      );
    });

    test('dedup by map-valued key', () {
      expect(
        query('. | unique_by(.meta) | map(.v)', <Object?>[
          <String, Object?>{
            'meta': <String, Object?>{'kind': 'a'},
            'v': 1,
          },
          <String, Object?>{
            'meta': <String, Object?>{'kind': 'a'},
            'v': 2,
          },
          <String, Object?>{
            'meta': <String, Object?>{'kind': 'b'},
            'v': 3,
          },
        ]),
        [1, 3],
      );
    });
  });

  group('group_by with collection-valued keys', () {
    test('group by list-valued key', () {
      final result = query('. | group_by(.tag)', <Object?>[
        <String, Object?>{
          'tag': <Object?>[1, 2],
          'v': 'a',
        },
        <String, Object?>{
          'tag': <Object?>[1, 2],
          'v': 'b',
        },
        <String, Object?>{
          'tag': <Object?>[3],
          'v': 'c',
        },
      ]);
      expect(result, isA<List<Object?>>());
      final groups = result! as List<Object?>;
      expect(groups.length, 2);

      final first = groups[0]! as Map<String, Object?>;
      expect(first['key'], [1, 2]);
      expect((first['values']! as List).length, 2);

      final second = groups[1]! as Map<String, Object?>;
      expect(second['key'], [3]);
      expect((second['values']! as List).length, 1);
    });

    test('group preserves original key value (not stringified)', () {
      final result = query('. | group_by(.k)', <Object?>[
        <String, Object?>{
          'k': <String, Object?>{'x': 1},
          'v': 'a',
        },
        <String, Object?>{
          'k': <String, Object?>{'x': 1},
          'v': 'b',
        },
      ]);
      final groups = result! as List<Object?>;
      final group = groups[0]! as Map<String, Object?>;
      // Key is preserved as the original Map, not a JSON string.
      expect(group['key'], isA<Map<String, Object?>>());
      expect(group['key'], {'x': 1});
    });
  });
}
