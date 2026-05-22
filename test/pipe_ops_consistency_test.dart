/// Pins the pipe-op spec table to runtime ground truth.
///
/// For every pipe op × every concrete shape kind, this test runs the
/// evaluator against a representative value and cross-checks the
/// spec's `accepts` predicate: if the evaluator throws a "expected X"
/// type error, the spec must reject the shape; if it succeeds or
/// throws an element-level error (e.g. `sum` on a list of strings),
/// the spec must accept.
///
/// This catches drift between `pipe_ops.dart` and the evaluator: if a
/// contributor changes one without the other, this test fails loudly
/// instead of letting the completer and `--explain` silently lie
/// about what's valid.
library;

import 'package:lambe/lambe.dart';
import 'package:lambe/src/evaluator.dart' as eval_;
import 'package:test/test.dart';

/// Representative value for each concrete shape kind.
///
/// The values are chosen so the evaluator exercises its type check
/// without running into element-level errors: e.g. `sum` needs a list
/// of numbers, not a list of strings, to reach its numeric code path
/// — but `sum` on a map must surface the "expected list" rejection
/// regardless of element type.
final _representatives = <Shape, Object?>{
  const SNull(): null,
  const SBool(): true,
  const SNum(): 42,
  const SString(): 'hello',
  const SList(SAny()): <Object?>[1, 2, 3],
  const SMap(<String, Shape>{}): <String, Object?>{'a': 1, 'b': 2},
};

/// AST node to evaluate for each op. Parameterized ops use a minimal
/// inner expression — `Identity()` where the evaluator just passes
/// through, `BoolLit(true)` for filter predicates, and a string literal
/// for `has` which needs a key. After the pipe-op AST consolidation,
/// every built-in op resolves to a [BuiltinPipeOp]; the only exception
/// is `as(...)`, which keeps a dedicated AST class for its typed
/// argument.
LamExpr _opNode(String name) {
  switch (name) {
    case 'as':
      return const As(OutputFormat.json);
    case 'filter':
    case 'filter_values':
    case 'filter_keys':
      return BuiltinPipeOp(name, const [BoolLit(true)]);
    case 'has':
      return BuiltinPipeOp(name, const [StrLit('a')]);
    case 'map':
    case 'map_values':
    case 'sort_by':
    case 'group_by':
    case 'unique_by':
      return BuiltinPipeOp(name, const [Identity()]);
    case 'sort':
    case 'reverse':
    case 'keys':
    case 'values':
    case 'length':
    case 'first':
    case 'last':
    case 'sum':
    case 'avg':
    case 'min':
    case 'max':
    case 'unique':
    case 'flatten':
    case 'to_entries':
    case 'from_entries':
    case 'to_number':
    case 'type':
    case 'text':
      return BuiltinPipeOp(name, const []);
    default:
      throw StateError('No test AST for op "$name"');
  }
}

/// Runtime outcome of evaluating an op against a representative value
/// of some shape.
enum _Outcome {
  /// Evaluation returned without throwing.
  ok,

  /// Threw a [QueryError] whose message mentions "expected" — a
  /// structural type rejection ("expected list, got map", etc.). This
  /// is exactly what the spec's `accepts` predicate is supposed to
  /// predict.
  typeError,

  /// Threw some other error: element-level failure (sum of strings),
  /// missing key, invalid JSON shape for `as`, etc. These are
  /// orthogonal to structural acceptance — `accepts` is not expected
  /// to catch them.
  otherError,
}

_Outcome _run(String opName, Shape shape) {
  final value = _representatives[shape];
  final ast = _opNode(opName);
  try {
    eval_.evaluate(ast, value);
    return _Outcome.ok;
  } on QueryError catch (e) {
    if (e.message.contains('expected')) return _Outcome.typeError;
    return _Outcome.otherError;
  } catch (_) {
    return _Outcome.otherError;
  }
}

void main() {
  group('Spec acceptance matches evaluator ground truth', () {
    for (final opName in pipeOpNames) {
      for (final shape in _representatives.keys) {
        test('$opName on ${shape.runtimeType}', () {
          final info = pipeOpInfoForName(opName)!;
          final accepts = info.accepts(shape);
          final outcome = _run(opName, shape);
          switch (outcome) {
            case _Outcome.typeError:
              // Runtime rejects this shape structurally; the spec
              // must agree.
              expect(
                accepts,
                isFalse,
                reason:
                    '$opName threw a "expected X" type error on '
                    '${shape.runtimeType}, so the spec should reject '
                    'this shape. Fix: change `accepts` in the '
                    '$opName spec in pipe_ops.dart to exclude '
                    '${shape.runtimeType}.',
              );
            case _Outcome.ok:
              // Runtime accepts and completes; the spec must agree.
              expect(
                accepts,
                isTrue,
                reason:
                    '$opName completed successfully on '
                    '${shape.runtimeType}, so the spec should accept '
                    'this shape. Fix: broaden `accepts` in the '
                    '$opName spec in pipe_ops.dart to include '
                    '${shape.runtimeType}.',
              );
            case _Outcome.otherError:
              // Runtime threw an element-level error, not a type
              // rejection. This is orthogonal to structural
              // acceptance — element-level validation is intentionally
              // outside the spec's scope (see pipe_ops.dart design
              // invariants). No assertion.
              break;
          }
        });
      }
    }
  });

  group('inferShape respects structural failures', () {
    test('flatten on map widens to SAny (not SMap)', () {
      // Previously `inferShape` returned the input unchanged for
      // flatten/sort/reverse/unique, even on shapes the runtime
      // rejects. The spec-backed dispatch now gates `infer` on
      // `accepts`, so incompatible inputs produce SAny.
      final ast = parseAst('.deps | flatten');
      final shape = inferShape(ast, const SMap({'deps': SMap({})}));
      expect(shape, isA<SAny>());
    });

    test('sort on map widens to SAny', () {
      final ast = parseAst('. | sort');
      final shape = inferShape(ast, const SMap({}));
      expect(shape, isA<SAny>());
    });

    test('reverse on string widens to SAny', () {
      final ast = parseAst('. | reverse');
      final shape = inferShape(ast, const SString());
      expect(shape, isA<SAny>());
    });

    test('filter_values on list widens to SAny', () {
      final ast = parseAst('. | filter_values(true)');
      final shape = inferShape(ast, const SList(SNum()));
      expect(shape, isA<SAny>());
    });

    test('length on number widens to SAny', () {
      final ast = parseAst('. | length');
      final shape = inferShape(ast, const SNum());
      expect(shape, isA<SAny>());
    });

    test('length on list still yields SNum (accepted shape)', () {
      final ast = parseAst('. | length');
      final shape = inferShape(ast, const SList(SAny()));
      expect(shape, isA<SNum>());
    });
  });

  group('Spec table is complete', () {
    test('every name in pipeOpNames has a spec', () {
      for (final name in pipeOpNames) {
        expect(
          pipeOpInfoForName(name),
          isNotNull,
          reason: '"$name" is in pipeOpNames but has no spec entry',
        );
      }
    });

    test('every spec accepts SAny', () {
      for (final name in pipeOpNames) {
        final info = pipeOpInfoForName(name)!;
        expect(
          info.accepts(const SAny()),
          isTrue,
          reason:
              '$name.accepts(SAny) must be true — the completer relies '
              'on this to avoid hiding candidates under uncertainty',
        );
      }
    });

    test('BuiltinPipeOp(name) round-trips through pipeOpInfoFor', () {
      // Round-trip: building a [BuiltinPipeOp] with a spec's name and
      // looking it up via pipeOpInfoFor must yield the same spec. This
      // pins the unified dispatch — renaming a spec or breaking the
      // name lookup fails here.
      for (final spec in pipeOpSpecs) {
        if (spec.parseKind == PipeOpParseKind.custom) continue;
        final args =
            spec.parseKind == PipeOpParseKind.oneArg
                ? const [Identity()]
                : const <LamExpr>[];
        final node = BuiltinPipeOp(spec.name, args);
        final resolved = pipeOpInfoFor(node);
        expect(
          resolved?.name,
          spec.name,
          reason:
              'BuiltinPipeOp("${spec.name}", ...) resolved to '
              '"${resolved?.name}" instead. Ensure the spec is '
              'registered in _specsByName.',
        );
      }
    });
  });
}
