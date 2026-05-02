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

  group('explain: predicate warnings for provably-empty filters', () {
    const userListShape = SMap({
      'users': SList(
        SMap({'name': SString(), 'age': SNum(), 'active': SBool()}),
      ),
    });

    test('filter(.missing) warns: field not in element shape', () {
      final report = explain(
        _parse('.users | filter(.missing)'),
        userListShape,
      );
      expect(report.warnings, hasLength(1));
      final w = report.warnings.first;
      expect(w.stageIndex, 1);
      expect(w.message, contains('.missing does not exist'));
      expect(w.message, contains('element shape'));
      expect(w.message, contains('filter will always be empty'));
    });

    test('filter(.name) warns: field exists but is not boolean', () {
      final report = explain(_parse('.users | filter(.name)'), userListShape);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.first.message, contains('shape string'));
    });

    test('filter(.active) does not warn: field is boolean', () {
      final report = explain(_parse('.users | filter(.active)'), userListShape);
      expect(report.warnings, isEmpty);
    });

    test('filter(.age > 25) does not warn: comparison yields bool', () {
      final report = explain(
        _parse('.users | filter(.age > 25)'),
        userListShape,
      );
      expect(report.warnings, isEmpty);
    });

    test('filter(true) does not warn: literal bool', () {
      final report = explain(_parse('.users | filter(true)'), userListShape);
      expect(report.warnings, isEmpty);
    });

    test('filter on SAny input does not warn: cannot prove anything', () {
      final report = explain(_parse('.users | filter(.missing)'), const SAny());
      expect(report.warnings, isEmpty);
    });

    test('sort_by(.missing) does not warn: only filter* is gated this way', () {
      final report = explain(
        _parse('.users | sort_by(.missing)'),
        userListShape,
      );
      expect(report.warnings, isEmpty);
    });

    test('filter_values warns when predicate is not bool', () {
      final report = explain(
        _parse('.deps | filter_values(.)'),
        const SMap({
          'deps': SMap({'a': SString(), 'b': SString()}),
        }),
      );
      expect(report.warnings, hasLength(1));
      expect(report.warnings.first.message, contains('filter_values'));
    });

    test('filter_values missing-field warning names the value domain', () {
      final report = explain(
        _parse('.deps | filter_values(.missing)'),
        const SMap({
          'deps': SMap({
            'a': SMap({'known': SBool()}),
            'b': SMap({'known': SBool()}),
          }),
        }),
      );
      expect(report.warnings, hasLength(1));
      expect(report.warnings.first.message, contains('value shape'));
    });

    test('filter_keys warns: keys are strings, not bool', () {
      final report = explain(
        _parse('.deps | filter_keys(.)'),
        const SMap({
          'deps': SMap({'a': SString()}),
        }),
      );
      expect(report.warnings, hasLength(1));
      expect(report.warnings.first.message, contains('filter_keys'));
    });

    test('nested missing field .address.missing warns', () {
      final report = explain(
        _parse('.users | filter(.address.missing)'),
        const SMap({
          'users': SList(
            SMap({
              'address': SMap({'city': SString(), 'zip': SString()}),
            }),
          ),
        }),
      );
      expect(report.warnings, hasLength(1));
      expect(
        report.warnings.first.message,
        contains('.address.missing does not exist'),
      );
    });

    test('renderExplain prints warnings between stages and writability', () {
      final report = explain(
        _parse('.users | filter(.missing)'),
        userListShape,
      );
      final text = renderExplain(report);
      expect(text, contains('Warning:'));
      expect(text, contains('filter(.missing)'));
      expect(text, contains('does not exist'));
      expect(text, contains('Writable as:'));

      final warningIdx = text.indexOf('Warning:');
      final writableIdx = text.indexOf('Writable as:');
      final stageIdx = text.indexOf(': list<');
      expect(stageIdx, isNonNegative);
      expect(stageIdx, lessThan(warningIdx));
      expect(warningIdx, lessThan(writableIdx));
    });

    test('no warnings: renderExplain contains no Warning: line', () {
      final report = explain(_parse('.users | filter(.active)'), userListShape);
      final text = renderExplain(report);
      expect(text, isNot(contains('Warning:')));
    });
  });

  group('explain: CellPolicy threads through to writability', () {
    // A list of maps whose cells hold a list. Under refuse (default),
    // csv/tsv are NOT writable; under json, they ARE.
    const nonFlatShape = SList(
      SMap({'name': SString(), 'tags': SList(SString())}),
    );

    test('default (refuse) rejects csv/tsv for non-flat list-of-maps', () {
      final report = explain(_parse('.'), nonFlatShape);
      expect(report.writableAs, isNot(contains(OutputFormat.csv)));
      expect(report.writableAs, isNot(contains(OutputFormat.tsv)));
      expect(report.notWritableAs, contains(OutputFormat.csv));
      expect(report.notWritableAs, contains(OutputFormat.tsv));
    });

    test('json policy accepts csv/tsv for the same shape', () {
      final report = explain(
        _parse('.'),
        nonFlatShape,
        flattenCells: CellPolicy.json,
      );
      expect(report.writableAs, contains(OutputFormat.csv));
      expect(report.writableAs, contains(OutputFormat.tsv));
      expect(report.notWritableAs, isNot(contains(OutputFormat.csv)));
      expect(report.notWritableAs, isNot(contains(OutputFormat.tsv)));
    });

    test('report.flattenCells round-trips the requested policy', () {
      final refuse = explain(_parse('.'), nonFlatShape);
      expect(refuse.flattenCells, CellPolicy.refuse);

      final json = explain(
        _parse('.'),
        nonFlatShape,
        flattenCells: CellPolicy.json,
      );
      expect(json.flattenCells, CellPolicy.json);
    });

    test('renderExplain emits Cell policy footer only when non-default', () {
      final refuse = explain(_parse('.'), nonFlatShape);
      expect(renderExplain(refuse), isNot(contains('Cell policy:')));

      final json = explain(
        _parse('.'),
        nonFlatShape,
        flattenCells: CellPolicy.json,
      );
      expect(renderExplain(json), contains('Cell policy: json'));
    });
  });
}
