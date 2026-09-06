/// Consistency between shape inference and evaluation for binary and
/// unary operators.
///
/// For every operator and every pair of concrete operand shapes, the
/// shape [inferShape] reports must agree with what `evaluate` actually
/// returns at runtime:
///
/// - a runtime error must pair with [SAny] (inference cannot prove the
///   operation succeeds), and
/// - a successful evaluation must pair with a shape of the same type
///   family as the returned value.
///
/// Any divergence means either the inference table or the evaluator is
/// wrong about the operator's contract.
library;

import 'package:lambe/lambe.dart';
import 'package:lambe/src/evaluator.dart' show evaluate;
import 'package:lambe/src/parser.dart' show parseQuery;
import 'package:rumil/rumil.dart' show ParseError, Success;
import 'package:test/test.dart';

/// One operand shape paired with a literal expression and a runtime
/// sample value of that shape.
class _Operand {
  final String label;
  final Shape shape;
  final LamExpr expr;
  final Object? sample;
  const _Operand(this.label, this.shape, this.expr, this.sample);
}

const _nullOp = _Operand('null', SNull(), NullLit(), null);
const _boolOp = _Operand('bool', SBool(), BoolLit(true), true);
const _numOp = _Operand('num', SNum(), NumLit(1), 1);
const _stringOp = _Operand('string', SString(), StrLit('a'), 'a');
const _listOp = _Operand(
  'list<num>',
  SList(SNum()),
  ListConstruct([NumLit(1)]),
  <Object?>[1],
);
const _mapOp = _Operand('map', SMap({}), ObjConstruct([]), <String, Object?>{});

final _operands = [_nullOp, _boolOp, _numOp, _stringOp, _listOp, _mapOp];

const _binaryOps = [
  '+',
  '-',
  '*',
  '/',
  '%',
  '==',
  '!=',
  '<',
  '<=',
  '>',
  '>=',
  '&&',
  '||',
];

String _family(Shape shape) => switch (shape) {
  SAny() => 'any',
  SNull() => 'null',
  SBool() => 'bool',
  SNum() => 'number',
  SString() => 'string',
  SList() => 'list',
  SMap() => 'map',
  SOptional() => 'optional',
};

String _runtimeFamily(Object? value) => switch (value) {
  null => 'null',
  bool() => 'bool',
  num() => 'number',
  String() => 'string',
  List<Object?>() => 'list',
  Map<String, Object?>() => 'map',
  _ => 'any',
};

void main() {
  group('binary operator inference matches evaluation', () {
    for (final op in _binaryOps) {
      group("'$op'", () {
        for (final l in _operands) {
          for (final r in _operands) {
            test('${l.label} $op ${r.label}', () {
              final ast = BinaryOp(op, l.expr, r.expr);
              final inferred = inferShape(ast, const SAny());

              Object? result;
              Object? error;
              try {
                result = evaluate(ast, null);
              } catch (e) {
                error = e;
              }

              if (error != null) {
                expect(
                  inferred,
                  const SAny(),
                  reason:
                      '$op on (${l.label}, ${r.label}) throws at runtime '
                      '($error); inference must widen to SAny',
                );
                return;
              }
              final expected = _runtimeFamily(result);
              final actual = _family(inferred);
              expect(
                actual,
                anyOf(expected, 'any'),
                reason:
                    '$op on (${l.label}, ${r.label}) returns '
                    '$expected (${_brief(result)}) at runtime, but '
                    'inference reports $actual',
              );
            });
          }
        }
      });
    }
  });

  group('unary operator inference matches evaluation', () {
    // `-` requires a number, `!` requires a bool; both are checked
    // through the same family contract.
    for (final op in const ['-', '!']) {
      for (final operand in _operands) {
        test('$op on ${operand.label}', () {
          final ast = UnaryOp(op, operand.expr);
          final inferred = inferShape(ast, const SAny());
          Object? result;
          Object? error;
          try {
            result = evaluate(ast, null);
          } catch (e) {
            error = e;
          }
          if (error != null) {
            expect(inferred, const SAny(), reason: '$error');
            return;
          }
          expect(
            _family(inferred),
            anyOf(_runtimeFamily(result), 'any'),
            reason: 'operand ${operand.label}, sample $_brief(result)',
          );
        });
      }
    }
  });

  group('targeted precision cases', () {
    LamExpr parse(String source) => switch (parseQuery(source)) {
      Success<ParseError, LamExpr>(:final value) => value,
      _ => fail('query should parse: $source'),
    };

    test('string + string infers string', () {
      final shape = inferShape(
        parse('.first + .last'),
        const SMap({'first': SString(), 'last': SString()}),
      );
      expect(shape, const SString());
    });

    test('string + number infers string (toString concatenation)', () {
      final shape = inferShape(
        parse('.name + .age'),
        const SMap({'name': SString(), 'age': SNum()}),
      );
      expect(shape, const SString());
    });

    test('list + list joins element shapes', () {
      final shape = inferShape(
        parse('.a + .b'),
        const SMap({'a': SList(SNum()), 'b': SList(SNum())}),
      );
      expect(shape, const SList(SNum()));
    });

    test('list + string stays SAny (runtime type error)', () {
      final shape = inferShape(
        parse('.a + .b'),
        const SMap({'a': SList(SNum()), 'b': SString()}),
      );
      expect(shape, const SAny());
    });

    test('number - number infers number', () {
      final shape = inferShape(
        parse('.price - .discount'),
        const SMap({'price': SNum(), 'discount': SNum()}),
      );
      expect(shape, const SNum());
    });

    test('string - string widens to SAny (runtime error)', () {
      final shape = inferShape(
        parse('.a - .b'),
        const SMap({'a': SString(), 'b': SString()}),
      );
      expect(shape, const SAny());
    });

    test('bool && bool infers bool', () {
      final shape = inferShape(
        parse('.a && .b'),
        const SMap({'a': SBool(), 'b': SBool()}),
      );
      expect(shape, const SBool());
    });

    test('num && num widens to SAny (runtime error)', () {
      final shape = inferShape(
        parse('.a && .b'),
        const SMap({'a': SNum(), 'b': SNum()}),
      );
      expect(shape, const SAny());
    });
  });
}

String _brief(Object? value) {
  final text = '$value';
  return text.length > 40 ? '${text.substring(0, 40)}…' : text;
}
