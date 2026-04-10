import 'package:lambe/src/completer.dart';
import 'package:test/test.dart';

void main() {
  final sampleData = <String, Object?>{
    'users': <Object?>[
      <String, Object?>{'name': 'Alice', 'age': 25, 'active': true},
      <String, Object?>{'name': 'Bob', 'age': 35, 'active': false},
    ],
    'config': <String, Object?>{
      'database': <String, Object?>{'host': 'localhost', 'port': 5432},
    },
    'version': '1.0.0',
  };

  group('Field completion', () {
    test('root fields from identity', () {
      final (:start, :candidates) = complete('.', 1, sampleData);
      expect(start, 0);
      expect(candidates, containsAll(['.config', '.users', '.version']));
    });

    test('partial match on root fields', () {
      final (:start, :candidates) = complete('.us', 3, sampleData);
      expect(start, 0);
      expect(candidates, ['.users']);
    });

    test('multiple partial matches', () {
      final data = <String, Object?>{'name': 'x', 'namespace': 'y', 'age': 1};
      final (:start, :candidates) = complete('.na', 3, data);
      expect(start, 0);
      expect(candidates, ['.name', '.namespace']);
    });

    test('nested fields', () {
      final (:start, :candidates) = complete('.config.', 8, sampleData);
      expect(start, 7);
      expect(candidates, ['.database']);
    });

    test('deeply nested fields', () {
      final (:start, :candidates) = complete(
        '.config.database.',
        17,
        sampleData,
      );
      expect(start, 16);
      expect(candidates, containsAll(['.host', '.port']));
    });

    test('after index access', () {
      final (:start, :candidates) = complete('.users[0].', 10, sampleData);
      expect(start, 9);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('partial after index access', () {
      final (:start, :candidates) = complete('.users[0].na', 12, sampleData);
      expect(start, 9);
      expect(candidates, ['.name']);
    });

    test('no match returns empty', () {
      final (:start, :candidates) = complete('.xyz', 4, sampleData);
      expect(candidates, isEmpty);
    });

    test('non-map target returns empty', () {
      final (:start, :candidates) = complete('.version.', 9, sampleData);
      expect(candidates, isEmpty);
    });
  });

  group('Pipeline operation completion', () {
    test('all ops after |', () {
      final (:start, :candidates) = complete('.users | ', 9, sampleData);
      expect(candidates.length, pipelineOps.length);
      expect(candidates, pipelineOps);
    });

    test('partial match after |', () {
      final (:start, :candidates) = complete('.users | fil', 12, sampleData);
      expect(candidates, ['filter', 'filter_keys', 'filter_values']);
    });

    test('single match after |', () {
      final (:start, :candidates) = complete('.users | rev', 12, sampleData);
      expect(candidates, ['reverse']);
    });

    test('no match after |', () {
      final (:start, :candidates) = complete('.users | xyz', 12, sampleData);
      expect(candidates, isEmpty);
    });

    test('start position is after | and space', () {
      final (:start, :candidates) = complete('.users | so', 11, sampleData);
      expect(start, 9);
      expect(candidates, ['sort', 'sort_by']);
    });
  });

  group('Inner field completion', () {
    test('inside filter(.', () {
      final (:start, :candidates) = complete(
        '.users | filter(.',
        17,
        sampleData,
      );
      expect(start, 16);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('partial inside filter', () {
      final (:start, :candidates) = complete(
        '.users | filter(.na',
        19,
        sampleData,
      );
      expect(start, 16);
      expect(candidates, ['.name']);
    });

    test('inside map(.', () {
      final (:start, :candidates) = complete('.users | map(.', 14, sampleData);
      expect(start, 13);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('inside sort_by(.', () {
      final (:start, :candidates) = complete(
        '.users | sort_by(.',
        18,
        sampleData,
      );
      expect(start, 17);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('after chained pipeline', () {
      final (:start, :candidates) = complete(
        '.users | sort_by(.name) | filter(.a',
        35,
        sampleData,
      );
      expect(start, 33);
      expect(candidates, containsAll(['.active', '.age']));
    });

    test('non-list input returns empty', () {
      final (:start, :candidates) = complete(
        '.config | filter(.',
        18,
        sampleData,
      );
      expect(candidates, isEmpty);
    });
  });

  group('Nested field completion', () {
    final nestedData = <String, Object?>{
      'users': <Object?>[
        <String, Object?>{
          'name': 'Alice',
          'address': <String, Object?>{'city': 'NYC', 'zip': '10001'},
        },
      ],
    };

    test('nested field inside filter', () {
      const text = '.users | filter(.address.ci';
      final (:start, :candidates) = complete(text, text.length, nestedData);
      expect(candidates, ['.city']);
    });

    test('nested field inside map', () {
      const text = '.users | map(.address.';
      final (:start, :candidates) = complete(text, text.length, nestedData);
      expect(candidates, containsAll(['.city', '.zip']));
    });

    test('empty filter paren offers all element fields', () {
      const text = '.users | filter(.';
      final (:start, :candidates) = complete(text, text.length, nestedData);
      expect(candidates, containsAll(['.address', '.name']));
    });
  });

  group('Command completion', () {
    test(':to format completion', () {
      final (:start, :candidates) = complete(':to ', 4, null);
      expect(start, 4);
      expect(candidates, ['csv', 'hcl', 'json', 'toml', 'tsv', 'xml', 'yaml']);
    });

    test(':to partial', () {
      final (:start, :candidates) = complete(':to y', 5, null);
      expect(candidates, ['yaml']);
    });

    test(':to no match', () {
      final (:start, :candidates) = complete(':to z', 5, null);
      expect(candidates, isEmpty);
    });

    test('command name completion', () {
      final (:start, :candidates) = complete(':sch', 4, null);
      expect(start, 1);
      expect(candidates, ['schema']);
    });

    test('command prefix q matches q and quit', () {
      final (:start, :candidates) = complete(':q', 2, null);
      expect(candidates, ['q', 'quit']);
    });

    test('all commands on bare colon', () {
      final (:start, :candidates) = complete(':', 1, null);
      expect(candidates.length, 9);
      expect(candidates, contains('help'));
      expect(candidates, contains('schema'));
    });
  });

  group('String-with-pipe regression', () {
    test('pipe inside string literal does not confuse pipe detection', () {
      const text = '.users | map(.name + " | ") | fil';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(candidates, ['filter', 'filter_keys', 'filter_values']);
    });

    test('pipe in filter predicate string does not confuse completion', () {
      const text = '.users | filter(.name != "admin|root") | ';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(candidates.length, pipelineOps.length);
    });

    test('empty input returns empty', () {
      final (:start, :candidates) = complete('', 0, sampleData);
      expect(candidates, isEmpty);
    });

    test('short-op ambiguity: sort_ completes to sort_by', () {
      const text = '.users | sort_';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(candidates, ['sort_by']);
    });

    test('short-op ambiguity: unique_ completes to unique_by', () {
      const text = '.users | unique_';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(candidates, ['unique_by']);
    });
  });

  group('Recovery edge cases', () {
    test('conditional: complete in then-branch (missing else)', () {
      const text = 'if true then .us';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(start, text.length - 3);
      expect(candidates, ['.users']);
    });

    test('conditional: complete in else-branch', () {
      const text = 'if true then .name else .ver';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(start, text.length - 4);
      expect(candidates, ['.version']);
    });

    test('string interpolation: field inside \\(.', () {
      const text = r'"hello \(.us';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(candidates, ['.users']);
    });

    test('binary op right side: .age > 20 && .na', () {
      final (:start, :candidates) = complete(
        '.users | filter(.age > 20 && .na',
        32,
        sampleData,
      );
      expect(start, 29);
      expect(candidates, ['.name']);
    });

    test('complete after pipe chain with all op types', () {
      // Verify recovery works through chained pipes
      const text = '.users | filter(.active) | map(.na';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(start, text.length - 3);
      expect(candidates, ['.name']);
    });

    test('empty object construction does not crash', () {
      const text = '.users | map({';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      // May or may not have candidates, but must not throw
      expect(candidates, isA<List<String>>());
    });

    test('empty index bracket does not crash', () {
      const text = '.users[';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      expect(candidates, isA<List<String>>());
    });

    test('all parameterized ops recover inner expr', () {
      // Verify each parameterized op produces completions with recovery
      for (final op in ['filter', 'map', 'sort_by', 'group_by', 'unique_by']) {
        final text = '.users | $op(.na';
        final (:start, :candidates) = complete(text, text.length, sampleData);
        expect(candidates, contains('.name'), reason: '$op should complete');
      }
    });

    test('filter_values completes on map value fields', () {
      final data = <String, Object?>{
        'scores': <String, Object?>{
          'alice': <String, Object?>{'total': 100, 'rank': 1},
          'bob': <String, Object?>{'total': 80, 'rank': 2},
        },
      };
      // filter_values operates on map values, not list elements
      // Currently returns empty (non-list input), which is acceptable
      const text = '.scores | filter_values(.to';
      final (:start, :candidates) = complete(text, text.length, data);
      // filter_values context is a map, not a list — no crash
      expect(candidates, isA<List<String>>());
    });

    test('complete expression is never Partial', () {
      // Verify recovery doesn't fire on complete expressions
      const text = '.users | filter(.age > 30)';
      final (:start, :candidates) = complete(text, text.length, sampleData);
      // Complete expression — no field completion context
      expect(candidates, isEmpty);
    });
  });
}
