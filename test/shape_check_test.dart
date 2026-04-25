/// Tests for [canWriteAs]: shape-based output format compatibility.
///
/// Covers the full (shape × format) matrix and verifies that every
/// [NotWritable] case carries a non-empty, non-trivial list of
/// [Remediation] suggestions.
library;

import 'package:lambe/src/output.dart' show OutputFormat;
import 'package:lambe/src/shape/check.dart';
import 'package:lambe/src/shape/shape.dart';
import 'package:test/test.dart';

void main() {
  group('canWriteAs: JSON and YAML accept anything', () {
    final universalAccepts = <Object?>[
      null,
      true,
      42,
      'hello',
      <Object?>[1, 2, 3],
      <String, Object?>{'a': 1},
    ];

    for (final fmt in [OutputFormat.json, OutputFormat.yaml]) {
      test('${fmt.name} accepts every shape', () {
        for (final v in universalAccepts) {
          expect(canWriteAs(v, fmt), isA<Writable>(), reason: 'for $v');
        }
      });
    }
  });

  group('canWriteAs: TOML/HCL require map', () {
    for (final fmt in [OutputFormat.toml, OutputFormat.hcl]) {
      test('${fmt.name} accepts a map', () {
        expect(canWriteAs(<String, Object?>{'a': 1}, fmt), isA<Writable>());
      });

      test('${fmt.name} accepts an empty map', () {
        expect(canWriteAs(<String, Object?>{}, fmt), isA<Writable>());
      });

      test('${fmt.name} rejects a list with suggestions', () {
        final report = canWriteAs(<Object?>[1, 2, 3], fmt);
        expect(report, isA<NotWritable>());
        final nw = report as NotWritable;
        expect(nw.format, fmt);
        expect(nw.got, isA<SList>());
        expect(nw.required, isA<MustBeMap>());
        expect(nw.suggestions, isNotEmpty);
      });

      test('${fmt.name} rejects a string with suggestions', () {
        final report = canWriteAs('hi', fmt);
        expect(report, isA<NotWritable>());
        final nw = report as NotWritable;
        expect(nw.got, isA<SString>());
        expect(nw.suggestions, isNotEmpty);
        expect(nw.suggestions.first.display, contains('{'));
      });

      test('${fmt.name} rejects a number with suggestions', () {
        final report = canWriteAs(42, fmt);
        expect(report, isA<NotWritable>());
        expect((report as NotWritable).suggestions, isNotEmpty);
      });

      test('${fmt.name} rejects null with at least one suggestion', () {
        final report = canWriteAs(null, fmt);
        expect(report, isA<NotWritable>());
        expect((report as NotWritable).suggestions, isNotEmpty);
      });
    }
  });

  group('canWriteAs: CSV/TSV require list', () {
    for (final fmt in [OutputFormat.csv, OutputFormat.tsv]) {
      test('${fmt.name} accepts a list of maps', () {
        expect(
          canWriteAs([
            <String, Object?>{'a': 1},
            <String, Object?>{'a': 2},
          ], fmt),
          isA<Writable>(),
        );
      });

      test('${fmt.name} accepts an empty list', () {
        expect(canWriteAs(<Object?>[], fmt), isA<Writable>());
      });

      test('${fmt.name} accepts a list of scalars', () {
        expect(canWriteAs(<Object?>[1, 2, 3], fmt), isA<Writable>());
      });

      test('${fmt.name} rejects a map with suggestions', () {
        final report = canWriteAs(<String, Object?>{'a': 1}, fmt);
        expect(report, isA<NotWritable>());
        final nw = report as NotWritable;
        expect(nw.got, isA<SMap>());
        expect(nw.required, isA<MustBeList>());
        expect(nw.suggestions, isNotEmpty);
        // First suggestion should be to_entries for map → list of rows.
        expect(nw.suggestions.first.display, contains('to_entries'));
      });

      test('${fmt.name} rejects a scalar with suggestions', () {
        final report = canWriteAs(42, fmt);
        expect(report, isA<NotWritable>());
        expect((report as NotWritable).suggestions, isNotEmpty);
      });
    }
  });

  group('canWriteShapeAs: shape-only path', () {
    test('works directly on Shape values', () {
      expect(
        canWriteShapeAs(const SMap({'a': SNum()}), OutputFormat.toml),
        isA<Writable>(),
      );
      expect(
        canWriteShapeAs(const SList(SNum()), OutputFormat.toml),
        isA<NotWritable>(),
      );
    });

    test('SAny is accepted by every requirement', () {
      // SAny represents an unknown shape. A shape-inference pass may
      // not be able to resolve every branch, and refusing to serialize
      // unknown shapes would block valid data.
      for (final fmt in OutputFormat.values) {
        expect(canWriteShapeAs(const SAny(), fmt), isA<Writable>());
      }
    });
  });

  group('Remediation ASTs parse cleanly', () {
    // The Remediation factory calls parseQuery on its source string at
    // construction time. If any curated entry is malformed, constructing
    // it throws ArgumentError. The test exercises every (shape, format)
    // combination for which a suggestion is defined, so a bad template
    // cannot slip past CI.
    test('every curated remediation is valid Lambe syntax', () {
      final combos = <(Object?, OutputFormat)>[
        (<Object?>[1], OutputFormat.toml),
        (<Object?>[1], OutputFormat.hcl),
        ('x', OutputFormat.toml),
        ('x', OutputFormat.hcl),
        (42, OutputFormat.toml),
        (true, OutputFormat.hcl),
        (null, OutputFormat.toml),
        (<String, Object?>{'a': 1}, OutputFormat.csv),
        (<String, Object?>{'a': 1}, OutputFormat.tsv),
        ('x', OutputFormat.csv),
        (0, OutputFormat.tsv),
        (null, OutputFormat.csv),
      ];
      for (final (value, fmt) in combos) {
        // Instantiation walks the factory for each suggestion. No throw
        // means every entry parsed successfully.
        expect(
          () => canWriteAs(value, fmt),
          returnsNormally,
          reason: '$value → ${fmt.name} should not throw',
        );
      }
    });
  });

  group('Remediation quality', () {
    test('every NotWritable has at least one suggestion', () {
      final badCombos = <(Object?, OutputFormat)>[
        (<Object?>[], OutputFormat.toml),
        (<Object?>[1], OutputFormat.hcl),
        ('x', OutputFormat.toml),
        (42, OutputFormat.hcl),
        (true, OutputFormat.toml),
        (null, OutputFormat.toml),
        (<String, Object?>{'a': 1}, OutputFormat.csv),
        (<String, Object?>{'a': 1}, OutputFormat.tsv),
        ('x', OutputFormat.csv),
        (0, OutputFormat.tsv),
      ];
      for (final (value, fmt) in badCombos) {
        final report = canWriteAs(value, fmt);
        expect(
          report,
          isA<NotWritable>(),
          reason: '$value → ${fmt.name} should not be writable',
        );
        final nw = report as NotWritable;
        expect(
          nw.suggestions,
          isNotEmpty,
          reason: '$value → ${fmt.name} needs at least one suggestion',
        );
        for (final r in nw.suggestions) {
          expect(r.label, isNotEmpty);
          expect(r.display, isNotEmpty);
          expect(r.template, isNotNull);
          expect(r.explanation, isNotEmpty);
        }
      }
    });
  });
}
