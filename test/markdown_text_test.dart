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

    test('hard break contributes a newline', () {
      // Markdown hard break = `\` at end of line, or two trailing
      // spaces. Author intent is "force a line break here", so
      // `text` preserves it as `'\n'`. The CommonMark parser emits
      // both a `hard_break` AND a `soft_break` for the source
      // `"hello  \nworld"` (the explicit break followed by the
      // line continuation), so the result has both separators in
      // sequence. Users who want a fully flat string can
      // post-process with a whitespace collapser.
      final doc = _md('hello  \nworld\n');
      final result = query('.children[0] | text', doc) as String;
      expect(result, contains('hello'));
      expect(result, contains('world'));
      expect(result.contains('\n'), isTrue);
    });

    test('soft break contributes a single space', () {
      // Markdown soft break = a single newline in the source where
      // the author intended paragraph continuation, not a forced
      // break. Without a separator, words on consecutive source
      // lines would concatenate ("queriesagainst" instead of
      // "queries against"). A space preserves word boundaries
      // without imposing line structure. This deliberately diverges
      // from `mdast-util-to-string`'s empty-on-soft-break default.
      final doc = _md('hello\nworld\n');
      final result = query('.children[0] | text', doc) as String;
      expect(result, 'hello world');
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

  group('YAML frontmatter is split out, not absorbed as prose', () {
    const fmSource =
        '---\n'
        'title: My Title\n'
        'tags:\n'
        '  - alpha\n'
        '  - beta\n'
        '---\n'
        '\n'
        '# Heading\n'
        '\n'
        'Body.\n';

    test('text op no longer scoops up the frontmatter', () {
      final doc = _md(fmSource);
      final result = query('. | text', doc) as String;
      // Pre-fix: the result included "title: My Title alpha beta..." because
      // the YAML block was parsed as a paragraph. Post-fix: only the body.
      expect(result, contains('Heading'));
      expect(result, contains('Body.'));
      expect(result, isNot(contains('title:')));
      expect(result, isNot(contains('alpha')));
    });

    test('frontmatter is addressable via .frontmatter', () {
      final doc = _md(fmSource);
      expect(query('.frontmatter.title', doc), 'My Title');
      expect(query('.frontmatter.tags', doc), <String>['alpha', 'beta']);
    });

    test('document without frontmatter has no frontmatter field', () {
      final doc = _md('# heading\n\nbody.\n');
      expect(query('. | has("frontmatter")', doc), false);
    });

    test('children of frontmatter doc preserve previous shape', () {
      final doc = _md(fmSource);
      final firstChild = query('.children[0]', doc) as Map<String, Object?>;
      expect(firstChild['type'], 'heading');
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
