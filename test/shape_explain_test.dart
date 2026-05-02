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

import 'dart:convert';

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

  group('explain: runtime-rejection warnings', () {
    test('filter on a map shape is flagged', () {
      const shape = SMap({'a': SNum()});
      final report = explain(_parse('. | filter(.x)'), shape);
      final rejection =
          report.warnings
              .where((w) => w.kind == WarningKind.runtimeRejection)
              .toList();
      expect(rejection, hasLength(1));
      expect(rejection.first.message, contains('filter rejects'));
      expect(rejection.first.message, contains('throw at runtime'));
    });

    test('sum on a map shape is flagged', () {
      const shape = SMap({'a': SNum()});
      final report = explain(_parse('. | sum'), shape);
      final rejection =
          report.warnings
              .where((w) => w.kind == WarningKind.runtimeRejection)
              .toList();
      expect(rejection, hasLength(1));
      expect(rejection.first.message, contains('sum rejects'));
    });

    test('SAny input does not trigger rejection (cannot prove)', () {
      final report = explain(_parse('. | filter(.x)'), const SAny());
      final rejection = report.warnings.where(
        (w) => w.kind == WarningKind.runtimeRejection,
      );
      expect(rejection, isEmpty);
    });

    test('compatible input (list for filter) does not trigger', () {
      const shape = SList(SMap({'active': SBool()}));
      final report = explain(_parse('. | filter(.active)'), shape);
      final rejection = report.warnings.where(
        (w) => w.kind == WarningKind.runtimeRejection,
      );
      expect(rejection, isEmpty);
    });

    test(
      'after a rejection, downstream stages see SAny and do not double-warn',
      () {
        // `. | filter(.a) | sort` starting from a map: filter rejects
        // (warning emitted), inferShape widens ctx to SAny, sort then
        // accepts any shape and should NOT emit its own rejection.
        const shape = SMap({'a': SNum()});
        final report = explain(_parse('. | filter(.a) | sort'), shape);
        final rejections =
            report.warnings
                .where((w) => w.kind == WarningKind.runtimeRejection)
                .toList();
        expect(rejections, hasLength(1));
        expect(rejections.first.stageIndex, 1);
        expect(rejections.first.message, contains('filter rejects'));
      },
    );
  });

  group('explain: trivial-result warnings (opt-in)', () {
    const userListShape = SList(SMap({'name': SString(), 'age': SNum()}));

    test('sort_by(.missing) flagged when includeTrivial: true', () {
      final report = explain(
        _parse('. | sort_by(.missing)'),
        userListShape,
        includeTrivial: true,
      );
      final trivial =
          report.warnings
              .where((w) => w.kind == WarningKind.trivialResult)
              .toList();
      expect(trivial, hasLength(1));
      expect(trivial.first.message, contains('sort_by'));
      expect(trivial.first.message, contains('.missing'));
    });

    test('group_by(.missing) flagged when includeTrivial: true', () {
      final report = explain(
        _parse('. | group_by(.missing)'),
        userListShape,
        includeTrivial: true,
      );
      final trivial =
          report.warnings
              .where((w) => w.kind == WarningKind.trivialResult)
              .toList();
      expect(trivial, hasLength(1));
      expect(trivial.first.message, contains('group_by'));
    });

    test('map(.missing) flagged when includeTrivial: true', () {
      final report = explain(
        _parse('. | map(.missing)'),
        userListShape,
        includeTrivial: true,
      );
      final trivial =
          report.warnings
              .where((w) => w.kind == WarningKind.trivialResult)
              .toList();
      expect(trivial, hasLength(1));
      expect(trivial.first.message, contains('map'));
    });

    test('NOT flagged by default (includeTrivial: false)', () {
      final report = explain(_parse('. | sort_by(.missing)'), userListShape);
      final trivial = report.warnings.where(
        (w) => w.kind == WarningKind.trivialResult,
      );
      expect(trivial, isEmpty);
    });

    test('existing field does not produce a trivial warning', () {
      final report = explain(
        _parse('. | sort_by(.age)'),
        userListShape,
        includeTrivial: true,
      );
      final trivial = report.warnings.where(
        (w) => w.kind == WarningKind.trivialResult,
      );
      expect(trivial, isEmpty);
    });

    test('SAny element shape cannot prove missing; no trivial warning', () {
      final report = explain(
        _parse('. | sort_by(.missing)'),
        const SList(SAny()),
        includeTrivial: true,
      );
      final trivial = report.warnings.where(
        (w) => w.kind == WarningKind.trivialResult,
      );
      expect(trivial, isEmpty);
    });
  });

  group('renderExplainJson: machine-readable output', () {
    test('valid JSON with documented top-level keys', () {
      final report = explain(
        _parse('.users | map(.name)'),
        const SMap({
          'users': SList(SMap({'name': SString()})),
        }),
      );
      final json = renderExplainJson(report);
      final parsed = jsonDecode(json) as Map<String, Object?>;
      expect(
        parsed.keys,
        containsAll([
          'stages',
          'warnings',
          'writable_as',
          'not_writable_as',
          'flatten_cells',
        ]),
      );
    });

    test('stages carry source and shape strings', () {
      final report = explain(
        _parse('.users | length'),
        const SMap({'users': SList(SString())}),
      );
      final parsed =
          jsonDecode(renderExplainJson(report)) as Map<String, Object?>;
      final stages = parsed['stages'] as List;
      expect(stages, hasLength(2));
      final first = stages.first as Map<String, Object?>;
      expect(first['source'], '.users');
      // Structured shape: {kind: list, element: {kind: string}}.
      expect(first['shape'], isA<Map<String, Object?>>());
      final shape = first['shape'] as Map<String, Object?>;
      expect(shape['kind'], 'list');
      final element = shape['element'] as Map<String, Object?>;
      expect(element['kind'], 'string');
    });

    test('warnings carry stage_index, kind (snake_case), and message', () {
      const shape = SMap({'a': SNum()});
      final report = explain(_parse('. | filter(.x)'), shape);
      final parsed =
          jsonDecode(renderExplainJson(report)) as Map<String, Object?>;
      final warnings = parsed['warnings'] as List;
      expect(warnings, isNotEmpty);
      final w = warnings.first as Map<String, Object?>;
      expect(w.keys, containsAll(['stage_index', 'kind', 'message']));
      expect(w['kind'], 'runtime_rejection');
    });

    test('kind uses snake_case for all three categories', () {
      // empty_filter
      const listShape = SList(SMap({'a': SNum()}));
      final emptyReport = explain(_parse('. | filter(.b)'), listShape);
      final emptyKinds = [
        for (final w
            in (jsonDecode(renderExplainJson(emptyReport))
                    as Map<String, Object?>)['warnings']
                as List)
          (w as Map<String, Object?>)['kind'],
      ];
      expect(emptyKinds, contains('empty_filter'));

      // trivial_result
      final trivialReport = explain(
        _parse('. | sort_by(.missing)'),
        listShape,
        includeTrivial: true,
      );
      final trivialKinds = [
        for (final w
            in (jsonDecode(renderExplainJson(trivialReport))
                    as Map<String, Object?>)['warnings']
                as List)
          (w as Map<String, Object?>)['kind'],
      ];
      expect(trivialKinds, contains('trivial_result'));
    });

    test('writable_as / not_writable_as are name lists', () {
      final report = explain(_parse('.'), const SList(SString()));
      final parsed =
          jsonDecode(renderExplainJson(report)) as Map<String, Object?>;
      expect(parsed['writable_as'], contains('json'));
      expect(parsed['not_writable_as'], contains('toml'));
    });

    test('flatten_cells is the policy name string', () {
      final report = explain(
        _parse('.'),
        const SList(SMap({'a': SList(SNum())})),
        flattenCells: CellPolicy.json,
      );
      final parsed =
          jsonDecode(renderExplainJson(report)) as Map<String, Object?>;
      expect(parsed['flatten_cells'], 'json');
    });
  });

  group('SOptional: propagates through inference and analyzers', () {
    test('field access on map with optional field returns optional', () {
      final mapShape = SMap({'age': SOptional(const SNum())});
      final report = explain(_parse('.age'), mapShape);
      expect(report.stages.last.shape, SOptional(const SNum()));
    });

    test('field access on optional map wraps result in optional', () {
      final mapShape = SOptional(const SMap({'name': SString()}));
      final report = explain(_parse('.name'), mapShape);
      expect(report.stages.last.shape, SOptional(const SString()));
    });

    test('filter accepts optional list (acceptance unwraps)', () {
      final listShape = SOptional(const SList(SNum()));
      final report = explain(_parse('. | filter(. > 0)'), listShape);
      // Rejection analyzer should NOT fire: optional unwraps for
      // acceptance, and the inner SList is accepted.
      final rejection = report.warnings.where(
        (w) => w.kind == WarningKind.runtimeRejection,
      );
      expect(rejection, isEmpty);
    });

    test('missing-field check walks through optional wrappers', () {
      final shape = SOptional(
        const SMap({
          'users': SList(SMap({'name': SString()})),
        }),
      );
      // `.users | filter(.missing)` on an optional-outer map: the
      // walk should see users is a list of maps with only `name`.
      final report = explain(_parse('.users | filter(.missing)'), shape);
      final emptyFilter =
          report.warnings
              .where((w) => w.kind == WarningKind.emptyFilter)
              .toList();
      expect(emptyFilter, hasLength(1));
      expect(emptyFilter.first.message, contains('.missing'));
    });

    test('optional bool predicate is not provably-empty', () {
      // An optional bool is "bool or absent" — not provably non-boolean.
      // The empty-filter check should NOT fire.
      final listShape = SList(SMap({'active': SOptional(const SBool())}));
      final report = explain(_parse('. | filter(.active)'), listShape);
      final emptyFilter = report.warnings.where(
        (w) => w.kind == WarningKind.emptyFilter,
      );
      expect(emptyFilter, isEmpty);
    });

    test('root optional map rejects TOML (MustBeMap does NOT unwrap)', () {
      // Root optional means "might be absent entirely" — TOML cannot
      // serialize that without a materialization step.
      final shape = SOptional(const SMap({'a': SNum()}));
      final report = explain(_parse('.'), shape);
      expect(report.notWritableAs, contains(OutputFormat.toml));
    });

    test('nested optionality collapses through factory', () {
      // Verified via the factory, but also check that inference never
      // produces stacked optionals via field-through-optional.
      final shape = SOptional(SMap({'nested': SOptional(const SNum())}));
      final report = explain(_parse('.nested'), shape);
      // Two optional steps (outer map, inner field) should collapse
      // to a single SOptional<SNum>.
      expect(report.stages.last.shape, SOptional(const SNum()));
    });

    test('shapeToJson round-trips optional', () {
      final shape = SOptional(const SNum());
      expect(shapeToJson(shape), {
        'kind': 'optional',
        'inner': {'kind': 'number'},
      });
    });
  });
}
