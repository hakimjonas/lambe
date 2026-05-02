/// Tests that pin CSV/TSV element-level shape: a list of maps whose cells
/// are not scalar must be rejected, not silently stringified.
///
/// Bug motivating this test: `.deps | as(csv) | as(toml) | as(csv)` on a
/// map-of-strings fixture produced
/// `items,"[{key: rumil, value: ^0.6.0}, ...]"`. The cell's value was
/// Dart's default `List<Map>.toString()` output. `MustBeList.accepts`
/// only checked list-at-the-root; the element shape was never validated.
///
/// The tests fall in two layers:
///
/// 1. Direct `formatOutput` calls on crafted values: a list of maps with a
///    list-valued cell, or a nested-list cell. Must throw a [QueryError]
///    (either [OutputShapeError] from the shape check, or the defensive
///    writer-level guard) rather than produce a row with a stringified
///    Dart `toString()` cell.
/// 2. End-to-end `query` on the real reproduction pipeline. The chain
///    must either succeed with scalar-only cells or raise
///    [OutputShapeError]. It must not silently emit the
///    `[{key: ..., value: ...}]` garbage cell.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('CSV/TSV reject non-scalar cells in list-of-maps', () {
    final listOfMapsWithListValue = <Object?>[
      {
        'key': 'items',
        'value': <Object?>[1, 2, 3],
      },
    ];

    final listOfMapsWithMapValue = <Object?>[
      {
        'key': 'first',
        'value': <String, Object?>{'nested': 'x'},
      },
    ];

    final listOfListsWithListElement = <Object?>[
      <Object?>[
        1,
        <Object?>[2, 3],
      ],
    ];

    for (final fmt in [OutputFormat.csv, OutputFormat.tsv]) {
      test('${fmt.name}: list of maps with a list-valued cell throws', () {
        expect(
          () => formatOutput(listOfMapsWithListValue, fmt),
          throwsA(isA<OutputShapeError>()),
        );
      });

      test('${fmt.name}: list of maps with a map-valued cell throws', () {
        expect(
          () => formatOutput(listOfMapsWithMapValue, fmt),
          throwsA(isA<OutputShapeError>()),
        );
      });

      test('${fmt.name}: list of lists with a nested-list cell throws', () {
        expect(
          () => formatOutput(listOfListsWithListElement, fmt),
          throwsA(isA<QueryError>()),
        );
      });
    }
  });

  group('CSV/TSV end-to-end: as(csv) on non-scalar cells is not silent', () {
    final fixture = <String, Object?>{
      'dependencies': <String, Object?>{
        'rumil': '^0.6.0',
        'rumil_parsers': '^0.6.0',
        'rumil_expressions': '^0.6.0',
      },
    };

    test('the four-stage chain .deps | as(csv) | as(toml) | as(csv) never '
        'emits a Dart toString()-style cell', () {
      const expression = '.dependencies | as(csv) | as(toml) | as(csv)';
      final value = query(expression, fixture);
      try {
        final out = formatOutput(value, OutputFormat.csv);
        expect(
          out,
          isNot(contains('{key:')),
          reason: 'silent Dart toString() garbage leaked into output',
        );
        expect(
          out,
          isNot(contains('[{')),
          reason: 'silent Dart toString() garbage leaked into output',
        );
      } on OutputShapeError {
        return;
      }
    });
  });

  group('CSV/TSV still accept legal scalar-cell shapes', () {
    test('list of maps with scalar cells round-trips', () {
      final v = <Object?>[
        {'a': 1, 'b': 'x'},
        {'a': 2, 'b': 'y'},
      ];
      expect(formatOutput(v, OutputFormat.csv), contains('a,b'));
      expect(formatOutput(v, OutputFormat.tsv), contains('a\tb'));
    });

    test('list of lists of scalars', () {
      final v = <Object?>[
        <Object?>[1, 2, 3],
        <Object?>[4, 5, 6],
      ];
      expect(formatOutput(v, OutputFormat.csv), isNot(isEmpty));
    });

    test('list of scalars', () {
      final v = <Object?>[1, 'two', true, null];
      expect(formatOutput(v, OutputFormat.csv), isNot(isEmpty));
    });

    test('empty list', () {
      expect(formatOutput(<Object?>[], OutputFormat.csv), isEmpty);
    });
  });

  group('NotWritable.hints surface the --flatten-cells escape hatch', () {
    test(
      'csv refuse + non-flat list-of-maps: hint carries all three forms',
      () {
        final v = <Object?>[
          {
            'k': <Object?>[1, 2],
          },
        ];
        final report = canWriteAs(v, OutputFormat.csv) as NotWritable;
        expect(report.hints, hasLength(1));
        final h = report.hints.first;
        expect(h.cliFlag, '--flatten-cells json');
        expect(h.replCommand, ':flatten-cells json');
        expect(h.mcpParameter, ('flatten_cells', 'json'));
        expect(h.label, isNotEmpty);
        expect(h.explanation, isNotEmpty);
      },
    );

    test('csv under json policy accepts the value, no hint to produce', () {
      final v = <Object?>[
        {
          'k': <Object?>[1, 2],
        },
      ];
      final report = canWriteAs(
        v,
        OutputFormat.csv,
        flattenCells: CellPolicy.json,
      );
      expect(report, isA<Writable>());
    });

    test('toml mismatch carries no --flatten-cells hint', () {
      final report =
          canWriteAs(<Object?>[1, 2, 3], OutputFormat.toml) as NotWritable;
      expect(report.hints, isEmpty);
    });

    test(
      'csv refuse + map-rooted rejection: no hint (flag would not help)',
      () {
        final report =
            canWriteAs(<String, Object?>{'a': 1}, OutputFormat.csv)
                as NotWritable;
        expect(report.hints, isEmpty);
      },
    );

    test('OutputShapeError.message does NOT bake hint text', () {
      // Hints are structured data; each surface renders the form that
      // applies to it. The baked message stays neutral so a REPL user
      // does not see --flatten-cells CLI syntax and vice versa.
      final v = <Object?>[
        {
          'k': <Object?>[1, 2],
        },
      ];
      try {
        formatOutput(v, OutputFormat.csv);
        fail('expected OutputShapeError');
      } on OutputShapeError catch (e) {
        expect(e.message, isNot(contains('--flatten-cells')));
        expect(e.message, isNot(contains(':flatten-cells')));
        expect(e.message, isNot(contains('flatten_cells')));
        expect(e.hints, hasLength(1));
      }
    });
  });

  group('Defensive writer guard uses descriptive type names', () {
    test('list cell fires _scalarCell with "list" in the message', () {
      final heteroRows = <Object?>[
        'scalar',
        <Object?>[1, 2],
      ];
      try {
        formatOutput(heteroRows, OutputFormat.csv);
        fail('expected QueryError');
      } on QueryError catch (e) {
        expect(e.message, contains('cell must be a scalar'));
        expect(e.message, contains('list'));
        expect(e.message, isNot(contains('GrowableList')));
      }
    });
  });

  group('CSV/TSV with CellPolicy.json encodes non-scalar cells inline', () {
    final listOfMapsWithListValue = <Object?>[
      {
        'key': 'items',
        'value': <Object?>[1, 2, 3],
      },
    ];
    final listOfMapsWithMapValue = <Object?>[
      {
        'key': 'first',
        'value': <String, Object?>{'nested': 'x'},
      },
    ];
    final listOfListsWithListElement = <Object?>[
      <Object?>[
        1,
        <Object?>[2, 3],
      ],
    ];

    for (final fmt in [OutputFormat.csv, OutputFormat.tsv]) {
      test('${fmt.name}: list-valued cell JSON-encodes', () {
        final out = formatOutput(
          listOfMapsWithListValue,
          fmt,
          flattenCells: CellPolicy.json,
        );
        expect(out, contains('[1,2,3]'));
        expect(out, isNot(contains('{key:')));
      });

      test('${fmt.name}: map-valued cell JSON-encodes', () {
        final out = formatOutput(
          listOfMapsWithMapValue,
          fmt,
          flattenCells: CellPolicy.json,
        );
        // JSON's embedded double-quotes get RFC 4180 escaping (doubled
        // and quote-wrapped) by the delimited writer regardless of
        // delimiter.
        expect(out, contains('"{""nested"":""x""}"'));
      });

      test('${fmt.name}: nested-list cell JSON-encodes', () {
        final out = formatOutput(
          listOfListsWithListElement,
          fmt,
          flattenCells: CellPolicy.json,
        );
        expect(out, contains('[2,3]'));
      });

      test('${fmt.name}: scalar cells still pass through unchanged', () {
        final v = <Object?>[
          {'a': 1, 'b': 'x'},
          {'a': 2, 'b': 'y'},
        ];
        expect(
          formatOutput(v, fmt, flattenCells: CellPolicy.json),
          formatOutput(v, fmt),
        );
      });
    }

    test('canWriteAs widens MustBeFlatList to MustBeList under json', () {
      final value = listOfMapsWithListValue;
      expect(canWriteAs(value, OutputFormat.csv), isA<NotWritable>());
      expect(
        canWriteAs(value, OutputFormat.csv, flattenCells: CellPolicy.json),
        isA<Writable>(),
      );
    });

    test('requirementFor csv/tsv returns MustBeList under json policy', () {
      expect(requirementFor(OutputFormat.csv), isA<MustBeFlatList>());
      expect(
        requirementFor(OutputFormat.csv, flattenCells: CellPolicy.json),
        isA<MustBeList>(),
      );
      expect(
        requirementFor(OutputFormat.tsv, flattenCells: CellPolicy.json),
        isA<MustBeList>(),
      );
    });

    test('refuse policy is unchanged from 0.8.0 default', () {
      expect(
        () => formatOutput(
          listOfMapsWithListValue,
          OutputFormat.csv,
          flattenCells: CellPolicy.refuse,
        ),
        throwsA(isA<OutputShapeError>()),
      );
    });

    test('json policy is still a scalar-root list rejection for non-list', () {
      const scalarRoot = 'hello';
      expect(
        canWriteAs(scalarRoot, OutputFormat.csv, flattenCells: CellPolicy.json),
        isA<NotWritable>(),
      );
    });

    test('json policy: embedded delimiter triggers cell quoting for CSV', () {
      final v = <Object?>[
        {
          'k': <Object?>[1, 2],
        },
      ];
      final csvOut = formatOutput(
        v,
        OutputFormat.csv,
        flattenCells: CellPolicy.json,
      );
      expect(csvOut, contains('"[1,2]"'));
    });
  });

  group('CSV/TSV preserve every column across heterogeneous-keyed rows', () {
    test('disjoint keys: both columns appear, rows fill with empties', () {
      final v = <Object?>[
        {'a': 1},
        {'b': 2},
      ];
      final out = formatOutput(v, OutputFormat.csv);
      expect(out, contains('a,b'));
      expect(out, contains('1,'));
      expect(out, contains(',2'));
    });

    test('overlapping keys: union in first-seen order', () {
      final v = <Object?>[
        {'a': 1, 'b': 2},
        {'b': 3, 'c': 4},
      ];
      final out = formatOutput(v, OutputFormat.csv);
      expect(out.split(RegExp(r'\r?\n')).first, 'a,b,c');
    });

    test('row missing a key renders as empty, not a dropped cell', () {
      final v = <Object?>[
        {'a': 1, 'b': 2},
        {'a': 3},
      ];
      final out = formatOutput(v, OutputFormat.csv);
      final lines = out.split(RegExp(r'\r?\n'));
      expect(lines[0], 'a,b');
      expect(lines[1], '1,2');
      expect(lines[2], '3,');
    });

    test('homogeneous list-of-maps output unchanged by the union pass', () {
      final v = <Object?>[
        {'a': 1, 'b': 2},
        {'a': 3, 'b': 4},
      ];
      final out = formatOutput(v, OutputFormat.csv);
      final lines = out.split(RegExp(r'\r?\n'));
      expect(lines[0], 'a,b');
      expect(lines[1], '1,2');
      expect(lines[2], '3,4');
    });

    test(
      'null value and absent key both render as empty, indistinguishable',
      () {
        final nullValue = <Object?>[
          {'a': 1, 'b': null},
        ];
        final absentKey = <Object?>[
          {'a': 1, 'b': 2},
          {'a': 3},
        ];
        final nullOut = formatOutput(nullValue, OutputFormat.csv);
        final absentOut = formatOutput(absentKey, OutputFormat.csv);
        expect(nullOut.split(RegExp(r'\r?\n'))[1], '1,');
        expect(absentOut.split(RegExp(r'\r?\n'))[2], '3,');
      },
    );

    test('tsv also gets the union-headers treatment', () {
      final v = <Object?>[
        {'a': 1},
        {'b': 2},
      ];
      final out = formatOutput(v, OutputFormat.tsv);
      expect(out.split(RegExp(r'\r?\n')).first, 'a\tb');
    });
  });
}
