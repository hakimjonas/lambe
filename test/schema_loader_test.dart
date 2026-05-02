/// Tests for the schema loader: file IO, sibling auto-detect, and
/// [mergeSchemaWithData] semantics.
///
/// Merge rules under test:
///   1. Agreement: both sides concrete and equal → that type.
///   2. SAny on either side: the other side wins.
///   3. Schema-only fields: preserved.
///   4. Data-only fields: preserved.
///   5. Schema optional + data present: strip optional.
///   6. Schema optional + data null: keep optional (Lambe-style
///      null propagation: null means absent-ish).
///   7. Disagreement on concrete types: QueryError with a path.
///   8. Recursion through lists and maps.
library;

import 'dart:io';

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('loadSchemaFromFile', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('lambe_schema_loader_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('reads a valid schema file', () {
      final path = '${tmp.path}/s.json';
      File(path).writeAsStringSync('{"type": "string"}');
      expect(loadSchemaFromFile(path), const SString());
    });

    test('throws on missing file with a clear message', () {
      expect(
        () => loadSchemaFromFile('${tmp.path}/nope.json'),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('schema file not found'),
          ),
        ),
      );
    });

    test('propagates parser errors on malformed content', () {
      final path = '${tmp.path}/bad.json';
      File(path).writeAsStringSync('{"type": "nonsense"}');
      expect(
        () => loadSchemaFromFile(path),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains('unsupported type "nonsense"'),
          ),
        ),
      );
    });
  });

  group('loadSchemaForData: sibling auto-detect', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('lambe_schema_sibling_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('returns null when no explicit path and no sibling exists', () {
      final dataPath = '${tmp.path}/data.json';
      File(dataPath).writeAsStringSync('{}');
      expect(loadSchemaForData(dataPath: dataPath), isNull);
    });

    test('finds sibling <data>.schema.json next to data file', () {
      final dataPath = '${tmp.path}/users.json';
      File(dataPath).writeAsStringSync('[]');
      File(
        '${tmp.path}/users.schema.json',
      ).writeAsStringSync('{"type": "array"}');
      expect(loadSchemaForData(dataPath: dataPath), const SList(SAny()));
    });

    test('sibling works for .ndjson extension too', () {
      final dataPath = '${tmp.path}/events.ndjson';
      File(dataPath).writeAsStringSync('{}\n');
      File(
        '${tmp.path}/events.schema.json',
      ).writeAsStringSync('{"type": "object"}');
      expect(
        loadSchemaForData(dataPath: dataPath),
        const SMap(<String, Shape>{}),
      );
    });

    test('explicit path beats sibling', () {
      final dataPath = '${tmp.path}/data.json';
      File(dataPath).writeAsStringSync('{}');
      // Sibling says number.
      File(
        '${tmp.path}/data.schema.json',
      ).writeAsStringSync('{"type": "number"}');
      // Explicit says string.
      final explicit = '${tmp.path}/explicit.json';
      File(explicit).writeAsStringSync('{"type": "string"}');
      expect(
        loadSchemaForData(explicitSchemaPath: explicit, dataPath: dataPath),
        const SString(),
      );
    });

    test('explicit path without data path still works', () {
      final explicit = '${tmp.path}/only.json';
      File(explicit).writeAsStringSync('{"type": "boolean"}');
      expect(loadSchemaForData(explicitSchemaPath: explicit), const SBool());
    });
  });

  group('mergeSchemaWithData: agreement and SAny', () {
    test('equal concrete scalars pass through', () {
      expect(mergeSchemaWithData(const SNum(), const SNum()), const SNum());
    });

    test('SAny on either side yields the other', () {
      expect(mergeSchemaWithData(const SAny(), const SNum()), const SNum());
      expect(
        mergeSchemaWithData(const SString(), const SAny()),
        const SString(),
      );
    });

    test('both SAny collapses to SAny', () {
      expect(mergeSchemaWithData(const SAny(), const SAny()), const SAny());
    });
  });

  group('mergeSchemaWithData: disagreement errors', () {
    test('scalar vs scalar disagreement raises with path', () {
      expect(
        () => mergeSchemaWithData(const SNum(), const SString()),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('disagreement'),
              contains(r'$'),
              contains('number'),
              contains('string'),
            ),
          ),
        ),
      );
    });

    test('schema map + data non-map raises', () {
      expect(
        () => mergeSchemaWithData(const SMap({'a': SNum()}), const SNum()),
        throwsA(isA<QueryError>()),
      );
    });

    test('schema list + data non-list raises', () {
      expect(
        () => mergeSchemaWithData(const SList(SNum()), const SString()),
        throwsA(isA<QueryError>()),
      );
    });

    test('nested disagreement carries the nested path', () {
      expect(
        () => mergeSchemaWithData(
          const SMap({
            'user': SMap({'age': SNum()}),
          }),
          const SMap({
            'user': SMap({'age': SString()}),
          }),
        ),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains(r'$.user.age'),
          ),
        ),
      );
    });

    test('list element disagreement carries [*] path', () {
      expect(
        () => mergeSchemaWithData(const SList(SNum()), const SList(SString())),
        throwsA(
          isA<QueryError>().having(
            (e) => e.message,
            'message',
            contains(r'$[*]'),
          ),
        ),
      );
    });
  });

  group('mergeSchemaWithData: SOptional handling', () {
    test('schema optional + data present strips optional', () {
      // Schema says field is optional; data has it present.
      // Merged should be the concrete inner shape.
      final merged = mergeSchemaWithData(
        SMap({'age': SOptional(const SNum())}),
        const SMap({'age': SNum()}),
      );
      expect(merged, const SMap({'age': SNum()}));
    });

    test('schema optional + data absent keeps optional', () {
      // Data has no `age` field. Schema wins.
      final schema = SMap({'age': SOptional(const SNum())});
      const data = SMap(<String, Shape>{});
      expect(mergeSchemaWithData(schema, data), schema);
    });

    test('schema optional + data null keeps optional '
        '(Lambe null-propagation stance)', () {
      final schema = SMap({'age': SOptional(const SNum())});
      const data = SMap({'age': SNull()});
      final merged = mergeSchemaWithData(schema, data) as SMap;
      expect(merged.fields['age'], isA<SOptional>());
    });

    test('optional inner still checks for disagreement', () {
      // Schema says optional<number>, data has string. String is not
      // number-or-absent, so error.
      expect(
        () => mergeSchemaWithData(
          SMap({'age': SOptional(const SNum())}),
          const SMap({'age': SString()}),
        ),
        throwsA(isA<QueryError>()),
      );
    });
  });

  group('mergeSchemaWithData: augmentation', () {
    test('schema-only field is preserved', () {
      final schema = SMap({
        'name': const SString(),
        'age': SOptional(const SNum()),
      });
      const data = SMap({'name': SString()});
      final merged = mergeSchemaWithData(schema, data) as SMap;
      expect(merged.fields['name'], const SString());
      expect(merged.fields['age'], isA<SOptional>());
    });

    test('data-only field is preserved', () {
      const schema = SMap({'name': SString()});
      const data = SMap({'name': SString(), 'extra': SBool()});
      final merged = mergeSchemaWithData(schema, data) as SMap;
      expect(merged.fields['name'], const SString());
      expect(merged.fields['extra'], const SBool());
    });

    test('empty data list + schema with typed items uses schema element', () {
      // shapeOf([]) == SList(SAny()). Schema says list<string>.
      // Merge should yield list<string>.
      const schema = SList(SString());
      const data = SList(SAny());
      expect(mergeSchemaWithData(schema, data), const SList(SString()));
    });

    test('non-empty data list passes through schema element merge', () {
      // Both sides know the element; they agree.
      const schema = SList(SNum());
      const data = SList(SNum());
      expect(mergeSchemaWithData(schema, data), const SList(SNum()));
    });

    test('recursive merge across nested lists and maps', () {
      final schema = SMap({
        'users': SList(
          SMap({
            'name': const SString(),
            'tags': SOptional(const SList(SString())),
          }),
        ),
      });
      const data = SMap({
        'users': SList(SMap({'name': SString(), 'active': SBool()})),
      });
      final merged = mergeSchemaWithData(schema, data) as SMap;
      final users = (merged.fields['users']! as SList).element as SMap;
      expect(users.fields['name'], const SString());
      expect(users.fields['active'], const SBool());
      // Schema-declared optional field missing from data stays
      // optional.
      expect(users.fields['tags'], isA<SOptional>());
    });
  });
}
