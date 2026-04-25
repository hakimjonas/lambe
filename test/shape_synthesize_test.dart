/// Tests for [synthesize]: shape-directed query-fragment suggestion.
///
/// Every returned AST fragment, when composed with the original query
/// via [Pipe], must produce a value whose shape the target format
/// accepts.
library;

import 'package:lambe/lambe.dart';
import 'package:lambe/src/evaluator.dart' as evaluator;
import 'package:test/test.dart';

void main() {
  group('synthesize: empty list for already-writable shapes', () {
    test('list → json returns no bridges', () {
      expect(synthesize(const SList(SNum()), OutputFormat.json), isEmpty);
    });

    test('map → toml returns no bridges', () {
      expect(synthesize(const SMap({'a': SNum()}), OutputFormat.toml), isEmpty);
    });

    test('SAny accepts everything: no bridges needed', () {
      for (final fmt in OutputFormat.values) {
        expect(
          synthesize(const SAny(), fmt),
          isEmpty,
          reason: 'SAny should never need a bridge for ${fmt.name}',
        );
      }
    });
  });

  group('synthesize: returns AST for mismatched shapes', () {
    test('list → toml returns at least one bridge', () {
      final bridges = synthesize(const SList(SNum()), OutputFormat.toml);
      expect(bridges, isNotEmpty);
    });

    test('scalar → toml returns at least one bridge', () {
      final bridges = synthesize(const SString(), OutputFormat.toml);
      expect(bridges, isNotEmpty);
    });

    test('map → csv returns at least one bridge', () {
      final bridges = synthesize(const SMap({'a': SNum()}), OutputFormat.csv);
      expect(bridges, isNotEmpty);
    });

    test('scalar → csv returns at least one bridge', () {
      final bridges = synthesize(const SNum(), OutputFormat.csv);
      expect(bridges, isNotEmpty);
    });
  });

  group('synthesize: bridges actually bridge', () {
    // For each (sample value, target format), synthesize the bridges
    // and evaluate `value | bridge` for each one. Every result shape
    // must satisfy the target format's requirement.
    final cases = <(Object?, OutputFormat)>[
      (<Object?>[1, 2, 3], OutputFormat.toml),
      (<Object?>['a', 'b'], OutputFormat.hcl),
      ('hi', OutputFormat.toml),
      (42, OutputFormat.hcl),
      (true, OutputFormat.toml),
      (null, OutputFormat.toml),
      (<String, Object?>{'a': 1, 'b': 2}, OutputFormat.csv),
      (<String, Object?>{'host': 'x'}, OutputFormat.tsv),
      ('single', OutputFormat.csv),
      (7, OutputFormat.tsv),
    ];

    for (final (value, fmt) in cases) {
      test('$value with ${fmt.name} bridges produce writable shapes', () {
        final from = shapeOf(value);
        final bridges = synthesize(from, fmt);
        expect(
          bridges,
          isNotEmpty,
          reason: 'no bridges for $value → ${fmt.name}',
        );
        for (final bridge in bridges) {
          final bridged = evaluator.evaluate(bridge, value);
          final report = canWriteAs(bridged, fmt);
          expect(
            report,
            isA<Writable>(),
            reason: 'bridge failed to satisfy ${fmt.name}: $value → $bridged',
          );
        }
      });
    }
  });

  group('synthesizeWithLabels: returns full records', () {
    test('every entry has display, template, and explanation', () {
      final rems = synthesizeWithLabels(const SList(SNum()), OutputFormat.toml);
      expect(rems, isNotEmpty);
      for (final r in rems) {
        expect(r.display, isNotEmpty);
        expect(r.template, isNotNull);
        expect(r.explanation, isNotEmpty);
        expect(r.label, isNotEmpty);
      }
    });
  });

  group('applyBridge: composes via Pipe', () {
    test('applyBridge wraps user query + bridge into a single AST', () {
      // applyBridge returns a Pipe with the user query on the left
      // and the bridge fragment on the right.
      const user = Field('users');
      const bridge = Identity();
      final composed = applyBridge(user, bridge);
      expect(composed, isA<Pipe>());
      expect((composed as Pipe).input, same(user));
      expect(composed.op, same(bridge));
    });
  });
}
