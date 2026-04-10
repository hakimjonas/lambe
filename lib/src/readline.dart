/// Minimal readline implementation using raw terminal mode.
///
/// Handles printable characters, cursor movement, history navigation,
/// tab completion with common-prefix fill, and standard editing shortcuts.
/// No external dependencies - uses only `dart:io`.
library;

import 'dart:io';

/// Callback for tab completion.
///
/// Takes the current input [text] and [cursor] position. Returns a record
/// with the replacement [start] position and a sorted list of [candidates].
typedef CompleteCallback =
    ({int start, List<String> candidates}) Function(String text, int cursor);

/// Minimal readline with history and tab completion.
///
/// Uses stdin raw mode for keystroke-level control. Supports:
/// - Printable character insertion at cursor
/// - Backspace, Delete, Left/Right arrows, Home/End
/// - Up/Down arrows for history navigation
/// - Tab completion with common-prefix fill
/// - Ctrl+A (home), Ctrl+E (end), Ctrl+K (kill to end), Ctrl+U (kill to start)
/// - Ctrl+C (cancel line), Ctrl+D (EOF on empty line)
class ReadLine {
  /// Creates a readline instance with an optional [complete] callback
  /// and an externally managed [history] list.
  ///
  /// History is used for Up/Down arrow navigation but is NOT modified
  /// by ReadLine - the caller is responsible for adding complete entries.
  ReadLine({CompleteCallback? complete, List<String>? history})
    : _complete = complete,
      _history = history ?? [];

  final CompleteCallback? _complete;
  final List<String> _history;

  /// Read a line of input displaying [prompt].
  ///
  /// Returns the entered text, or `null` on EOF (Ctrl+D on empty line).
  /// Returns an empty string on Ctrl+C (line cancelled).
  String? call(String prompt) {
    stdout.write(prompt);
    final buf = <int>[];
    var cursor = 0;
    var histIdx = _history.length;
    var saved = '';

    stdin.echoMode = false;
    stdin.lineMode = false;

    try {
      for (;;) {
        final byte = stdin.readByteSync();
        if (byte == -1) return buf.isEmpty ? null : _submit(buf);

        switch (byte) {
          case 0x0a || 0x0d:
            stdout.writeln();
            return _submit(buf);

          case 0x03:
            stdout.writeln('^C');
            return '';

          case 0x04:
            if (buf.isEmpty) {
              stdout.writeln();
              return null;
            }
            if (cursor < buf.length) {
              buf.removeAt(cursor);
              _redraw(prompt, buf, cursor);
            }

          case 0x7f:
            if (cursor > 0) {
              cursor--;
              buf.removeAt(cursor);
              _redraw(prompt, buf, cursor);
            }

          case 0x09:
            cursor = _tab(prompt, buf, cursor);

          case 0x01:
            cursor = 0;
            stdout.write('\r$prompt');

          case 0x05:
            if (cursor < buf.length) {
              stdout.write('\x1b[${buf.length - cursor}C');
              cursor = buf.length;
            }

          case 0x0b:
            buf.removeRange(cursor, buf.length);
            stdout.write('\x1b[K');

          case 0x15:
            buf.removeRange(0, cursor);
            cursor = 0;
            _redraw(prompt, buf, cursor);

          case 0x12:
            final found = _reverseSearch(prompt, buf);
            if (found != null) {
              buf
                ..clear()
                ..addAll(found.codeUnits);
              cursor = buf.length;
            }
            _redraw(prompt, buf, cursor);

          case 0x1b:
            (cursor, histIdx, saved) = _escape(
              prompt,
              buf,
              cursor,
              histIdx,
              saved,
            );

          default:
            if (byte >= 0x20 && byte < 0x7f) {
              buf.insert(cursor, byte);
              cursor++;
              if (cursor == buf.length) {
                stdout.writeCharCode(byte);
              } else {
                _redraw(prompt, buf, cursor);
              }
            }
        }
      }
    } finally {
      stdin.echoMode = true;
      stdin.lineMode = true;
    }
  }

  /// The command history (unmodifiable view).
  List<String> get history => List.unmodifiable(_history);

  String _submit(List<int> buf) => String.fromCharCodes(buf);

  void _redraw(String prompt, List<int> buf, int cursor) {
    stdout.write('\r$prompt${_highlight(buf)}\x1b[K');
    final remaining = buf.length - cursor;
    if (remaining > 0) stdout.write('\x1b[${remaining}D');
  }

  (int, int, String) _escape(
    String prompt,
    List<int> buf,
    int cursor,
    int histIdx,
    String saved,
  ) {
    final next = stdin.readByteSync();
    if (next == 0x5b) {
      return _csi(prompt, buf, cursor, histIdx, saved);
    }
    if (next == 0x4f) {
      return _ss3(prompt, buf, cursor, histIdx, saved);
    }
    return (cursor, histIdx, saved);
  }

  (int, int, String) _csi(
    String prompt,
    List<int> buf,
    int cursor,
    int histIdx,
    String saved,
  ) {
    final code = stdin.readByteSync();
    switch (code) {
      case 0x41:
        if (histIdx > 0) {
          if (histIdx == _history.length) saved = String.fromCharCodes(buf);
          histIdx--;
          buf
            ..clear()
            ..addAll(_history[histIdx].codeUnits);
          cursor = buf.length;
          _redraw(prompt, buf, cursor);
        }

      case 0x42:
        if (histIdx < _history.length) {
          histIdx++;
          final text = histIdx == _history.length ? saved : _history[histIdx];
          buf
            ..clear()
            ..addAll(text.codeUnits);
          cursor = buf.length;
          _redraw(prompt, buf, cursor);
        }

      case 0x43:
        if (cursor < buf.length) {
          cursor++;
          stdout.write('\x1b[C');
        }

      case 0x44:
        if (cursor > 0) {
          cursor--;
          stdout.write('\x1b[D');
        }

      case 0x33:
        if (stdin.readByteSync() == 0x7e && cursor < buf.length) {
          buf.removeAt(cursor);
          _redraw(prompt, buf, cursor);
        }

      case 0x31:
        if (stdin.readByteSync() == 0x3b) {
          final mod = stdin.readByteSync();
          final dir = stdin.readByteSync();
          if (mod == 0x35) {
            switch (dir) {
              case 0x43:
                cursor = _nextWord(buf, cursor);
                _redraw(prompt, buf, cursor);
              case 0x44:
                cursor = _prevWord(buf, cursor);
                _redraw(prompt, buf, cursor);
            }
          }
        }

      case 0x48:
        cursor = 0;
        stdout.write('\r$prompt');

      case 0x46:
        if (cursor < buf.length) {
          stdout.write('\x1b[${buf.length - cursor}C');
          cursor = buf.length;
        }
    }
    return (cursor, histIdx, saved);
  }

  (int, int, String) _ss3(
    String prompt,
    List<int> buf,
    int cursor,
    int histIdx,
    String saved,
  ) {
    final code = stdin.readByteSync();
    switch (code) {
      case 0x48:
        cursor = 0;
        stdout.write('\r$prompt');

      case 0x46:
        if (cursor < buf.length) {
          stdout.write('\x1b[${buf.length - cursor}C');
          cursor = buf.length;
        }
    }
    return (cursor, histIdx, saved);
  }

  int _tab(String prompt, List<int> buf, int cursor) {
    final complete = _complete;
    if (complete == null) return cursor;

    final text = String.fromCharCodes(buf);
    final (:start, :candidates) = complete(text, cursor);
    if (candidates.isEmpty) return cursor;

    if (candidates.length == 1) {
      final replacement = candidates.first;
      final newText =
          '${text.substring(0, start)}$replacement${text.substring(cursor)}';
      buf
        ..clear()
        ..addAll(newText.codeUnits);
      final newCursor = start + replacement.length;
      _redraw(prompt, buf, newCursor);
      return newCursor;
    }

    final prefix = _commonPrefix(candidates);
    var newCursor = cursor;
    if (prefix.length > cursor - start) {
      final newText =
          '${text.substring(0, start)}$prefix${text.substring(cursor)}';
      buf
        ..clear()
        ..addAll(newText.codeUnits);
      newCursor = start + prefix.length;
    }
    stdout.writeln();
    stdout.writeln(candidates.join('    '));
    _redraw(prompt, buf, newCursor);
    return newCursor;
  }

  /// Incremental reverse search through history.
  ///
  /// Returns the matched history entry, or `null` if cancelled.
  String? _reverseSearch(String originalPrompt, List<int> originalBuf) {
    final query = <int>[];
    String? match;

    void redrawSearch() {
      final q = String.fromCharCodes(query);
      final display = match ?? '';
      stdout.write('\r\x1b[K(reverse-i-search)`$q\': $display');
    }

    redrawSearch();

    for (;;) {
      final byte = stdin.readByteSync();
      switch (byte) {
        case -1 || 0x1b || 0x03:
          return null;

        case 0x0a || 0x0d:
          stdout.writeln();
          return match;

        case 0x12:
          if (match != null && query.isNotEmpty) {
            final q = String.fromCharCodes(query);
            final currentIdx = _history.lastIndexOf(match);
            for (var i = currentIdx - 1; i >= 0; i--) {
              if (_history[i].contains(q)) {
                match = _history[i];
                break;
              }
            }
          }
          redrawSearch();

        case 0x7f:
          if (query.isNotEmpty) {
            query.removeLast();
            match = _findMatch(String.fromCharCodes(query));
            redrawSearch();
          }

        default:
          if (byte >= 0x20 && byte < 0x7f) {
            query.add(byte);
            match = _findMatch(String.fromCharCodes(query));
            redrawSearch();
          }
      }
    }
  }

  /// Find the most recent history entry containing [query].
  String? _findMatch(String query) {
    if (query.isEmpty) return null;
    for (var i = _history.length - 1; i >= 0; i--) {
      if (_history[i].contains(query)) return _history[i];
    }
    return null;
  }
}

const _hReset = '\x1b[0m';
const _hDim = '\x1b[2m';
const _hCyan = '\x1b[36m';
const _hGreen = '\x1b[32m';
const _hYellow = '\x1b[33m';
const _hMagenta = '\x1b[35m';
const _hRed = '\x1b[31m';

/// Colorize a buffer for display. Lightweight lexer-level scan - not a full
/// parse, but good enough for interactive highlighting.
String _highlight(List<int> buf) {
  if (buf.isEmpty) return '';

  final out = StringBuffer();
  final text = String.fromCharCodes(buf);
  var i = 0;

  while (i < text.length) {
    final c = text[i];

    if (c == '"') {
      out.write(_hGreen);
      out.write('"');
      i++;
      while (i < text.length && text[i] != '"') {
        if (text[i] == r'\' && i + 1 < text.length) {
          out.write(text[i]);
          out.write(text[i + 1]);
          i += 2;
        } else {
          out.write(text[i]);
          i++;
        }
      }
      if (i < text.length) {
        out.write('"');
        i++;
      }
      out.write(_hReset);
      continue;
    }

    if ((c == '-' && i + 1 < text.length && _isDigit(text.codeUnitAt(i + 1))) ||
        _isDigit(c.codeUnitAt(0))) {
      out.write(_hYellow);
      if (c == '-') {
        out.write(c);
        i++;
      }
      while (i < text.length &&
          (_isDigit(text.codeUnitAt(i)) || text[i] == '.')) {
        out.write(text[i]);
        i++;
      }
      out.write(_hReset);
      continue;
    }

    if ('|><=!&+-*/%'.contains(c)) {
      out.write(_hDim);
      out.write(c);
      if (i + 1 < text.length && '|&='.contains(text[i + 1])) {
        out.write(text[i + 1]);
        i++;
      }
      out.write(_hReset);
      i++;
      continue;
    }

    if ('()[]{}:,'.contains(c)) {
      out.write(_hDim);
      out.write(c);
      out.write(_hReset);
      i++;
      continue;
    }

    if (c == '.') {
      out.write(_hCyan);
      out.write('.');
      i++;
      while (i < text.length && _isWordChar(text.codeUnitAt(i))) {
        out.write(text[i]);
        i++;
      }
      out.write(_hReset);
      continue;
    }

    if (_isWordChar(c.codeUnitAt(0))) {
      final start = i;
      while (i < text.length && _isWordChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      switch (word) {
        case 'true' || 'false':
          out.write('$_hMagenta$word$_hReset');
        case 'null':
          out.write('$_hRed$word$_hReset');
        case 'if' || 'then' || 'else':
          out.write('$_hMagenta$word$_hReset');
        default:
          out.write(word);
      }
      continue;
    }

    out.write(c);
    i++;
  }

  return out.toString();
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f;

/// Move cursor to the start of the next word.
int _nextWord(List<int> buf, int cursor) {
  while (cursor < buf.length && !_isWordChar(buf[cursor])) {
    cursor++;
  }
  while (cursor < buf.length && _isWordChar(buf[cursor])) {
    cursor++;
  }
  return cursor;
}

/// Move cursor to the start of the previous word.
int _prevWord(List<int> buf, int cursor) {
  while (cursor > 0 && !_isWordChar(buf[cursor - 1])) {
    cursor--;
  }
  while (cursor > 0 && _isWordChar(buf[cursor - 1])) {
    cursor--;
  }
  return cursor;
}

String _commonPrefix(List<String> strings) {
  if (strings.isEmpty) return '';
  var prefix = strings.first;
  for (final s in strings.skip(1)) {
    var i = 0;
    while (i < prefix.length && i < s.length && prefix[i] == s[i]) {
      i++;
    }
    prefix = prefix.substring(0, i);
    if (prefix.isEmpty) return '';
  }
  return prefix;
}
