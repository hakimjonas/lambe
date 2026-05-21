/// Pins string single-char indexing semantics.
///
/// Pre-0.9.0 string slicing (`.name[0:3]`) worked but single-char
/// indexing (`.name[0]`) threw `Cannot index string`. The asymmetry was
/// gratuitous; 0.9.0 mirrors slice semantics — out-of-range returns
/// null (same as list indexing), non-int still throws.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('string single-char indexing', () {
    test('first char', () {
      expect(query('.name[0]', {'name': 'alice'}), 'a');
    });

    test('middle char', () {
      expect(query('.name[2]', {'name': 'alice'}), 'i');
    });

    test('last char via -1', () {
      expect(query('.name[-1]', {'name': 'alice'}), 'e');
    });

    test('negative offset within range', () {
      expect(query('.name[-3]', {'name': 'alice'}), 'i');
    });

    test('out of range returns null', () {
      expect(query('.name[10]', {'name': 'alice'}), null);
    });

    test('negative out of range returns null', () {
      expect(query('.name[-99]', {'name': 'alice'}), null);
    });

    test('empty string is always out of range', () {
      expect(query('.name[0]', {'name': ''}), null);
    });

    test('non-int index still throws', () {
      expect(
        () => query('.name["a"]', {'name': 'alice'}),
        throwsA(isA<QueryError>()),
      );
    });

    test('slice still works (regression check)', () {
      expect(query('.name[0:3]', {'name': 'alice'}), 'ali');
    });

    test('slice and index compose', () {
      expect(query('.name[0:3] | .[1]', {'name': 'alice'}), 'l');
    });
  });
}
