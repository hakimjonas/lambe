import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('Format detection by extension', () {
    test('.json', () => expect(detectFormat('data.json'), Format.json));
    test('.yaml', () => expect(detectFormat('config.yaml'), Format.yaml));
    test('.yml', () => expect(detectFormat('config.yml'), Format.yaml));
    test('.toml', () => expect(detectFormat('config.toml'), Format.toml));
    test('.JSON (case)', () => expect(detectFormat('DATA.JSON'), Format.json));
    test('.txt returns null', () => expect(detectFormat('file.txt'), null));
    test('no extension returns null', () => expect(detectFormat('file'), null));
  });

  group('Format sniffing by content', () {
    test('object → json', () => expect(sniffFormat('{"key": 1}'), Format.json));
    test('array → json', () => expect(sniffFormat('[1, 2]'), Format.json));
    test(
      '--- → yaml',
      () => expect(sniffFormat('---\nname: test'), Format.yaml),
    );
    test(
      'key: value → yaml',
      () => expect(sniffFormat('name: test'), Format.yaml),
    );
    test(
      'key = value → toml',
      () => expect(sniffFormat('name = "test"'), Format.toml),
    );
    test(
      'leading whitespace ignored',
      () => expect(sniffFormat('  {"key": 1}'), Format.json),
    );
  });

  group('YAML input', () {
    test('simple mapping', () {
      final result = queryString('.name', 'name: Alice', format: Format.yaml);
      expect(result, 'Alice');
    });

    test('nested mapping (flow)', () {
      const yaml = '{database: {host: localhost, port: 5432}}';
      expect(
        queryString('.database.host', yaml, format: Format.yaml),
        'localhost',
      );
      expect(queryString('.database.port', yaml, format: Format.yaml), 5432);
    });

    test('sequence (flow)', () {
      const yaml = '{items: [apple, banana, cherry]}';
      final result = queryString('.items | length', yaml, format: Format.yaml);
      expect(result, 3);
    });

    test('multi-line block mapping', () {
      const yaml = 'active: true\ndeleted: false\n';
      expect(queryString('.active', yaml, format: Format.yaml), true);
      expect(queryString('.deleted', yaml, format: Format.yaml), false);
    });

    test('null value', () {
      expect(queryString('.notes', 'notes: null', format: Format.yaml), null);
    });

    test('integer preserved', () {
      final result = queryString('.port', 'port: 8080', format: Format.yaml);
      expect(result, isA<int>());
      expect(result, 8080);
    });

    test('float preserved', () {
      final result = queryString('.pi', 'pi: 3.14', format: Format.yaml);
      expect(result, isA<double>());
      expect(result, 3.14);
    });
  });

  group('TOML input', () {
    test('simple key-value', () {
      final result = queryString(
        '.title',
        'title = "My App"',
        format: Format.toml,
      );
      expect(result, 'My App');
    });

    test('nested table', () {
      const toml = '''
[database]
host = "localhost"
port = 5432
''';
      expect(
        queryString('.database.host', toml, format: Format.toml),
        'localhost',
      );
      expect(queryString('.database.port', toml, format: Format.toml), 5432);
    });

    test('array', () {
      const toml = 'ports = [8080, 8081, 8082]';
      expect(queryString('.ports | length', toml, format: Format.toml), 3);
      expect(queryString('.ports[0]', toml, format: Format.toml), 8080);
    });

    test('boolean', () {
      const toml = 'enabled = true';
      expect(queryString('.enabled', toml, format: Format.toml), true);
    });

    test('integer preserved', () {
      final result = queryString('.port', 'port = 8080', format: Format.toml);
      expect(result, isA<int>());
      expect(result, 8080);
    });
  });

  group('Auto-detected format', () {
    test('JSON auto-detected', () {
      expect(queryString('.name', '{"name": "Alice"}'), 'Alice');
    });

    test('YAML auto-detected', () {
      expect(queryString('.name', 'name: Alice'), 'Alice');
    });
  });

  group('Aggregation operations', () {
    test('sum', () {
      expect(query('. | sum', [1, 2, 3, 4]), 10);
    });

    test('sum preserves int', () {
      expect(query('. | sum', [1, 2, 3]), isA<int>());
    });

    test('sum with doubles', () {
      expect(query('. | sum', [1.5, 2.5]), 4.0);
    });

    test('avg', () {
      expect(query('. | avg', [2, 4, 6]), 4.0);
    });

    test('avg returns double', () {
      expect(query('. | avg', [1, 2]), isA<double>());
    });

    test('min', () {
      expect(query('. | min', [3, 1, 2]), 1);
    });

    test('min strings', () {
      expect(query('. | min', ['banana', 'apple', 'cherry']), 'apple');
    });

    test('max', () {
      expect(query('. | max', [3, 1, 2]), 3);
    });

    test('max strings', () {
      expect(query('. | max', ['banana', 'apple', 'cherry']), 'cherry');
    });

    test('sum on empty list throws', () {
      expect(query('. | sum', <Object?>[]), 0);
    });

    test('avg on empty list throws', () {
      expect(() => query('. | avg', <Object?>[]), throwsA(isA<QueryError>()));
    });

    test('min on empty list throws', () {
      expect(() => query('. | min', <Object?>[]), throwsA(isA<QueryError>()));
    });

    test('map then sum', () {
      final data = {
        'items': [
          {'price': 10, 'qty': 2},
          {'price': 5, 'qty': 3},
        ],
      };
      expect(query('.items | map(.price * .qty) | sum', data), 35);
    });
  });
}
