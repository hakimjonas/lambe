import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('Format detection by extension', () {
    test('.json', () => expect(detectFormat('data.json'), Format.json));
    test('.yaml', () => expect(detectFormat('config.yaml'), Format.yaml));
    test('.yml', () => expect(detectFormat('config.yml'), Format.yaml));
    test('.toml', () => expect(detectFormat('config.toml'), Format.toml));
    test('.JSON (case)', () => expect(detectFormat('DATA.JSON'), Format.json));
    test('.md', () => expect(detectFormat('README.md'), Format.markdown));
    test(
      '.markdown',
      () => expect(detectFormat('notes.markdown'), Format.markdown),
    );
    test('.MD (case)', () => expect(detectFormat('DOC.MD'), Format.markdown));
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
    test(
      '# heading → markdown',
      () => expect(sniffFormat('# Hello World'), Format.markdown),
    );
    test(
      '- list → markdown',
      () => expect(sniffFormat('- item one\n- item two'), Format.markdown),
    );
    test(
      '* list → markdown',
      () => expect(sniffFormat('* first\n* second'), Format.markdown),
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

  group('Markdown input', () {
    test('heading', () {
      final result = queryString(
        '.children[0].type',
        '# Hello',
        format: Format.markdown,
      );
      expect(result, 'heading');
    });

    test('heading level', () {
      expect(
        queryString('.children[0].level', '## Sub', format: Format.markdown),
        2,
      );
    });

    test('heading text', () {
      expect(
        queryString(
          '.children[0].children[0].text',
          '# Title',
          format: Format.markdown,
        ),
        'Title',
      );
    });

    test('paragraph', () {
      expect(
        queryString(
          '.children[0].type',
          'Hello world',
          format: Format.markdown,
        ),
        'paragraph',
      );
    });

    test('link', () {
      const md = '[click](https://example.com)';
      final result = queryString(
        '.children[0].children[0]',
        md,
        format: Format.markdown,
      );
      expect(result, isA<Map<String, Object?>>());
      final link = result as Map<String, Object?>;
      expect(link['type'], 'link');
      expect(link['href'], 'https://example.com');
    });

    test('code block', () {
      const md = '```dart\nvoid main() {}\n```';
      final result = queryString('.children[0]', md, format: Format.markdown);
      expect(result, isA<Map<String, Object?>>());
      final block = result as Map<String, Object?>;
      expect(block['type'], 'code_block');
      expect(block['language'], 'dart');
      expect(block['code'], 'void main() {}\n');
    });

    test('image', () {
      const md = '![alt text](image.png "A title")';
      final result = queryString(
        '.children[0].children[0]',
        md,
        format: Format.markdown,
      );
      expect(result, isA<Map<String, Object?>>());
      final img = result as Map<String, Object?>;
      expect(img['type'], 'image');
      expect(img['src'], 'image.png');
      expect(img['alt'], 'alt text');
      expect(img['title'], 'A title');
    });

    test('emphasis and strong', () {
      const md = '*italic* and **bold**';
      final children =
          queryString('.children[0].children', md, format: Format.markdown)
              as List;
      expect(children[0], isA<Map<String, Object?>>());
      expect((children[0] as Map<String, Object?>)['type'], 'emphasis');
      expect((children[2] as Map<String, Object?>)['type'], 'strong');
    });

    test('unordered list', () {
      const md = '- one\n- two\n- three';
      final result = queryString('.children[0]', md, format: Format.markdown);
      expect(result, isA<Map<String, Object?>>());
      final list = result as Map<String, Object?>;
      expect(list['type'], 'list');
      expect(list['ordered'], false);
      expect((list['items'] as List).length, 3);
    });

    test('ordered list', () {
      const md = '3. first\n4. second';
      final result = queryString('.children[0]', md, format: Format.markdown);
      final list = result as Map<String, Object?>;
      expect(list['type'], 'list');
      expect(list['ordered'], true);
      expect(list['start'], 3);
    });

    test('tight vs loose list', () {
      const tight = '- a\n- b';
      expect(
        queryString('.children[0].tight', tight, format: Format.markdown),
        true,
      );
      const loose = '- a\n\n- b';
      expect(
        queryString('.children[0].tight', loose, format: Format.markdown),
        false,
      );
    });

    test('blockquote', () {
      const md = '> quoted text';
      final result = queryString('.children[0]', md, format: Format.markdown);
      expect((result as Map<String, Object?>)['type'], 'blockquote');
    });

    test('nested blockquote', () {
      const md = '> outer\n>\n> > inner';
      final outer =
          queryString('.children[0]', md, format: Format.markdown)
              as Map<String, Object?>;
      expect(outer['type'], 'blockquote');
      final nested =
          (outer['children'] as List).firstWhere(
                (c) => (c as Map<String, Object?>)['type'] == 'blockquote',
              )
              as Map<String, Object?>;
      expect(nested['type'], 'blockquote');
    });

    test('thematic break', () {
      const md = 'above\n\n---\n\nbelow';
      final types = queryString(
        '.children | map(.type)',
        md,
        format: Format.markdown,
      );
      expect(types, contains('thematic_break'));
    });

    test('inline code', () {
      const md = 'Use `lam` to query';
      final children =
          queryString('.children[0].children', md, format: Format.markdown)
              as List;
      final code =
          children.firstWhere(
                (c) => (c as Map<String, Object?>)['type'] == 'code',
              )
              as Map<String, Object?>;
      expect(code['code'], 'lam');
    });

    test('empty document', () {
      final result = queryString(
        '.children | length',
        '',
        format: Format.markdown,
      );
      expect(result, 0);
    });

    test('html block', () {
      const md = '<div>raw</div>\n';
      final result = queryString(
        '.children[0].type',
        md,
        format: Format.markdown,
      );
      expect(result, 'html_block');
    });

    test('end-to-end: extract all headings', () {
      const md = '# One\n\n## Two\n\nParagraph\n\n### Three';
      final result = queryString(
        '.children | filter(.type == "heading") | map(.level)',
        md,
        format: Format.markdown,
      );
      expect(result, [1, 2, 3]);
    });

    test('end-to-end: find all links', () {
      const md = 'See [A](a.html) and [B](b.html).';
      final result = queryString(
        '.children[0].children | filter(.type == "link") | map(.href)',
        md,
        format: Format.markdown,
      );
      expect(result, ['a.html', 'b.html']);
    });

    test('end-to-end: list code block languages', () {
      const md = '```dart\nx\n```\n\n```python\ny\n```\n\n```\nz\n```';
      final result = queryString(
        '.children | filter(.type == "code_block") | map(.language)',
        md,
        format: Format.markdown,
      );
      expect(result, ['dart', 'python', null]);
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
