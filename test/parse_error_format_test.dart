/// Tests for the line-aware parse-error renderer.
///
/// A query with a typo or dangling pipe should produce a jq-style
/// excerpt: the error header with `line:column`, the offending line
/// with a gutter-prefixed line number, a caret under the offending
/// column, and (for multi-line queries) one line of context on either
/// side so the reader can orient. The "did you mean" hint for mistyped
/// pipe ops continues to work.
///
/// QueryError.message is the clean rendered text; callers should print
/// `e.message` rather than `$e`, because `$e` prepends `QueryError: `
/// and doubles the prefix the CLI adds.
library;

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('parseAst: single-line errors', () {
    test('mistyped pipe op emits a did-you-mean hint', () {
      try {
        parseAst('.users | filtre(.age)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 1, column 8'));
        expect(e.message, contains('unknown operation "filtre"'));
        expect(e.message, contains('did you mean "filter"?'));
        expect(e.message, contains('  1 | .users | filtre(.age)'));
        expect(e.message, contains('\n             ^'));
      }
    });

    test('trailing pipe points at the pipe column', () {
      try {
        parseAst('.users |');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 1, column 8'));
        expect(e.message, contains('unexpected | at end of expression'));
        expect(e.message, contains('  1 | .users |'));
      }
    });

    test('mid-expression leftover lands the caret at the token', () {
      try {
        parseAst('.foo bar');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 1, column 6'));
        expect(e.message, contains('unexpected "bar"'));
        expect(e.message, contains('  1 | .foo bar'));
      }
    });
  });

  group('parseAst: multi-line errors', () {
    test('error on line 2 shows line 1 as context', () {
      try {
        parseAst('.users\n| filtre(.age)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 2, column 1'));
        expect(e.message, contains('did you mean "filter"?'));
        expect(e.message, contains('  1 | .users'));
        expect(e.message, contains('  2 | | filtre(.age)'));
      }
    });

    test('error on line 3 shows line 2 as context but not line 1', () {
      try {
        parseAst('.users\n| map(.name)\n| filtre(.)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 3, column 1'));
        expect(e.message, contains('  2 | | map(.name)'));
        expect(e.message, contains('  3 | | filtre(.)'));
        expect(e.message, isNot(contains('  1 | .users')));
      }
    });

    test('error on line 1 of a multi-line query shows line 2 below', () {
      try {
        parseAst('.foo bar\n| map(.name)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 1, column 6'));
        expect(e.message, contains('  1 | .foo bar'));
        expect(e.message, contains('  2 | | map(.name)'));
      }
    });

    test('gutter width grows with total line count', () {
      final prefix = List<String>.filled(10, '.').join('\n| ');
      try {
        parseAst('$prefix\n| filtre(.)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 11, column 1'));
        expect(e.message, contains(' 10 | | .'));
        expect(e.message, contains(' 11 | | filtre(.)'));
      }
    });

    test('Windows-style \\r\\n line endings split correctly', () {
      try {
        parseAst('.users\r\n| filtre(.age)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('line 2, column 1'));
        expect(e.message, contains('  1 | .users'));
        expect(e.message, contains('  2 | | filtre(.age)'));
        expect(e.message, isNot(contains('\r')));
      }
    });
  });

  group('parseAst: empty input is actionable', () {
    test('empty expression returns a one-liner, not a 30-token list', () {
      try {
        parseAst('');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, 'parse error: expression is empty');
        expect(e.message, isNot(contains('expected')));
        expect(e.message, isNot(contains('filter')));
      }
    });

    test('whitespace-only expression treated as empty', () {
      try {
        parseAst('   ');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, 'parse error: expression is empty');
      }
    });

    test('newline-only expression treated as empty', () {
      try {
        parseAst('\n\n');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, 'parse error: expression is empty');
      }
    });
  });

  group('QueryError.message vs toString', () {
    test('message is prefix-free, toString adds QueryError:', () {
      try {
        parseAst('.foo bar');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, startsWith('parse error at '));
        expect(e.toString(), startsWith('QueryError: parse error at '));
      }
    });
  });

  group('jq-idiom hints', () {
    test('.users[] suggests map()', () {
      try {
        parseAst('.users[]');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('no `[]` iterate-all'));
        expect(e.message, contains('map(.name)'));
      }
    });

    test('.items[].name suggests map()', () {
      try {
        parseAst('.items[].name');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('no `[]` iterate-all'));
      }
    });

    test('.foo? suggests has() / shape-check', () {
      try {
        parseAst('.foo?');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('no `?` optional-path suffix'));
        expect(e.message, contains('has('));
      }
    });

    test('.. suggests explicit paths', () {
      try {
        parseAst('..');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('no `..` recursive descent'));
      }
    });

    test('| select(pred) suggests filter()', () {
      try {
        parseAst('.x | select(.active)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('select'));
        expect(e.message, contains('filter'));
      }
    });

    test('map(select(...)) suggests filter()', () {
      try {
        parseAst('.users | map(select(.active))');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('only valid inside `filter'));
      }
    });

    test('| empty suggests filter()', () {
      try {
        parseAst('.x | empty');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('`empty` does not exist'));
        expect(e.message, contains('filter'));
      }
    });

    test('if/then/else/end with empty suggests filter()', () {
      try {
        parseAst('.x | map(if .a then .a else empty end)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('no `empty` keyword'));
      }
    });

    test('| if as pipe stage explains the expression-only rule', () {
      try {
        parseAst('.x | if . > 0 then . else null end');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('if/then/else/end'));
        expect(e.message, contains('expression'));
      }
    });

    test('did-you-mean still fires for plain typos', () {
      try {
        parseAst('.users | filtre(.age)');
        fail('expected parse to fail');
      } on QueryError catch (e) {
        expect(e.message, contains('did you mean "filter"?'));
      }
    });
  });
}
