import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('--to: format conversion', () {
    group('JSON output', () {
      test('pretty', () {
        final out = formatOutput({'name': 'Alice'}, OutputFormat.json);
        expect(out, contains('\n'));
        expect(out, contains('"name"'));
      });

      test('compact', () {
        final out = formatOutput(
          {'name': 'Alice'},
          OutputFormat.json,
          pretty: false,
        );
        expect(out, isNot(contains('\n')));
      });
    });

    group('YAML output', () {
      test('simple mapping', () {
        final out = formatOutput({
          'name': 'Alice',
          'age': 25,
        }, OutputFormat.yaml);
        expect(out, contains('name: Alice'));
        expect(out, contains('age: 25'));
      });

      test('nested mapping', () {
        final out = formatOutput({
          'database': {'host': 'localhost', 'port': 5432},
        }, OutputFormat.yaml);
        expect(out, contains('database:'));
        expect(out, contains('  host: localhost'));
      });

      test('sequence', () {
        final out = formatOutput({
          'tags': ['admin', 'user'],
        }, OutputFormat.yaml);
        expect(out, contains('- admin'));
        expect(out, contains('- user'));
      });

      test('null value', () {
        final out = formatOutput({'key': null}, OutputFormat.yaml);
        expect(out, contains('null'));
      });
    });

    group('TOML output', () {
      test('simple table', () {
        final out = formatOutput({
          'name': 'Alice',
          'port': 8080,
        }, OutputFormat.toml);
        expect(out, contains('name = "Alice"'));
        expect(out, contains('port = 8080'));
      });

      test('nested table', () {
        final out = formatOutput({
          'title': 'test',
          'database': {'host': 'localhost', 'port': 5432},
        }, OutputFormat.toml);
        expect(out, contains('[database]'));
        expect(out, contains('host = "localhost"'));
      });

      test('root must be map', () {
        expect(
          () => formatOutput([1, 2, 3], OutputFormat.toml),
          throwsA(isA<QueryError>()),
        );
      });

      test('root string throws', () {
        expect(
          () => formatOutput('hello', OutputFormat.toml),
          throwsA(isA<QueryError>()),
        );
      });
    });
  });

  group('--assert: validation', () {
    test('true expression', () {
      final result = query('.version != "0.0.0"', {'version': '1.0.0'});
      expect(result, true);
    });

    test('false expression', () {
      final result = query('.version != "0.0.0"', {'version': '0.0.0'});
      expect(result, false);
    });

    test('complex assertion', () {
      final result = query('.users | length > 0 && .version != null', {
        'users': [
          {'name': 'Alice'},
        ],
        'version': '1.0.0',
      });
      expect(result, true);
    });
  });

  group('HCL input', () {
    test('simple attributes', () {
      final result = queryString(
        '.name',
        'name = "Alice"\nage = 30\n',
        format: Format.hcl,
      );
      expect(result, 'Alice');
    });

    test('block access', () {
      final result = queryString(
        '.resource[0]._labels',
        'resource "aws_instance" "web" {\n  ami = "abc"\n}\n',
        format: Format.hcl,
      );
      expect(result, ['aws_instance', 'web']);
    });

    test('block body field', () {
      final result = queryString(
        '.resource[0].ami',
        'resource "aws_instance" "web" {\n  ami = "abc"\n}\n',
        format: Format.hcl,
      );
      expect(result, 'abc');
    });

    test('blocks are list-shaped uniformly across N=1 and N=2', () {
      final n1 = queryString(
        '.variable',
        'variable "region" {\n  default = "us-east-1"\n}\n',
        format: Format.hcl,
      );
      expect(n1, isA<List<Object?>>());
      expect((n1 as List).length, 1);

      final n2 = queryString(
        '.variable',
        'variable "region" {\n  default = "us-east-1"\n}\n'
            'variable "instance_type" {\n  default = "t3.micro"\n}\n',
        format: Format.hcl,
      );
      expect(n2, isA<List<Object?>>());
      expect((n2 as List).length, 2);
    });

    test('.tf extension auto-detected', () {
      expect(detectFormat('main.tf'), Format.hcl);
      expect(detectFormat('config.hcl'), Format.hcl);
    });
  });

  group('Ring 6 integration', () {
    test('query JSON, output as YAML', () {
      final data = {'name': 'Alice', 'age': 25};
      final result = query('.', data);
      final yaml = formatOutput(result, OutputFormat.yaml);
      expect(yaml, contains('name: Alice'));
      expect(yaml, contains('age: 25'));
    });

    test('query YAML, output as JSON', () {
      final result = queryString(
        '.',
        'name: Alice\nage: 30\n',
        format: Format.yaml,
      );
      final json = formatOutput(result, OutputFormat.json, pretty: false);
      expect(json, contains('"name":"Alice"'));
    });

    test('assert on TOML config', () {
      final result = queryString(
        '.database.port > 0',
        '[database]\nhost = "localhost"\nport = 5432\n',
        format: Format.toml,
      );
      expect(result, true);
    });
  });
}
