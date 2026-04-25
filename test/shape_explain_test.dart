/// Tests for the [explain] shape-trace renderer.
///
/// Explain is static analysis: it walks the pipe backbone without
/// evaluating. Properties to lock in:
///   1. Each pipe stage appears as a separate [ExplainStage] with the
///      right inferred shape.
///   2. `as(fmt)` appears as a stage and reports the transformed shape.
///   3. The writability list matches what [canWriteShapeAs] says for the
///      final shape.
library;

import 'package:lambe/lambe.dart';
import 'package:lambe/src/parser.dart' show parseQuery;
import 'package:rumil/rumil.dart' show Success, ParseError;
import 'package:test/test.dart';

LamExpr _parse(String source) {
  final result = parseQuery(source);
  return switch (result) {
    Success<ParseError, LamExpr>(:final value) => value,
    _ => fail('failed to parse: $source'),
  };
}

void main() {
  group('explain: pipe backbone stages', () {
    test('a single expression produces one stage', () {
      final report = explain(_parse('.name'), const SMap({'name': SString()}));
      expect(report.stages, hasLength(1));
      expect(report.stages.first.source, '.name');
      expect(report.stages.first.shape, const SString());
    });

    test('a two-stage pipe produces two stages', () {
      final report = explain(
        _parse('.users | length'),
        const SMap({'users': SList(SString())}),
      );
      expect(report.stages, hasLength(2));
      expect(report.stages[0].source, '.users');
      expect(report.stages[0].shape, const SList(SString()));
      expect(report.stages[1].source, '| length');
      expect(report.stages[1].shape, const SNum());
    });

    test('three-stage pipe with map produces three stages', () {
      final report = explain(
        _parse('.users | map(.name) | length'),
        const SMap({
          'users': SList(SMap({'name': SString(), 'age': SNum()})),
        }),
      );
      expect(report.stages, hasLength(3));
      expect(report.stages[0].shape, isA<SList>());
      expect(report.stages[1].shape, const SList(SString()));
      expect(report.stages[2].shape, const SNum());
    });
  });

  group('explain: writability summary', () {
    test('list<string> result writable as JSON, YAML, CSV, TSV', () {
      final report = explain(
        _parse('.dependencies | keys'),
        const SMap({
          'dependencies': SMap({'a': SString(), 'b': SString()}),
        }),
      );
      expect(
        report.writableAs.map((f) => f.name).toSet(),
        containsAll(<String>['json', 'yaml', 'csv', 'tsv']),
      );
      expect(
        report.notWritableAs.map((f) => f.name).toSet(),
        containsAll(<String>['toml', 'hcl']),
      );
    });

    test('scalar result only writable as JSON and YAML', () {
      final report = explain(_parse('.name'), const SMap({'name': SString()}));
      expect(report.writableAs.map((f) => f.name), <String>['json', 'yaml']);
      expect(
        report.notWritableAs.map((f) => f.name),
        containsAll(<String>['toml', 'csv', 'tsv', 'hcl']),
      );
    });

    test('map result writable as JSON, YAML, TOML, HCL', () {
      final report = explain(
        _parse('.config'),
        const SMap({
          'config': SMap({'host': SString(), 'port': SNum()}),
        }),
      );
      expect(
        report.writableAs.map((f) => f.name).toSet(),
        containsAll(<String>['json', 'yaml', 'toml', 'hcl']),
      );
    });
  });

  group('explain: as() stage reports the bridge shape', () {
    test('list | as(toml) shows the wrapped map', () {
      final report = explain(
        _parse('.users | as(toml)'),
        const SMap({'users': SList(SString())}),
      );
      expect(report.stages, hasLength(2));
      expect(report.stages[1].source, '| as(toml)');
      expect(report.stages[1].shape, const SMap({'items': SList(SString())}));
      expect(
        report.writableAs.map((f) => f.name),
        containsAll(<String>['json', 'yaml', 'toml', 'hcl']),
      );
    });

    test('already-writable input | as(toml) is identity at shape level', () {
      const mapShape = SMap({'host': SString(), 'port': SNum()});
      final report = explain(_parse('as(toml)'), mapShape);
      expect(report.stages.last.shape, mapShape);
    });
  });

  group('explain: SAny input propagates through inference', () {
    test('unknown input yields SAny through field access', () {
      final report = explain(_parse('.users | map(.name)'), const SAny());
      // Field access on an unknown input yields SAny. map(.name) over
      // list<any> also yields list<any>. The final stage is therefore
      // reported as any.
      expect(report.stages.last.shape, const SAny());
    });
  });

  group('renderExplain: text output', () {
    test('includes a Writable-as line when any formats accept', () {
      final report = explain(_parse('.'), const SMap({'a': SNum()}));
      final text = renderExplain(report);
      expect(text, contains('Writable as:'));
      expect(text, contains('json'));
    });

    test('includes a Not-writable line when any formats reject', () {
      final report = explain(_parse('.name'), const SMap({'name': SString()}));
      final text = renderExplain(report);
      expect(text, contains('Not writable as:'));
      expect(text, contains('toml'));
    });
  });
}
