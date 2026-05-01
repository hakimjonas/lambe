/// Tests for the apply-a-suggestion flow shared by the CLI, REPL, and
/// MCP server.
///
/// Each test parses a query that produces a shape mismatch, retrieves
/// its [OutputShapeError.suggestions], composes the user's AST with a
/// suggestion via [applyBridge], re-evaluates, and confirms the result
/// is writable in the target format.
library;

import 'dart:convert';

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('parseAst and evaluateAst', () {
    test('parseAst produces a LamExpr that evaluateAst can run', () {
      final ast = parseAst('.name');
      expect(ast, isA<Field>());
      expect(evaluateAst(ast, <String, Object?>{'name': 'alice'}), 'alice');
    });

    test('parseAst throws QueryError on bad syntax', () {
      expect(() => parseAst('| invalid'), throwsA(isA<QueryError>()));
    });

    test('query() still equivalent to parseAst + evaluateAst', () {
      final data = <String, Object?>{'x': 42};
      expect(query('.x', data), evaluateAst(parseAst('.x'), data));
    });
  });

  group('applyBridge end-to-end', () {
    test('scalar to TOML is bridged by suggestion[0]', () {
      final data = <String, Object?>{'name': 'rumil'};
      final userAst = parseAst('.name');
      final result = evaluateAst(userAst, data);
      expect(result, 'rumil');

      final err = _shapeError(() => formatOutput(result, OutputFormat.toml));
      expect(err.suggestions, isNotEmpty);
      final chosen = err.suggestions.first;

      final bridged = applyBridge(userAst, chosen.template);
      final newResult = evaluateAst(bridged, data);

      expect(canWriteAs(newResult, OutputFormat.toml), isA<Writable>());
      expect(() => formatOutput(newResult, OutputFormat.toml), returnsNormally);
    });

    test(
      'map to CSV is bridged by to_entries template, displayed as as(csv)',
      () {
        final data = <String, Object?>{
          'deps': <String, Object?>{'a': '1.0', 'b': '2.0'},
        };
        final userAst = parseAst('.deps');
        final result = evaluateAst(userAst, data);

        final err = _shapeError(() => formatOutput(result, OutputFormat.csv));
        final bridged = applyBridge(userAst, err.suggestions.first.template);
        final newResult = evaluateAst(bridged, data);
        expect(canWriteAs(newResult, OutputFormat.csv), isA<Writable>());

        // Display surfaces the intent-level `as(csv)` form; the
        // template is still the raw `to_entries` AST, so the
        // applyBridge() call above composes the same query a
        // pre-0.7.1 caller would have produced.
        expect(err.suggestions.first.display, 'as(csv)');
        expect(err.suggestions.first.explanation, contains('to_entries'));
      },
    );

    test('list to TOML is bridged by {items: .}', () {
      final data = <String, Object?>{
        'tags': <Object?>['a', 'b', 'c'],
      };
      final userAst = parseAst('.tags');
      final result = evaluateAst(userAst, data);

      final err = _shapeError(() => formatOutput(result, OutputFormat.toml));
      final bridged = applyBridge(userAst, err.suggestions.first.template);
      final newResult = evaluateAst(bridged, data);
      expect(canWriteAs(newResult, OutputFormat.toml), isA<Writable>());
      expect((newResult as Map)['items'], <Object?>['a', 'b', 'c']);
    });
  });

  group('MCP shape-error payload', () {
    test('payload contains expected keys and applicable suggestions', () {
      final err = _shapeError(() => formatOutput('scalar', OutputFormat.toml));
      final payload = <String, Object?>{
        'error': 'output_shape_mismatch',
        'message': err.message,
        'format': err.format.name,
        'got_shape': renderShape(err.got),
        'original_expression': '.name',
        'suggestions': [
          for (var i = 0; i < err.suggestions.length; i++)
            {
              'id': i + 1,
              'label': err.suggestions[i].label,
              'template_text': err.suggestions[i].display,
              'apply_as': '.name | ${err.suggestions[i].display}',
              'explanation': err.suggestions[i].explanation,
            },
        ],
      };
      final encoded = jsonEncode(payload);
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded['error'], 'output_shape_mismatch');
      expect(decoded['format'], 'toml');
      expect(decoded['got_shape'], 'string');
      expect(decoded['original_expression'], '.name');
      final suggestions = decoded['suggestions'] as List<Object?>;
      expect(suggestions, isNotEmpty);
      for (final s in suggestions.cast<Map<String, Object?>>()) {
        expect(s.containsKey('id'), isTrue);
        expect(s.containsKey('label'), isTrue);
        expect(s.containsKey('template_text'), isTrue);
        expect(s.containsKey('apply_as'), isTrue);
        expect(s.containsKey('explanation'), isTrue);
        expect(() => parseAst(s['apply_as']! as String), returnsNormally);
      }
    });

    test('apply_as query runs and is writable', () {
      final data = <String, Object?>{'name': 'rumil'};
      final err = _shapeError(
        () => formatOutput(
          evaluateAst(parseAst('.name'), data),
          OutputFormat.toml,
        ),
      );
      final applyAs = '.name | ${err.suggestions.first.display}';
      final result = query(applyAs, data);
      expect(canWriteAs(result, OutputFormat.toml), isA<Writable>());
    });
  });
}

OutputShapeError _shapeError(void Function() action) {
  try {
    action();
  } on OutputShapeError catch (e) {
    return e;
  }
  fail('expected OutputShapeError');
}
