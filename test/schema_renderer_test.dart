/// Tests for [renderJsonSchema] and its round-trip with
/// [parseJsonSchema].
///
/// Invariants pinned here:
///   1. Every shape the parser can produce renders to valid JSON
///      Schema the parser re-accepts. Round-trip: parse(render(s)) == s
///      for every shape reachable through [parseJsonSchema].
///   2. Optional fields inside an [SMap] render as missing entries in
///      `required`, not as a modification to the property's shape.
///   3. [SAny] renders as the empty object `{}`, which parses back to
///      [SAny] via the "empty object means any" convention.
///   4. Pretty vs compact output both parse to the same shape.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('renderJsonSchema: scalars', () {
    test('SNull renders as {type: null}', () {
      expect(renderJsonSchema(const SNull()), contains('"type": "null"'));
    });
    test('SBool renders as {type: boolean}', () {
      expect(renderJsonSchema(const SBool()), contains('"type": "boolean"'));
    });
    test('SNum renders as {type: number}', () {
      expect(renderJsonSchema(const SNum()), contains('"type": "number"'));
    });
    test('SString renders as {type: string}', () {
      expect(renderJsonSchema(const SString()), contains('"type": "string"'));
    });
    test('SAny renders as empty object', () {
      expect(renderJsonSchema(const SAny()).trim(), '{}');
    });
  });

  group('renderJsonSchema: containers', () {
    test('SList with typed items', () {
      final out = renderJsonSchema(const SList(SString()));
      expect(out, contains('"type": "array"'));
      expect(out, contains('"items"'));
      expect(out, contains('"type": "string"'));
    });

    test('SList<SAny> renders items as empty object', () {
      final out = renderJsonSchema(const SList(SAny()));
      expect(out, contains('"type": "array"'));
      // The items field is present but its value is {}.
      expect(out, contains('"items":'));
    });

    test('SMap with all required fields lists all in required', () {
      final out = renderJsonSchema(const SMap({'a': SNum(), 'b': SString()}));
      expect(out, contains('"type": "object"'));
      expect(out, contains('"properties"'));
      expect(out, contains('"required"'));
      expect(out, contains('"a"'));
      expect(out, contains('"b"'));
    });

    test('SMap with only optional fields omits required', () {
      final shape = SMap({
        'a': SOptional(const SNum()),
        'b': SOptional(const SString()),
      });
      final out = renderJsonSchema(shape);
      expect(out, contains('"properties"'));
      expect(out, isNot(contains('"required"')));
    });

    test('SMap with mix: only required fields appear in required list', () {
      final shape = SMap({
        'name': const SString(),
        'age': SOptional(const SNum()),
      });
      // Round-trip-verify (shape-level) rather than string-match the
      // list contents.
      final reparsed = parseJsonSchema(renderJsonSchema(shape)) as SMap;
      expect(reparsed.fields['name'], const SString());
      expect(reparsed.fields['age'], isA<SOptional>());
    });

    test('empty SMap omits both properties and required', () {
      final out = renderJsonSchema(const SMap(<String, Shape>{}));
      expect(out, contains('"type": "object"'));
      expect(out, isNot(contains('"properties"')));
      expect(out, isNot(contains('"required"')));
    });
  });

  group('renderJsonSchema: SOptional handling', () {
    test('SOptional at top level flattens to the inner shape', () {
      // There is no JSON Schema idiom in our subset for a top-level
      // optional; renderer flattens to the inner shape.
      final out = renderJsonSchema(SOptional(const SNum()));
      expect(out, contains('"type": "number"'));
    });

    test('SOptional inside SList flattens on the inner element', () {
      // Same reasoning: a list whose element is "optional T" has no
      // standard JSON Schema spelling in our subset, so we render as
      // list<T>. This is a lossy edge case called out in design doc.
      final out = renderJsonSchema(SList(SOptional(const SString())));
      expect(out, contains('"type": "array"'));
      expect(out, contains('"type": "string"'));
    });

    test('SOptional inside SMap becomes non-required property', () {
      // This is the principal case. Round-trip with parser to verify.
      final shape = SMap({'x': SOptional(const SNum())});
      final reparsed = parseJsonSchema(renderJsonSchema(shape)) as SMap;
      expect(reparsed.fields['x'], isA<SOptional>());
    });
  });

  group('renderJsonSchema: compact vs pretty', () {
    test('pretty output has whitespace/newlines', () {
      final pretty = renderJsonSchema(const SString());
      expect(pretty, contains('\n'));
    });

    test('compact output has no newlines', () {
      final compact = renderJsonSchema(const SString(), pretty: false);
      expect(compact, isNot(contains('\n')));
    });

    test('pretty and compact parse back to the same shape', () {
      const shape = SList(SMap({'name': SString()}));
      final pretty = renderJsonSchema(shape);
      final compact = renderJsonSchema(shape, pretty: false);
      expect(parseJsonSchema(pretty), parseJsonSchema(compact));
    });
  });

  group('renderJsonSchema: round-trip with parser', () {
    // parse(render(s)) == s for every shape the parser can emit.
    final roundTripCases = <String, Shape>{
      'null': const SNull(),
      'bool': const SBool(),
      'number': const SNum(),
      'string': const SString(),
      'any (empty-object)': const SAny(),
      'list of numbers': const SList(SNum()),
      'list of strings': const SList(SString()),
      'list of any': const SList(SAny()),
      'empty map': const SMap(<String, Shape>{}),
      'map of scalars all required': const SMap({'a': SNum(), 'b': SString()}),
      'list of maps': const SList(SMap({'id': SString(), 'n': SNum()})),
      'nested maps': const SMap({
        'user': SMap({'name': SString(), 'age': SNum()}),
      }),
    };

    for (final entry in roundTripCases.entries) {
      test('round-trip: ${entry.key}', () {
        final rendered = renderJsonSchema(entry.value);
        final reparsed = parseJsonSchema(rendered);
        expect(reparsed, entry.value);
      });
    }

    test('round-trip: map with one required and one optional field', () {
      final shape = SMap({
        'name': const SString(),
        'age': SOptional(const SNum()),
      });
      final rendered = renderJsonSchema(shape);
      final reparsed = parseJsonSchema(rendered);
      expect(reparsed, shape);
    });

    test('round-trip: list of maps with optional field in element', () {
      final shape = SList(
        SMap({
          'id': const SString(),
          'tags': SOptional(const SList(SString())),
        }),
      );
      final rendered = renderJsonSchema(shape);
      final reparsed = parseJsonSchema(rendered);
      expect(reparsed, shape);
    });

    test('deeply nested round-trip', () {
      final shape = SMap({
        'a': SMap({
          'b': SMap({
            'c': SList(SMap({'d': SOptional(const SNum())})),
          }),
        }),
      });
      final rendered = renderJsonSchema(shape);
      final reparsed = parseJsonSchema(rendered);
      expect(reparsed, shape);
    });
  });
}
