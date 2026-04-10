import 'package:lambe/lambe.dart';
import 'package:rumil/rumil.dart';
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
  group('String interpolation', () {
    test('plain string (no interpolation)', () {
      expect(query('"hello"', null), 'hello');
    });

    test('empty string', () {
      expect(query('""', null), '');
    });

    test('simple interpolation', () {
      expect(query(r'"\(.name)"', {'name': 'Alice'}), 'Alice');
    });

    test('interpolation with surrounding text', () {
      expect(
        query(r'"\(.name) is \(.age) years old"', {'name': 'Alice', 'age': 25}),
        'Alice is 25 years old',
      );
    });

    test('interpolation with expression', () {
      expect(
        query(r'"total: \(.price * .qty)"', {'price': 10, 'qty': 3}),
        'total: 30',
      );
    });

    test('escaped backslash', () {
      expect(query(r'"hello\\world"', null), r'hello\world');
    });

    test('escaped quote', () {
      expect(query(r'"say \"hi\""', null), 'say "hi"');
    });

    test('newline escape', () {
      expect(query(r'"line1\nline2"', null), 'line1\nline2');
    });

    test('tab escape', () {
      expect(query(r'"a\tb"', null), 'a\tb');
    });

    test('null interpolation shows null', () {
      expect(query(r'"\(.missing)"', <String, Object?>{}), 'null');
    });

    test('in map pipeline', () {
      final data = [
        {'name': 'Alice', 'age': 25},
        {'name': 'Bob', 'age': 35},
      ];
      expect(query(r'. | map("\(.name): \(.age)")', data), [
        'Alice: 25',
        'Bob: 35',
      ]);
    });

    test('parse: plain string is StrLit', () {
      final expr = _parse('"hello"');
      expect(expr, isA<StrLit>());
    });

    test('parse: interpolation is StringInterp', () {
      final expr = _parse(r'"\(.name) ok"');
      expect(expr, isA<StringInterp>());
    });

    test('parse: only escapes collapses to StrLit', () {
      final expr = _parse(r'"hello\\world"');
      expect(expr, isA<StrLit>());
      expect((expr as StrLit).value, r'hello\world');
    });
  });

  group('Slicing', () {
    test('[1:3]', () {
      expect(query('.[1:3]', [10, 20, 30, 40, 50]), [20, 30]);
    });

    test('[:2]', () {
      expect(query('.[:2]', [10, 20, 30, 40]), [10, 20]);
    });

    test('[2:]', () {
      expect(query('.[2:]', [10, 20, 30, 40]), [30, 40]);
    });

    test('negative start [-2:]', () {
      expect(query('.[-2:]', [10, 20, 30, 40]), [30, 40]);
    });

    test('negative end [:-1]', () {
      expect(query('.[:-1]', [10, 20, 30, 40]), [10, 20, 30]);
    });

    test('full slice [:]', () {
      expect(query('.[:]', [1, 2, 3]), [1, 2, 3]);
    });

    test('out of bounds clamps', () {
      expect(query('.[0:100]', [1, 2, 3]), [1, 2, 3]);
    });

    test('empty result', () {
      expect(query('.[5:10]', [1, 2, 3]), <Object?>[]);
    });

    test('string slicing', () {
      expect(query('.[1:4]', 'hello'), 'ell');
    });

    test('string slice [:3]', () {
      expect(query('.[:3]', 'hello'), 'hel');
    });

    test('null target propagates', () {
      expect(query('.missing[1:3]', <String, Object?>{}), null);
    });

    test('chained with access', () {
      final data = {
        'items': [10, 20, 30, 40, 50],
      };
      expect(query('.items[1:4]', data), [20, 30, 40]);
    });

    test('parse: produces Slice node', () {
      final expr = _parse('.[1:3]');
      expect(expr, isA<Slice>());
      final slice = expr as Slice;
      expect(slice.start, isA<NumLit>());
      expect(slice.end, isA<NumLit>());
    });

    test('parse: [1] still produces Index (not Slice)', () {
      final expr = _parse('.[1]');
      expect(expr, isA<Index>());
    });
  });

  group('has()', () {
    test('has existing field', () {
      expect(query('. | has("name")', {'name': 'Alice', 'age': 25}), true);
    });

    test('has missing field', () {
      expect(query('. | has("email")', {'name': 'Alice'}), false);
    });

    test('has with null value (key exists)', () {
      expect(query('. | has("x")', {'x': null}), true);
    });

    test('has on list (valid index)', () {
      expect(query('. | has(0)', [10, 20, 30]), true);
    });

    test('has on list (out of bounds)', () {
      expect(query('. | has(5)', [10, 20]), false);
    });

    test('in filter: keep objects with field', () {
      final data = [
        {'name': 'Alice', 'email': 'a@x.com'},
        {'name': 'Bob'},
        {'name': 'Carol', 'email': 'c@x.com'},
      ];
      final result = query('. | filter(. | has("email")) | map(.name)', data);
      expect(result, ['Alice', 'Carol']);
    });

    test('parse structure', () {
      final expr = _parse('. | has("name")');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<HasOp>());
    });
  });

  group('to_entries / from_entries', () {
    test('to_entries', () {
      final result = query('. | to_entries', {'a': 1, 'b': 2});
      expect(result, [
        {'key': 'a', 'value': 1},
        {'key': 'b', 'value': 2},
      ]);
    });

    test('from_entries', () {
      final result = query('. | from_entries', [
        {'key': 'a', 'value': 1},
        {'key': 'b', 'value': 2},
      ]);
      expect(result, {'a': 1, 'b': 2});
    });

    test('round-trip: to_entries | from_entries', () {
      final data = {'x': 10, 'y': 20, 'z': 30};
      expect(query('. | to_entries | from_entries', data), data);
    });

    test('filter map entries via to_entries', () {
      final data = {'a': 1, 'b': 5, 'c': 3, 'd': 8};
      final result = query(
        '. | to_entries | filter(.value > 3) | from_entries',
        data,
      );
      expect(result, {'b': 5, 'd': 8});
    });

    test('to_entries on empty map', () {
      expect(query('. | to_entries', <String, Object?>{}), <Object?>[]);
    });

    test('from_entries on empty list', () {
      expect(query('. | from_entries', <Object?>[]), <String, Object?>{});
    });

    test('null propagates', () {
      expect(query('.missing | to_entries', <String, Object?>{}), null);
    });

    test('parse structure', () {
      final expr = _parse('. | to_entries');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<ToEntriesOp>());
    });
  });

  group('Ring 5 integration', () {
    test('interpolation + pipeline', () {
      final data = {
        'users': [
          {'name': 'Alice', 'role': 'admin'},
          {'name': 'Bob', 'role': 'user'},
        ],
      };
      expect(query(r'.users | map("\(.name) (\(.role))")', data), [
        'Alice (admin)',
        'Bob (user)',
      ]);
    });

    test('slice + sort', () {
      expect(query('(. | sort)[:3]', [5, 3, 1, 4, 2]), [1, 2, 3]);
    });

    test('has + filter + to_entries', () {
      final data = {
        'config': {'debug': true, 'verbose': false, 'secret': 'hidden'},
      };
      expect(
        query(
          '.config | to_entries | filter(.key != "secret") | from_entries',
          data,
        ),
        {'debug': true, 'verbose': false},
      );
    });
  });
}
