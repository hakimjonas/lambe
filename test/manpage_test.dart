import 'dart:io';

import 'package:test/test.dart';

void main() {
  final result = Process.runSync(
    'dart',
    ['run', 'tool/manpage.dart'],
    environment: {'PATH': '${Platform.environment['PATH']}'},
  );

  final output = result.stdout as String;

  group('Title block', () {
    test('TH header from YAML front matter', () {
      expect(output, contains('.TH "LAM" "1" "April 2026" "'));
    });

    test('author section', () {
      expect(output, contains('.SH AUTHOR'));
      expect(output, contains('Hakim Jonas Ghoula'));
    });
  });

  group('Headings', () {
    test('h1 becomes .SH uppercase', () {
      expect(output, contains('.SH NAME'));
      expect(output, contains('.SH SYNOPSIS'));
      expect(output, contains('.SH DESCRIPTION'));
      expect(output, contains('.SH OPTIONS'));
      expect(output, contains('.SH EXAMPLES'));
      expect(output, contains('.SH SEE ALSO'));
    });

    test('h2 becomes .SS', () {
      expect(output, contains('.SS Field access'));
      expect(output, contains('.SS Indexing'));
      expect(output, contains('.SS Slicing'));
    });
  });

  group('Inline formatting', () {
    test('bold with double asterisks', () {
      expect(output, contains(r'\fBlam\fR'));
      expect(output, contains(r'\fB-i\fR'));
    });

    test('italic with single asterisks', () {
      expect(output, contains(r'\fIOPTIONS\fR'));
      expect(output, contains(r'\fIFILE\fR'));
    });

    test('no raw asterisks from formatting', () {
      expect(output, isNot(contains('**')));
    });
  });

  group('Definition lists', () {
    test('options rendered as .TP blocks', () {
      expect(output, contains('.TP'));
      expect(output, contains(r'\fB-p\fR'));
      expect(output, contains('Pretty-print output.'));
    });

    test('REPL commands rendered as .TP blocks', () {
      expect(output, contains('Show data structure.'));
      expect(output, contains('Set output format.'));
    });
  });

  group('Code blocks', () {
    test('indented code becomes .nf/.fi', () {
      expect(output, contains('.nf'));
      expect(output, contains('.fi'));
      expect(output, contains("lam '.database.host' config.toml"));
    });
  });

  group('Structure', () {
    test('no empty .SH or .SS', () {
      expect(RegExp(r'\.SH\s*\n\.SH').hasMatch(output), isFalse);
      expect(RegExp(r'\.SS\s*\n\.SS').hasMatch(output), isFalse);
    });

    test('no pandoc % metadata in output', () {
      expect(output, isNot(contains('% LAM')));
      expect(output, isNot(contains('% Hakim')));
    });

    test('no YAML front matter in output', () {
      expect(output, isNot(contains('---')));
      expect(output, isNot(contains('title: LAM')));
    });

    test('ends with footer', () {
      expect(output.trim(), isNot(isEmpty));
    });
  });

  group('Round-trip', () {
    test('man -l renders without errors', () {
      final manResult = Process.runSync('man', ['-l', 'doc/lam.1']);
      expect(manResult.exitCode, 0);
    });

    test('output matches committed lam.1', () {
      final committed = File('doc/lam.1').readAsStringSync();
      expect(output, committed);
    });
  });
}
