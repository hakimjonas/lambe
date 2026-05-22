/// Tests for the `text` pipe op — markdown prose extraction.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

Map<String, Object?> _md(String src) =>
    queryString('.', src, format: Format.markdown) as Map<String, Object?>;

void main() {
  group('text on markdown nodes', () {
    test('plain heading', () {
      final doc = _md('# hello\n');
      expect(query('.children[0] | text', doc), 'hello');
    });

    test('heading with emphasis', () {
      final doc = _md('# *hello*\n');
      expect(query('.children[0] | text', doc), 'hello');
    });

    test('heading with inline code', () {
      final doc = _md('# `hello`\n');
      expect(query('.children[0] | text', doc), 'hello');
    });

    test('heading with link returns link text, not href', () {
      final doc = _md('# [docs](http://example.com)\n');
      expect(query('.children[0] | text', doc), 'docs');
    });

    test('nested inline (strong + emphasis)', () {
      final doc = _md('# **_hello_**\n');
      expect(query('.children[0] | text', doc), 'hello');
    });

    test('heading with image returns alt', () {
      final doc = _md('# ![alt text](src.png)\n');
      expect(query('.children[0] | text', doc), 'alt text');
    });

    test('code_block contributes code', () {
      final doc = _md('```\nfoo\n```\n');
      expect(query('.children[0] | text', doc), 'foo\n');
    });

    test('html_block excluded', () {
      final doc = _md('<div>raw</div>\n');
      expect(query('.children[0] | text', doc), '');
    });

    test(
      'html_inline tags excluded from paragraph (text between tags kept)',
      () {
        // CommonMark splits `hello <span>x</span> world` into text/html
        // tokens: "hello ", html_inline("<span>"), "x",
        // html_inline("</span>"), " world". Only the html_inline tags are
        // excluded; "x" is a regular text node.
        final doc = _md('hello <span>x</span> world\n');
        final result = query('.children[0] | text', doc) as String;
        expect(result, 'hello x world');
        expect(result.contains('<span>'), isFalse);
      },
    );

    test('hard break contributes empty string', () {
      final doc = _md('hello  \nworld\n');
      final result = query('.children[0] | text', doc);
      expect(result, contains('hello'));
      expect(result, contains('world'));
    });

    test('list of nodes (children) returns concatenated text', () {
      final doc = _md('# one\n\n# two\n');
      expect(query('.children | filter(.type == "heading") | map(text)', doc), [
        'one',
        'two',
      ]);
    });

    test('single node accepted (polymorphism)', () {
      final doc = _md('# hello\n');
      expect(query('.children[0] | text', doc), 'hello');
    });

    test('non-markdown map yields empty string', () {
      expect(query('. | text', {'name': 'Alice'}), '');
    });

    test('non-map non-list scalar throws', () {
      expect(() => query('. | text', 42), throwsA(isA<QueryError>()));
      expect(() => query('. | text', 'hello'), throwsA(isA<QueryError>()));
    });

    test('empty list returns empty string', () {
      expect(query('. | text', <Object?>[]), '');
    });

    test('top-level document returns full text', () {
      final doc = _md('# heading\n\nbody text.\n');
      final result = query('. | text', doc) as String;
      expect(result, contains('heading'));
      expect(result, contains('body text.'));
    });
  });

  group('text op metadata', () {
    test('registered in pipeOpNames', () {
      expect(pipeOpNames, contains('text'));
    });

    test('accepts list and map shapes', () {
      final spec = pipeOpInfoForName('text')!;
      expect(spec.accepts(const SList(SAny())), isTrue);
      expect(spec.accepts(const SMap(<String, Shape>{})), isTrue);
      expect(spec.accepts(const SAny()), isTrue);
    });

    test('rejects scalar shapes', () {
      final spec = pipeOpInfoForName('text')!;
      expect(spec.accepts(const SString()), isFalse);
      expect(spec.accepts(const SNum()), isFalse);
      expect(spec.accepts(const SBool()), isFalse);
    });

    test('infers SString output', () {
      final ast = parseAst('. | text');
      expect(inferShape(ast, const SAny()), isA<SString>());
    });
  });
}
