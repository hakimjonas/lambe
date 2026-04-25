/// Tests for the `as(format)` combinator, a shape-directed bridge
/// available as a first-class pipeline operator.
///
/// Properties under test:
///   1. `as(fmt)` parses for every known format and rejects unknown
///      format names.
///   2. When the current shape already satisfies `fmt`, `as(fmt)` is a
///      no-op (identity in, identity out).
///   3. When exactly one curated bridge is defined, `as(fmt)` applies
///      it, and the resulting value satisfies `canWriteAs(..., fmt)`.
///   4. `inferShape` over `as(fmt)` agrees with the shape of the
///      evaluated result.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('as: parsing', () {
    test('accepts each known output format', () {
      for (final fmt in OutputFormat.values) {
        expect(
          () => query('as(${fmt.name})', <String, Object?>{'x': 1}),
          returnsNormally,
          reason: 'as(${fmt.name}) should parse',
        );
      }
    });

    test('rejects unknown format tokens with a clear error', () {
      expect(
        () => query('as(parquet)', <String, Object?>{'x': 1}),
        throwsA(isA<QueryError>()),
      );
    });

    test('usable as a bare expression and in a pipeline', () {
      expect(() => query('as(json)', null), returnsNormally);
      expect(() => query('. | as(json)', null), returnsNormally);
    });
  });

  group('as: no-op when already writable', () {
    test('map → as(toml) returns the map unchanged', () {
      final data = <String, Object?>{'host': 'x', 'port': 8080};
      expect(query('as(toml)', data), data);
    });

    test('list → as(csv) returns the list unchanged', () {
      final data = <Object?>[
        <String, Object?>{'a': 1},
        <String, Object?>{'a': 2},
      ];
      expect(query('as(csv)', data), data);
    });

    test('anything → as(json) is identity', () {
      expect(query('as(json)', 42), 42);
      expect(query('as(json)', 'x'), 'x');
      expect(query('as(json)', <Object?>[1, 2]), <Object?>[1, 2]);
    });
  });

  group('as: applies curated bridge when one exists', () {
    test('list → as(toml) wraps under {items: .}', () {
      final result = query('as(toml)', <Object?>[1, 2, 3]);
      expect(result, <String, Object?>{
        'items': <Object?>[1, 2, 3],
      });
    });

    test('scalar → as(toml) wraps under {value: .}', () {
      expect(query('as(toml)', 'hello'), <String, Object?>{'value': 'hello'});
      expect(query('as(hcl)', 42), <String, Object?>{'value': 42});
    });

    test('map → as(csv) converts entries to rows', () {
      final result = query('as(csv)', <String, Object?>{'a': 1, 'b': 2});
      expect(result, <Object?>[
        <String, Object?>{'key': 'a', 'value': 1},
        <String, Object?>{'key': 'b', 'value': 2},
      ]);
    });

    test('scalar → as(csv) produces a one-row list via to_entries', () {
      final result = query('as(csv)', 'hi');
      expect(result, isA<List<Object?>>());
      expect((result as List).first, <String, Object?>{
        'key': 'value',
        'value': 'hi',
      });
    });
  });

  group('as: composes in a pipeline', () {
    test('.users | as(toml) bridges the users subvalue', () {
      final data = <String, Object?>{
        'users': <Object?>['alice', 'bob'],
      };
      expect(query('.users | as(toml)', data), <String, Object?>{
        'items': <Object?>['alice', 'bob'],
      });
    });

    test('as output is writable in the target format', () {
      // End-to-end: the bridge actually produces something formatOutput
      // accepts without throwing.
      final data = <Object?>[1, 2, 3];
      final bridged = query('as(toml)', data);
      expect(() => formatOutput(bridged, OutputFormat.toml), returnsNormally);
    });
  });

  group('as: field named `as` is still accessible', () {
    test('.as continues to mean field access', () {
      // The combinator only triggers when followed by `(`, so user data
      // with a field literally named "as" is still addressable.
      final data = <String, Object?>{'as': 'user-level-field'};
      expect(query('.as', data), 'user-level-field');
    });
  });

  group('as: inferShape agrees with evaluation', () {
    test('list → as(toml) infers the wrapped-map shape', () {
      const from = SList(SNum());
      final inferred = inferShape(_parseOrThrow('as(toml)'), from);
      expect(inferred, const SMap({'items': SList(SNum())}));
    });

    test('scalar → as(hcl) infers the wrapped-value shape', () {
      const from = SString();
      final inferred = inferShape(_parseOrThrow('as(hcl)'), from);
      expect(inferred, const SMap({'value': SString()}));
    });

    test('already-writable map → as(toml) preserves shape', () {
      const from = SMap({'a': SNum()});
      final inferred = inferShape(_parseOrThrow('as(toml)'), from);
      expect(inferred, from);
    });
  });
}

LamExpr _parseOrThrow(String source) {
  try {
    return _exprFromSource(source);
  } catch (e) {
    fail('failed to parse "$source": $e');
  }
}

// Minimal AST extractor. Used by the inferShape tests to construct an
// [As] node directly rather than through the parser, since the test
// cases cover a small closed set.
LamExpr _exprFromSource(String source) => switch (source) {
  'as(toml)' => const As(OutputFormat.toml),
  'as(hcl)' => const As(OutputFormat.hcl),
  'as(csv)' => const As(OutputFormat.csv),
  _ => throw ArgumentError('add "$source" to _exprFromSource'),
};
