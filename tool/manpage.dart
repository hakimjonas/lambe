/// Generates lam.1 mandoc from doc/lam.1.md using rumil_parsers' CommonMark
/// parser.
///
/// Usage: dart run tool/manpage.dart > doc/lam.1
library;

import 'dart:io';

import 'package:rumil/rumil.dart';
import 'package:rumil_parsers/rumil_parsers.dart';

void main() {
  var input = File('doc/lam.1.md').readAsStringSync();

  final meta = _extractFrontMatter(input);
  if (meta != null) {
    input = input.substring(meta.endOffset);
  }

  final result = parseMarkdown(input);
  switch (result) {
    case Success(:final value) || Partial(:final value):
      stdout.write(_emit(meta, value));
    case Failure(:final errors):
      stderr.writeln('Parse error: $errors');
      exit(1);
  }
}

final class _FrontMatter {
  final String title;
  final String section;
  final String source;
  final String author;
  final String date;
  final int endOffset;
  const _FrontMatter({
    required this.title,
    required this.section,
    required this.source,
    required this.author,
    required this.date,
    required this.endOffset,
  });
}

_FrontMatter? _extractFrontMatter(String input) {
  if (!input.startsWith('---\n')) return null;
  final end = input.indexOf('\n---\n', 4);
  if (end < 0) return null;
  final yamlSource = input.substring(4, end);
  final result = parseYaml(yamlSource);
  final fields = switch (result) {
    Success(:final value) => yamlToNative(value),
    Partial(:final value) => yamlToNative(value),
    Failure() => null,
  };
  if (fields is! Map<String, Object?>) return null;
  return _FrontMatter(
    title: '${fields['title'] ?? 'UNTITLED'}',
    section: '${fields['section'] ?? '1'}',
    source: '${fields['source'] ?? ''}',
    author: '${fields['author'] ?? ''}',
    date: '${fields['date'] ?? ''}',
    endOffset: end + 5,
  );
}

String _emit(_FrontMatter? meta, MdDocument doc) {
  final buf = StringBuffer();

  if (meta != null) {
    buf.writeln(
      '.TH "${meta.title.toUpperCase()}" "${meta.section}" '
      '"${meta.date}" "${meta.source}" ""',
    );
    if (meta.author.isNotEmpty) {
      buf.writeln('.SH AUTHOR');
      buf.writeln(meta.author);
    }
  }

  for (final node in doc.children) {
    _emitBlock(buf, node);
  }

  return buf.toString();
}

void _emitBlock(StringBuffer buf, MdNode node) {
  switch (node) {
    case MdHeading(:final level, :final children):
      final text = _inlineText(children);
      if (level == 1) {
        buf.writeln('.SH ${text.toUpperCase()}');
      } else {
        buf.writeln('.SS $text');
      }
    case MdParagraph(:final children):
      final def = _tryDefinition(children);
      if (def != null) {
        buf.writeln('.TP');
        buf.writeln(def.term);
        buf.writeln(def.definition);
      } else {
        buf.writeln('.PP');
        buf.writeln(_inlineText(children));
      }
    case MdCodeBlock(:final code):
      buf.writeln('.PP');
      buf.writeln('.nf');
      buf.write(code);
      if (!code.endsWith('\n')) buf.writeln();
      buf.writeln('.fi');
    case MdBlockquote(:final children):
      buf.writeln('.RS');
      for (final child in children) {
        _emitBlock(buf, child);
      }
      buf.writeln('.RE');
    case MdList(:final items):
      for (final item in items) {
        _emitBlock(buf, item);
      }
    case MdListItem(:final children):
      buf.writeln('.IP \\(bu 2');
      for (final child in children) {
        _emitBlock(buf, child);
      }
    case MdThematicBreak():
      buf.writeln('.PP');
      buf.writeln('\\l\'\\n(.lu\'');
    default:
      break;
  }
}

final class _Definition {
  final String term;
  final String definition;
  const _Definition(this.term, this.definition);
}

_Definition? _tryDefinition(List<MdNode> children) {
  final breakIdx = children.indexWhere((n) => n is MdSoftBreak);
  if (breakIdx < 0 || breakIdx >= children.length - 1) return null;

  final afterBreak = children[breakIdx + 1];
  if (afterBreak is! MdText) return null;
  if (!afterBreak.text.startsWith(':   ')) return null;

  final term = _inlineText(children.sublist(0, breakIdx));
  final defParts = <MdNode>[
    MdText(afterBreak.text.substring(4)),
    ...children.sublist(breakIdx + 2),
  ];
  return _Definition(term, _inlineText(defParts));
}

String _inlineText(List<MdNode> nodes) {
  final buf = StringBuffer();
  for (final node in nodes) {
    switch (node) {
      case MdText(:final text):
        buf.write(text.replaceAll(r'\', r'\\'));
      case MdStrong(:final children):
        buf.write('\\fB${_inlineText(children)}\\fR');
      case MdEmphasis(:final children):
        buf.write('\\fI${_inlineText(children)}\\fR');
      case MdCode(:final code):
        buf.write('\\fC$code\\fR');
      case MdLink(:final children):
        buf.write(_inlineText(children));
      case MdSoftBreak():
        buf.write(' ');
      case MdHardBreak():
        buf.writeln();
      default:
        break;
    }
  }
  return buf.toString();
}
