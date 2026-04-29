// Manual probe of complete(). Prints the input, cursor, returned
// start, and returned candidates for each case.
//
// Run: dart run tool/probe_completer.dart

import 'package:lambe/src/completer.dart';
import 'package:lambe/src/parser.dart' as parser_;
import 'package:rumil/rumil.dart';

void main() {
  final sampleData = <String, Object?>{
    'users': <Object?>[
      <String, Object?>{'name': 'Alice', 'age': 25, 'active': true},
    ],
    'config': <String, Object?>{
      'database': <String, Object?>{'host': 'localhost'},
    },
    'version': '1.0.0',
  };

  final cases = <(String, String)>[
    ('baseline: .', '.'),
    ('baseline: .users', '.users'),
    ('baseline: .users |', '.users |'),
    ('baseline: .users | ', '.users | '),
    ('trailing space after identity', '. '),
    ('trailing space after field', '.users '),
    ('trailing space after access', '.config.database '),
    ('trailing tab after field', '.users\t'),
    ('trailing newline after field', '.users\n'),
    ('multiple spaces after field', '.users   '),
    ('mixed ws after field', '.users \t '),
    ('inside filter, trailing space', '.users | filter(.age )'),
    ('inside map, trailing space', '.users | map(.name )'),
    ('trailing space after partial op', '.users | fil '),
    ('empty string', ''),
    ('just a dot, cursor 0', '.'),
  ];

  for (final (label, text) in cases) {
    final cursor = text.length;
    final r = complete(text, cursor, sampleData);
    final escText = text.replaceAll('\t', r'\t').replaceAll('\n', r'\n');
    print(label);
    print('  input=<$escText> length=${text.length} cursor=$cursor');
    print('  start=${r.start}');
    print('  candidates=${r.candidates}');
    print('');
  }

  // Special: cursor in the middle, not at the end.
  print('cursor mid-token');
  final mid = complete('.users', 3, sampleData);
  print('  input=<.users> cursor=3');
  print('  start=${mid.start}');
  print('  candidates=${mid.candidates}');

  // Focused repro for the .users | fil oddity.
  print('');
  print('=== focused: .users | fil variants ===');
  for (final input in [
    '.users | fil',
    '.users | fil ',
    '.users | filt',
    '.users | fi',
    '.users | f',
    '.users | ',
  ]) {
    final r = complete(input, input.length, sampleData);
    final esc = input.replaceAll(' ', '·');
    print(
      '  input=<$esc> len=${input.length} start=${r.start} '
      'candidates=${r.candidates.length > 5 ? "${r.candidates.take(5).toList()}... (${r.candidates.length})" : r.candidates}',
    );
  }

  // Trace `parsePartial` for selected inputs. `consumed` is how much
  // of `before` the parser treated as a valid prefix; what follows is
  // the "remainder" that the completer then classifies.
  print('');
  print('=== parser trace ===');
  for (final input in [
    '.users |',
    '.users | ',
    '.users | fil',
    '.users | fil ',
    '.users | filter',
    '.users | filter(.age)',
    '.users | sort',
    '.users | sort_by',
    '.users',
    '.',
  ]) {
    final r = parser_.parsePartial(input);
    final consumed = switch (r) {
      Success(:final consumed) => consumed,
      Partial(:final consumed) => consumed,
      Failure() => -1,
    };
    final kind = r.runtimeType.toString().split('<').first;
    final esc = input.replaceAll(' ', '·');
    print(
      '  input=<$esc> length=${input.length} consumed=$consumed kind=$kind',
    );
  }
}
