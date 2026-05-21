/// Pins TSV header detection to match CSV semantics.
///
/// 0.8.0 always returned `List<List<String>>` for TSV regardless of
/// whether the first row looked like headers — a silent inconsistency
/// vs the documented CSV model. 0.9.0 runs `detectDialect` for TSV with
/// the tab delimiter forced, so a header row produces
/// `List<Map<String, Object?>>` like CSV does.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('TSV header detection mirrors CSV', () {
    test('header row produces List<Map>', () {
      const tsv =
          'name\tage\tcity\n'
          'alice\t30\tboston\n'
          'bob\t25\tseattle\n';
      final result = parseInput(tsv, Format.tsv);
      expect(result, isA<List<Object?>>());
      final rows = result as List<Object?>;
      expect(rows, hasLength(2));
      expect(rows[0], isA<Map<String, Object?>>());
      expect(rows[0], {'name': 'alice', 'age': '30', 'city': 'boston'});
      expect(rows[1], {'name': 'bob', 'age': '25', 'city': 'seattle'});
    });

    test('all-numeric data (no header) returns List<List>', () {
      const tsv =
          '1\t2\t3\n'
          '4\t5\t6\n'
          '7\t8\t9\n';
      final result = parseInput(tsv, Format.tsv);
      expect(result, isA<List<Object?>>());
      final rows = result as List<Object?>;
      expect(rows, hasLength(3));
      expect(rows[0], isA<List<Object?>>());
      expect(rows[0], ['1', '2', '3']);
    });

    test('mixed numeric/string in row 1 does NOT false-detect a header', () {
      // detectDialect's heuristic: header iff row1 is all non-numeric AND
      // row2 has at least one numeric. A row1 with a number is not a
      // header.
      const tsv =
          'alice\t30\tboston\n'
          'bob\t25\tseattle\n';
      final result = parseInput(tsv, Format.tsv);
      expect(result, isA<List<Object?>>());
      final rows = result as List<Object?>;
      expect(rows[0], isA<List<Object?>>());
    });

    test('quoted fields parse correctly under header detection', () {
      // Header detection requires row2 to have at least one numeric
      // field. With age=30 the heuristic fires and quoted fields in
      // headers + data must round-trip through parseDelimitedWithHeaders.
      const tsv =
          'name\tage\n'
          '"alice, smith"\t30\n';
      final result = parseInput(tsv, Format.tsv);
      expect(result, isA<List<Object?>>());
      final rows = result as List<Object?>;
      expect(rows, hasLength(1));
      expect(rows[0], isA<Map<String, Object?>>());
      final row0 = rows[0] as Map<String, Object?>;
      expect(row0['name'], 'alice, smith');
      expect(row0['age'], '30');
    });

    test('CSV with same logical content also returns List<Map>', () {
      // Sanity: the docstring promise is "TSV honors headers the same
      // way CSV does". Pin both side by side.
      const csv =
          'name,age,city\n'
          'alice,30,boston\n';
      final csvResult = parseInput(csv, Format.csv);
      expect(csvResult, isA<List<Object?>>());
      expect((csvResult as List<Object?>)[0], isA<Map<String, Object?>>());
    });
  });
}
