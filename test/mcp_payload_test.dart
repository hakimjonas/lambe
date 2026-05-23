/// Tests for [renderMcpShapeErrorPayload]: the JSON payload shape an
/// MCP agent receives when the query result's shape is incompatible
/// with the requested output format.
///
/// The contract this pins:
///   1. Payload is valid JSON with the documented top-level keys.
///   2. Suggestions carry 1-based ids and include both the template
///      text and the fully-composed `apply_as` query.
///   3. Hints carry structured `parameter`/`value` pairs, not the CLI
///      or REPL syntax (which do not apply to an agent).
///   4. Both lists are empty when no guidance exists, not missing.
library;

import 'dart:convert';

import 'package:lambe/lambe.dart';
import 'package:test/test.dart';

void main() {
  group('renderMcpShapeErrorPayload: top-level shape', () {
    test('payload parses as JSON and carries all documented keys', () {
      // A scalar root against TOML: has suggestions, no hints.
      final report = canWriteAs('hello', OutputFormat.toml) as NotWritable;
      final error = OutputShapeError(report);

      final json = renderMcpShapeErrorPayload(error, '.name');
      final payload = jsonDecode(json) as Map<String, Object?>;

      expect(payload['error'], 'output_shape_mismatch');
      expect(payload['message'], contains('TOML'));
      expect(payload['format'], 'toml');
      expect(payload['got_shape'], 'string');
      expect(payload['original_expression'], '.name');
      expect(payload['suggestions'], isA<List<Object?>>());
      expect(payload['hints'], isA<List<Object?>>());
    });
  });

  group('renderMcpShapeErrorPayload: suggestions', () {
    test(
      'each suggestion has id, label, template_text, apply_as, explanation',
      () {
        final report =
            canWriteAs(<Object?>[1, 2, 3], OutputFormat.toml) as NotWritable;
        final error = OutputShapeError(report);
        final json = renderMcpShapeErrorPayload(error, '.items');
        final payload = jsonDecode(json) as Map<String, Object?>;
        final suggestions = payload['suggestions'] as List;

        expect(suggestions, isNotEmpty);
        final first = suggestions.first as Map<String, Object?>;
        expect(first['id'], 1);
        expect(first['label'], isA<String>());
        expect(first['template_text'], isA<String>());
        expect(first['apply_as'], startsWith('.items | '));
        expect(first['explanation'], isA<String>());
      },
    );

    test('ids are 1-based and increment across suggestions', () {
      final report =
          canWriteAs(<Object?>[1, 2, 3], OutputFormat.toml) as NotWritable;
      final error = OutputShapeError(report);
      final json = renderMcpShapeErrorPayload(error, '.items');
      final payload = jsonDecode(json) as Map<String, Object?>;
      final suggestions = payload['suggestions'] as List;

      for (var i = 0; i < suggestions.length; i++) {
        final s = suggestions[i] as Map<String, Object?>;
        expect(s['id'], i + 1);
      }
    });
  });

  group('renderMcpShapeErrorPayload: hints', () {
    test(
      'csv + non-scalar cells produces a structured hint, no CLI/REPL noise',
      () {
        final v = <Object?>[
          {
            'k': <Object?>[1, 2],
          },
        ];
        final report = canWriteAs(v, OutputFormat.csv) as NotWritable;
        final error = OutputShapeError(report);
        final json = renderMcpShapeErrorPayload(error, '.rows');
        final payload = jsonDecode(json) as Map<String, Object?>;
        final hints = payload['hints'] as List;

        expect(hints, hasLength(1));
        final hint = hints.first as Map<String, Object?>;
        expect(hint['label'], 'Flatten non-scalar cells');
        expect(hint['parameter'], 'flatten_cells');
        expect(hint['value'], 'json');
        expect(hint['explanation'], isA<String>());

        // The payload MUST NOT leak CLI or REPL syntax: an agent can
        // only invoke MCP tool parameters, so those forms would be
        // misleading noise in the structured response.
        expect(hint.keys, isNot(contains('cliFlag')));
        expect(hint.keys, isNot(contains('replCommand')));
        expect(json, isNot(contains('--flatten-cells')));
        expect(json, isNot(contains(':flatten-cells')));
      },
    );

    test('toml mismatch has empty hints (no relevant parameter)', () {
      final report =
          canWriteAs(<Object?>[1, 2, 3], OutputFormat.toml) as NotWritable;
      final error = OutputShapeError(report);
      final json = renderMcpShapeErrorPayload(error, '.items');
      final payload = jsonDecode(json) as Map<String, Object?>;
      expect(payload['hints'], isEmpty);
      // Key must still be present; missing hints would make agents
      // guess whether the field is optional or absent.
      expect(payload.containsKey('hints'), isTrue);
    });
  });
}
