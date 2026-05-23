/// Pins `canWriteAs` to `formatOutput` ground truth.
///
/// For every representative value and every [OutputFormat], this test
/// runs the writer and cross-checks the shape predicate: `Writable` must
/// never result in [OutputShapeError], and `NotWritable` must always
/// result in [OutputShapeError]. The `Writable` side is allowed to
/// raise [QueryError] from the writer's defensive guard (which only
/// fires when the shape language was too lossy to prove the mismatch,
/// typically [SAny] buried inside a container). What is strictly
/// forbidden is silent stringification, which is what the original
/// CSV round-trip bug produced.
///
/// This test is the structural complement to
/// `pipe_ops_consistency_test.dart`. The pipe-op matrix pins evaluator
/// vs. spec; this one pins writer vs. shape check. Together they
/// prevent a whole class of drift: a future contributor weakens one
/// side without the other, and one of these matrices fails loudly.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

final _representatives = <String, Object?>{
  'null': null,
  'bool': true,
  'number': 42,
  'string': 'hello',
  'empty list': <Object?>[],
  'list of scalars': <Object?>[1, 2, 3],
  'list of maps with scalar cells': <Object?>[
    {'a': 1, 'b': 'x'},
    {'a': 2, 'b': 'y'},
  ],
  'list of maps with a list-valued cell': <Object?>[
    {
      'key': 'items',
      'value': <Object?>[1, 2, 3],
    },
  ],
  'list of maps with a map-valued cell': <Object?>[
    {
      'key': 'first',
      'value': <String, Object?>{'nested': 'x'},
    },
  ],
  'list of lists of scalars': <Object?>[
    <Object?>[1, 2, 3],
    <Object?>[4, 5, 6],
  ],
  'list of maps with disjoint scalar keys': <Object?>[
    {'a': 1},
    {'b': 2},
  ],
  'list of maps with overlapping but non-identical scalar keys': <Object?>[
    {'a': 1, 'b': 2},
    {'b': 3, 'c': 4},
  ],
  'empty map': <String, Object?>{},
  'map of scalars': <String, Object?>{'a': 1, 'b': 'x'},
  'map with a list field': <String, Object?>{
    'deps': <Object?>[1, 2, 3],
  },
  'map with a nested map field': <String, Object?>{
    'inner': <String, Object?>{'k': 'v'},
  },
};

void main() {
  group('canWriteAs agrees with formatOutput across the full matrix', () {
    for (final entry in _representatives.entries) {
      final label = entry.key;
      final value = entry.value;
      for (final fmt in OutputFormat.values) {
        test('$label as ${fmt.name}', () {
          final report = canWriteAs(value, fmt);
          Object? thrown;
          try {
            formatOutput(value, fmt);
          } catch (e) {
            thrown = e;
          }

          switch (report) {
            case Writable():
              expect(
                thrown,
                isNot(isA<OutputShapeError>()),
                reason:
                    'canWriteAs said Writable for $label -> ${fmt.name}, '
                    'but formatOutput raised OutputShapeError. The shape '
                    'check and the writer disagree on whether this value '
                    'is representable.',
              );
            case NotWritable():
              expect(
                thrown,
                isA<OutputShapeError>(),
                reason:
                    'canWriteAs said NotWritable for $label -> '
                    '${fmt.name}, but formatOutput did not raise '
                    'OutputShapeError. A value the shape check rejects '
                    'must not pass the writer silently.',
              );
          }
        });
      }
    }
  });

  group('canWriteAs agrees with formatOutput under CellPolicy.json', () {
    for (final entry in _representatives.entries) {
      final label = entry.key;
      final value = entry.value;
      for (final fmt in [OutputFormat.csv, OutputFormat.tsv]) {
        test('$label as ${fmt.name} with json policy', () {
          final report = canWriteAs(value, fmt, flattenCells: CellPolicy.json);
          Object? thrown;
          try {
            formatOutput(value, fmt, flattenCells: CellPolicy.json);
          } catch (e) {
            thrown = e;
          }

          switch (report) {
            case Writable():
              expect(
                thrown,
                isNot(isA<OutputShapeError>()),
                reason:
                    'canWriteAs(flattenCells: json) said Writable for '
                    '$label -> ${fmt.name}, but formatOutput raised '
                    'OutputShapeError. Under json policy the writer '
                    'must accept any list shape the check accepts.',
              );
            case NotWritable():
              expect(
                thrown,
                isA<OutputShapeError>(),
                reason:
                    'canWriteAs(flattenCells: json) said NotWritable '
                    'for $label -> ${fmt.name}, but formatOutput did '
                    'not raise OutputShapeError. Widened check and '
                    'widened writer must agree on rejection too.',
              );
          }
        });
      }
    }
  });

  group('NotWritable.hints fire exactly for CSV/TSV refuse + SList root', () {
    for (final entry in _representatives.entries) {
      final label = entry.key;
      final value = entry.value;
      for (final fmt in OutputFormat.values) {
        test('$label as ${fmt.name} under refuse', () {
          final report = canWriteAs(value, fmt);
          if (report is! NotWritable) return; // hints only on rejection.
          final isListRoot = value is List<Object?>;
          final isDelimited =
              fmt == OutputFormat.csv || fmt == OutputFormat.tsv;
          if (isListRoot && isDelimited) {
            expect(
              report.hints,
              hasLength(1),
              reason:
                  'List-root rejection under csv/tsv refuse should surface '
                  'the --flatten-cells hint for $label -> ${fmt.name}.',
            );
            expect(report.hints.first.cliFlag, '--flatten-cells json');
          } else {
            expect(
              report.hints,
              isEmpty,
              reason:
                  'Hint should not fire for $label -> ${fmt.name}: the flag '
                  'would not resolve this mismatch.',
            );
          }
        });
      }
    }

    test('json policy never produces hints (nothing left to recommend)', () {
      for (final entry in _representatives.entries) {
        for (final fmt in [OutputFormat.csv, OutputFormat.tsv]) {
          final report = canWriteAs(
            entry.value,
            fmt,
            flattenCells: CellPolicy.json,
          );
          if (report is NotWritable) {
            expect(
              report.hints,
              isEmpty,
              reason:
                  'Already under json policy; no further --flatten-cells '
                  'hint should be added for ${entry.key} -> ${fmt.name}.',
            );
          }
        }
      }
    });
  });

  group('Writer never silently stringifies non-scalar CSV/TSV cells', () {
    final offenders = <String, Object?>{
      'list of maps with a list-valued cell': <Object?>[
        {
          'key': 'items',
          'value': <Object?>[1, 2, 3],
        },
      ],
      'list of maps with a map-valued cell': <Object?>[
        {
          'key': 'first',
          'value': <String, Object?>{'nested': 'x'},
        },
      ],
    };

    for (final entry in offenders.entries) {
      for (final fmt in [OutputFormat.csv, OutputFormat.tsv]) {
        test('${entry.key} -> ${fmt.name} throws rather than stringifies', () {
          expect(
            () => formatOutput(entry.value, fmt),
            throwsA(isA<QueryError>()),
            reason:
                'Writer must refuse rather than emit Dart toString() '
                'garbage. This is the pre-0.8.0 bug this release closes.',
          );
        });
      }
    }
  });
}
