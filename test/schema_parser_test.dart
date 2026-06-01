/// Tests for the JSON Schema subset parser.
///
/// The contract:
///   1. All seven scalar and container shapes in the Lambë ADT
///      round-trip through `type` plus the appropriate subkey.
///   2. `required` drives the optionality of properties: listed keys
///      stay required, unlisted keys become [SOptional].
///   3. Rejected JSON Schema keywords produce targeted errors;
///      unknown metadata keywords are ignored.
///   4. Errors include a JSON-path hint pointing at the site.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('parseJsonSchema: scalars', () {
    test('null', () {
      expect(parseJsonSchema('{"type": "null"}'), const SNull());
    });
    test('boolean', () {
      expect(parseJsonSchema('{"type": "boolean"}'), const SBool());
    });
    test('number', () {
      expect(parseJsonSchema('{"type": "number"}'), const SNum());
    });
    test('integer maps to number (Lambë has no int/double distinction)', () {
      expect(parseJsonSchema('{"type": "integer"}'), const SNum());
    });
    test('string', () {
      expect(parseJsonSchema('{"type": "string"}'), const SString());
    });
  });

  group('parseJsonSchema: arrays', () {
    test('array without items defaults to list<any>', () {
      expect(parseJsonSchema('{"type": "array"}'), const SList(SAny()));
    });

    test('array with scalar items', () {
      expect(
        parseJsonSchema('{"type": "array", "items": {"type": "string"}}'),
        const SList(SString()),
      );
    });

    test('array of objects', () {
      const schema =
          '{"type": "array", "items": {"type": "object", '
          '"properties": {"x": {"type": "number"}}, "required": ["x"]}}';
      expect(parseJsonSchema(schema), const SList(SMap({'x': SNum()})));
    });
  });

  group('parseJsonSchema: objects and required', () {
    test('empty object', () {
      expect(
        parseJsonSchema('{"type": "object"}'),
        const SMap(<String, Shape>{}),
      );
    });

    test('all properties required when listed in required', () {
      const schema =
          '{"type": "object", "properties": '
          '{"a": {"type": "number"}, "b": {"type": "string"}}, '
          '"required": ["a", "b"]}';
      expect(
        parseJsonSchema(schema),
        const SMap({'a': SNum(), 'b': SString()}),
      );
    });

    test('absent required means all properties are SOptional', () {
      const schema =
          '{"type": "object", "properties": '
          '{"a": {"type": "number"}, "b": {"type": "string"}}}';
      final shape = parseJsonSchema(schema) as SMap;
      expect(shape.fields['a'], isA<SOptional>());
      expect((shape.fields['a']! as SOptional).inner, const SNum());
      expect(shape.fields['b'], isA<SOptional>());
      expect((shape.fields['b']! as SOptional).inner, const SString());
    });

    test('partial required: unlisted become SOptional', () {
      const schema =
          '{"type": "object", "properties": '
          '{"a": {"type": "number"}, "b": {"type": "string"}}, '
          '"required": ["a"]}';
      final shape = parseJsonSchema(schema) as SMap;
      expect(shape.fields['a'], const SNum());
      expect(shape.fields['b'], isA<SOptional>());
    });

    test('nested object with its own required list', () {
      const schema = '''
        {
          "type": "object",
          "properties": {
            "user": {
              "type": "object",
              "properties": {
                "name": {"type": "string"},
                "age": {"type": "number"}
              },
              "required": ["name"]
            }
          },
          "required": ["user"]
        }
      ''';
      final shape = parseJsonSchema(schema) as SMap;
      final user = shape.fields['user']! as SMap;
      expect(user.fields['name'], const SString());
      expect(user.fields['age'], isA<SOptional>());
    });
  });

  group('parseJsonSchema: rejected keywords', () {
    final rejections = {
      // Value-level constraints
      '"minimum"': '{"type": "number", "minimum": 0}',
      '"maximum"': '{"type": "number", "maximum": 100}',
      '"pattern"': '{"type": "string", "pattern": "^[a-z]+\$"}',
      '"enum"': '{"type": "string", "enum": ["a", "b"]}',
      '"format"': '{"type": "string", "format": "email"}',
      '"minLength"': '{"type": "string", "minLength": 1}',
      // Structural combinators
      '"allOf"': '{"allOf": [{"type": "object"}]}',
      '"oneOf"': '{"oneOf": [{"type": "string"}, {"type": "number"}]}',
      '"anyOf"': '{"anyOf": [{"type": "string"}]}',
      '"not"': '{"not": {"type": "null"}}',
      // Conditionals
      '"if"': '{"type": "object", "if": {"type": "object"}}',
      '"dependencies"': '{"type": "object", "dependencies": {"a": ["b"]}}',
      // References
      '"\$ref"': '{"\$ref": "#/definitions/foo"}',
      '"\$defs"': '{"\$defs": {"foo": {"type": "string"}}}',
      'definitions':
          '{"type": "object", "definitions": {"x": {"type": "string"}}}',
      // Extra object constraints
      '"additionalProperties"':
          '{"type": "object", "additionalProperties": false}',
      '"patternProperties"':
          '{"type": "object", "patternProperties": {".*": {"type": "string"}}}',
    };

    for (final entry in rejections.entries) {
      test('rejects ${entry.key}', () {
        expect(
          () => parseJsonSchema(entry.value),
          throwsA(
            isA<QueryError>().having(
              (e) => e.message,
              'message',
              // The rejection message names the keyword without quotes.
              contains(entry.key.replaceAll('"', '')),
            ),
          ),
        );
      });
    }
  });

  group('parseJsonSchema: ignored metadata', () {
    test('description and title are tolerated', () {
      const schema = '''
        {
          "type": "object",
          "title": "User",
          "description": "A user record",
          "properties": {"name": {"type": "string", "description": "Full name"}},
          "required": ["name"]
        }
      ''';
      expect(parseJsonSchema(schema), const SMap({'name': SString()}));
    });

    test('\$schema and \$id at root are ignored', () {
      const schema = '''
        {
          "\$schema": "http://json-schema.org/draft-07/schema",
          "\$id": "https://example.com/schemas/x",
          "type": "string"
        }
      ''';
      expect(parseJsonSchema(schema), const SString());
    });
  });

  group('parseJsonSchema: error diagnostics', () {
    test('invalid JSON surfaces a JSON parse error', () {
      expect(
        () => parseJsonSchema('{not valid'),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('invalid JSON'),
          ),
        ),
      );
    });

    test('non-object root is rejected', () {
      expect(
        () => parseJsonSchema('42'),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('expected a JSON object'),
          ),
        ),
      );
    });

    test('missing type is rejected with a clear message', () {
      expect(
        () => parseJsonSchema('{"properties": {}}'),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('missing "type"'),
          ),
        ),
      );
    });

    test('unsupported type value is rejected', () {
      expect(
        () => parseJsonSchema('{"type": "color"}'),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('unsupported type "color"'),
          ),
        ),
      );
    });

    test('properties must be an object', () {
      expect(
        () => parseJsonSchema('{"type": "object", "properties": [1, 2]}'),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('"properties" must be'),
          ),
        ),
      );
    });

    test('required must be an array of strings', () {
      expect(
        () => parseJsonSchema(
          '{"type": "object", "properties": {"a": {"type": "number"}}, '
          '"required": "a"}',
        ),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('"required" must be'),
          ),
        ),
      );
    });

    test('nested error includes the JSON path to the offender', () {
      expect(
        () => parseJsonSchema(
          '{"type": "object", "properties": '
          '{"a": {"type": "object", "properties": '
          '{"b": {"type": "nonsense"}}}}, "required": ["a"]}',
        ),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('.properties.a.properties.b'),
              contains('unsupported type "nonsense"'),
            ),
          ),
        ),
      );
    });
  });

  group('parseJsonSchema: full round-trip scenarios', () {
    test('realistic user record', () {
      const schema = '''
        {
          "type": "object",
          "properties": {
            "name": {"type": "string"},
            "age": {"type": "number"},
            "active": {"type": "boolean"},
            "tags": {"type": "array", "items": {"type": "string"}}
          },
          "required": ["name", "age"]
        }
      ''';
      final shape = parseJsonSchema(schema) as SMap;
      expect(shape.fields['name'], const SString());
      expect(shape.fields['age'], const SNum());
      expect(shape.fields['active'], isA<SOptional>());
      expect(shape.fields['tags'], isA<SOptional>());
      expect(
        (shape.fields['tags']! as SOptional).inner,
        const SList(SString()),
      );
    });

    test('list of records (API response shape)', () {
      const schema = '''
        {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": {"type": "string"},
              "count": {"type": "integer"}
            },
            "required": ["id", "count"]
          }
        }
      ''';
      expect(
        parseJsonSchema(schema),
        const SList(SMap({'id': SString(), 'count': SNum()})),
      );
    });
  });
}
