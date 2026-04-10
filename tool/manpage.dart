/// Generates lam.1 mandoc from doc/lam.1.md using Rumil combinators.
///
/// Usage: dart run tool/manpage.dart > doc/lam.1
library;

import 'dart:io';

import 'package:rumil/rumil.dart';

void main() {
  final input = File('doc/lam.1.md').readAsStringSync();
  final result = _document.run(input);
  switch (result) {
    case Success(:final value) || Partial(:final value):
      stdout.write(_emit(value));
    case Failure(:final errors):
      stderr.writeln('Parse error: $errors');
      exit(1);
  }
}

sealed class MdNode {
  const MdNode();
}

final class TitleBlock extends MdNode {
  final String title;
  final String section;
  final String source;
  final String author;
  final String date;
  const TitleBlock(
    this.title,
    this.section,
    this.source,
    this.author,
    this.date,
  );
}

final class Heading extends MdNode {
  final int level;
  final String text;
  const Heading(this.level, this.text);
}

final class Paragraph extends MdNode {
  final String text;
  const Paragraph(this.text);
}

final class DefinitionItem extends MdNode {
  final String term;
  final String definition;
  const DefinitionItem(this.term, this.definition);
}

final class CodeBlock extends MdNode {
  final String text;
  const CodeBlock(this.text);
}

final class BlankLine extends MdNode {
  const BlankLine();
}

final _nl = char('\n');
final _notNl = satisfy((c) => c != '\n', 'not newline');
final _restOfLine = _notNl.many.capture.thenSkip(_nl);
final _blankLine = char('\n').as<MdNode>(const BlankLine());

final _frontMatterDelim = string('---').thenSkip(_nl);
final _frontMatterField = string(
  '---',
).notFollowedBy.skipThen(_notNl.many1.capture).thenSkip(_nl);

final _titleBlock = _frontMatterDelim
    .skipThen(_frontMatterField.many1)
    .thenSkip(_frontMatterDelim)
    .map((lines) {
      final fields = <String, String>{};
      for (final line in lines) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          fields[line.substring(0, colon).trim()] =
              line.substring(colon + 1).trim();
        }
      }
      return TitleBlock(
            fields['title'] ?? 'UNTITLED',
            fields['section'] ?? '1',
            fields['source'] ?? '',
            fields['author'] ?? '',
            fields['date'] ?? '',
          )
          as MdNode;
    });

final _heading = char('#').many1.capture.flatMap(
  (hashes) => char(' ')
      .skipThen(_restOfLine)
      .map((text) => Heading(hashes.length, text.trim()) as MdNode),
);

final _defTerm = _restOfLine;
final _defBody = string(':   ').skipThen(_restOfLine);
final _definition = _defTerm.flatMap(
  (term) => _defBody.map(
    (body) => DefinitionItem(term.trim(), body.trim()) as MdNode,
  ),
);

final _codeLine = string('    ').skipThen(_restOfLine);
final _codeBlock = _codeLine.many1.map(
  (lines) => CodeBlock(lines.join('\n')) as MdNode,
);

final _paragraph = _notNl.many1.capture
    .thenSkip(_nl)
    .many1
    .map((lines) => Paragraph(lines.join(' ').trim()) as MdNode);

final _node =
    _titleBlock | _heading | _definition | _codeBlock | _blankLine | _paragraph;

final _document = _node.many.thenSkip(eof());

String _emit(List<MdNode> nodes) {
  final buf = StringBuffer();

  for (final node in nodes) {
    switch (node) {
      case TitleBlock(
        :final title,
        :final section,
        :final source,
        :final author,
        :final date,
      ):
        buf.writeln(
          '.TH "${title.toUpperCase()}" "$section" "$date" "$source" ""',
        );
        if (author.isNotEmpty) {
          buf.writeln('.SH AUTHOR');
          buf.writeln(author);
        }
      case Heading(:final level, :final text):
        if (level == 1) {
          buf.writeln('.SH ${text.toUpperCase()}');
        } else {
          buf.writeln('.SS $text');
        }
      case Paragraph(:final text):
        buf.writeln('.PP');
        buf.writeln(_inlineFormat(text));
      case DefinitionItem(:final term, :final definition):
        buf.writeln('.TP');
        buf.writeln(_inlineFormat(term));
        buf.writeln(_inlineFormat(definition));
      case CodeBlock(:final text):
        buf.writeln('.PP');
        buf.writeln('.nf');
        buf.writeln(text);
        buf.writeln('.fi');
      case BlankLine():
        break;
    }
  }

  return buf.toString();
}

String _inlineFormat(String text) => text
    .replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => '\\fB${m.group(1)}\\fR',
    )
    .replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) => '\\fI${m.group(1)}\\fR')
    .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => '\\fC${m.group(1)}\\fR');
