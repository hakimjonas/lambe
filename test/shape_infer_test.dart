/// Tests for the [inferShape] interpreter.
///
/// Each test asserts either a concrete expected shape or [SAny] for
/// cases where the output shape cannot be determined without runtime
/// values. Where possible, the inferred shape is cross-checked against
/// the shape of the actually-evaluated result; any divergence indicates
/// a bug in either the expectation or the interpreter.
library;

import 'package:lambe/lambe.dart';
import 'package:lambe/src/parser.dart' show parseQuery;
import 'package:rumil/rumil.dart' show Success, ParseError;
import 'package:test/test.dart';

LamExpr _parse(String source) {
  final result = parseQuery(source);
  return switch (result) {
    Success<ParseError, LamExpr>(:final value) => value,
    _ => fail('query should parse: $source (got ${result.runtimeType})'),
  };
}

Shape _inferFor(String source, Shape input) =>
    inferShape(_parse(source), input);

void main() {
  group('inferShape: identity and literals', () {
    test('identity returns input unchanged', () {
      expect(_inferFor('.', const SNum()), const SNum());
      expect(_inferFor('.', const SList(SString())), const SList(SString()));
    });

    test('literals have fixed shape', () {
      expect(_inferFor('42', const SAny()), const SNum());
      expect(_inferFor('"hello"', const SAny()), const SString());
      expect(_inferFor('true', const SAny()), const SBool());
      expect(_inferFor('null', const SAny()), const SNull());
    });
  });

  group('inferShape: field access', () {
    test('.name on a known map returns the field shape', () {
      const input = SMap({'name': SString(), 'age': SNum()});
      expect(_inferFor('.name', input), const SString());
      expect(_inferFor('.age', input), const SNum());
    });

    test('.missing on a known map returns SAny', () {
      const input = SMap({'name': SString()});
      expect(_inferFor('.missing', input), const SAny());
    });

    test('.name on a non-map context returns SAny', () {
      expect(_inferFor('.name', const SList(SNum())), const SAny());
    });

    test('nested field access chains through maps', () {
      const input = SMap({
        'server': SMap({'host': SString(), 'port': SNum()}),
      });
      expect(_inferFor('.server.host', input), const SString());
      expect(_inferFor('.server.port', input), const SNum());
    });
  });

  group('inferShape: pipe composition', () {
    test('pipe threads output of lhs into rhs', () {
      const input = SMap({'users': SList(SString())});
      expect(_inferFor('.users | length', input), const SNum());
    });

    test('pipe with map preserves list-of-transformed', () {
      const input = SMap({
        'users': SList(SMap({'name': SString(), 'age': SNum()})),
      });
      expect(_inferFor('.users | map(.name)', input), const SList(SString()));
    });
  });

  group('inferShape: structural ops', () {
    test('keys on a known map returns list<string>', () {
      const input = SMap({'a': SNum(), 'b': SString()});
      expect(_inferFor('keys', input), const SList(SString()));
    });

    test('keys on a list returns list<number>', () {
      expect(_inferFor('keys', const SList(SNum())), const SList(SNum()));
    });

    test('values on a homogeneous map returns list of that element', () {
      const input = SMap({'a': SNum(), 'b': SNum()});
      expect(_inferFor('values', input), const SList(SNum()));
    });

    test('values on a heterogeneous map returns list<any>', () {
      const input = SMap({'a': SNum(), 'b': SString()});
      expect(_inferFor('values', input), const SList(SAny()));
    });

    test('length always returns number', () {
      expect(_inferFor('length', const SList(SNum())), const SNum());
      expect(_inferFor('length', const SMap({'a': SNum()})), const SNum());
      expect(_inferFor('length', const SString()), const SNum());
    });

    test('first and last return the element shape', () {
      expect(_inferFor('first', const SList(SString())), const SString());
      expect(_inferFor('last', const SList(SNum())), const SNum());
    });

    test('to_entries on a map returns list<{key, value}>', () {
      const input = SMap({'a': SNum(), 'b': SNum()});
      expect(
        _inferFor('to_entries', input),
        const SList(SMap({'key': SString(), 'value': SNum()})),
      );
    });

    test('from_entries on a list returns an SMap with unknown fields', () {
      const input = SList(SMap({'key': SString(), 'value': SNum()}));
      final shape = _inferFor('from_entries', input);
      expect(shape, isA<SMap>());
      expect((shape as SMap).fields, isEmpty);
    });

    test('type always returns string', () {
      expect(_inferFor('type', const SList(SNum())), const SString());
    });

    test('has always returns bool', () {
      expect(
        _inferFor('has("name")', const SMap({'name': SString()})),
        const SBool(),
      );
    });

    test('sum and avg return number', () {
      expect(_inferFor('sum', const SList(SNum())), const SNum());
      expect(_inferFor('avg', const SList(SNum())), const SNum());
    });

    test('sort, reverse, unique preserve input shape', () {
      const listOfMaps = SList(SMap({'name': SString(), 'age': SNum()}));
      expect(_inferFor('sort', listOfMaps), listOfMaps);
      expect(_inferFor('reverse', listOfMaps), listOfMaps);
      expect(_inferFor('unique', listOfMaps), listOfMaps);
    });

    test('to_number returns number', () {
      expect(_inferFor('to_number', const SString()), const SNum());
    });
  });

  group('inferShape: lambda ops', () {
    test('map(expr) produces list of inferred element shape', () {
      const input = SList(SMap({'name': SString(), 'age': SNum()}));
      expect(_inferFor('map(.name)', input), const SList(SString()));
      expect(
        _inferFor('map({n: .name, years: .age})', input),
        const SList(SMap({'n': SString(), 'years': SNum()})),
      );
    });

    test('filter preserves the input shape', () {
      const input = SList(SMap({'name': SString(), 'active': SBool()}));
      expect(_inferFor('filter(.active)', input), input);
    });

    test('sort_by and unique_by preserve input shape', () {
      const input = SList(SMap({'age': SNum()}));
      expect(_inferFor('sort_by(.age)', input), input);
      expect(_inferFor('unique_by(.age)', input), input);
    });

    test('group_by produces list<{key, values: list<elem>}>', () {
      const elem = SMap({'role': SString(), 'name': SString()});
      const input = SList(elem);
      expect(
        inferShape(_parse('group_by(.role)'), input),
        const SList(SMap({'key': SAny(), 'values': SList(elem)})),
      );
    });

    test('map_values preserves keys, transforms values', () {
      const input = SMap({'a': SNum(), 'b': SNum()});
      expect(
        _inferFor('map_values(. * 2)', input),
        const SMap({'a': SNum(), 'b': SNum()}),
      );
    });
  });

  group('inferShape: object construction', () {
    test('{key: expr} builds a map with per-key inferred shapes', () {
      const input = SMap({'price': SNum(), 'qty': SNum(), 'name': SString()});
      expect(
        _inferFor('{label: .name, total: .price * .qty}', input),
        const SMap({'label': SString(), 'total': SNum()}),
      );
    });

    test('shorthand {name} becomes {name: .name}', () {
      const input = SMap({'name': SString(), 'age': SNum()});
      expect(_inferFor('{name}', input), const SMap({'name': SString()}));
    });
  });

  group('inferShape: operators', () {
    test('arithmetic returns number', () {
      expect(_inferFor('1 + 2', const SAny()), const SNum());
      expect(_inferFor('.a * .b', const SAny()), const SNum());
    });

    test('comparison returns bool', () {
      expect(_inferFor('.age > 30', const SAny()), const SBool());
      expect(_inferFor('.a == .b', const SAny()), const SBool());
    });

    test('unary minus and not', () {
      expect(_inferFor('-.n', const SAny()), const SNum());
      expect(_inferFor('!.flag', const SAny()), const SBool());
    });

    test('string addition infers string (L1)', () {
      const input = SMap({'first': SString(), 'last': SString()});
      expect(_inferFor('.first + .last', input), const SString());
    });

    test('mixed string addition infers string (L1)', () {
      const input = SMap({'name': SString(), 'age': SNum()});
      expect(_inferFor('.name + .age', input), const SString());
    });

    test('list addition joins element shapes (L1)', () {
      const input = SMap({'a': SList(SNum()), 'b': SList(SNum())});
      expect(_inferFor('.a + .b', input), const SList(SNum()));
    });

    test('list mixed with string addition widens to SAny (L1)', () {
      const input = SMap({'a': SList(SNum()), 'b': SString()});
      expect(_inferFor('.a + .b', input), const SAny());
    });
  });

  group('inferShape: string indexing and slicing (F1)', () {
    test('slicing a string infers string', () {
      expect(_inferFor('.name[:3]', const SMap({'name': SString()})),
          const SString());
      expect(_inferFor('.name[1:3]', const SMap({'name': SString()})),
          const SString());
      expect(_inferFor('"hello"[2:]', const SAny()), const SString());
    });

    test('single-character indexing on a string infers optional string', () {
      expect(_inferFor('.name[0]', const SMap({'name': SString()})),
          SOptional(const SString()));
      expect(_inferFor('"hello"[-1]', const SAny()),
          SOptional(const SString()));
    });

    test('string indexing with a non-number index widens to SAny', () {
      expect(
        _inferFor('.name["a"]', const SMap({'name': SString()})),
        const SAny(),
      );
    });

    test('slicing an optional string keeps optionality', () {
      final input = SMap({'name': SOptional(const SString())});
      expect(_inferFor('.name[:3]', input), SOptional(const SString()));
    });

    test('slicing other scalars widens to SAny', () {
      expect(_inferFor('.n[:3]', const SMap({'n': SNum()})), const SAny());
    });
  });

  group('inferShape: bracketed map indexing (F2)', () {
    test('literal key on a known map resolves the field shape', () {
      expect(
        _inferFor('.["x-axis"]', const SMap({'x-axis': SNum()})),
        const SNum(),
      );
      expect(
        _inferFor('.users[0]["name"]', const SMap({'users': SList(SMap({'name': SString()}))})),
        const SString(),
      );
    });

    test('missing literal key infers SNull (runtime null read)', () {
      expect(
        _inferFor('.["missing"]', const SMap({'name': SString()})),
        const SNull(),
      );
    });

    test('non-literal key on a map widens to SAny', () {
      expect(
        _inferFor('.[.key]', const SMap({'name': SString(), 'key': SString()})),
        const SAny(),
      );
    });
  });

  group('inferShape: alternative on optional shapes (F3)', () {
    test('optional left joins with concrete right to the inner shape', () {
      final input = SMap({'email': SOptional(const SString()), 'name': const SString()});
      expect(_inferFor('.email // .name', input), const SString());
      expect(_inferFor('.email // "unknown"', input), const SString());
    });

    test('optional on both sides keeps optionality', () {
      final input = SMap({
        'email': SOptional(const SString()),
        'phone': SOptional(const SString()),
      });
      expect(
        _inferFor('.email // .phone', input),
        SOptional(const SString()),
      );
    });

    test('equal concrete shapes still pass through', () {
      const input = SMap({'a': SNum(), 'b': SNum()});
      expect(_inferFor('.a // .b', input), const SNum());
    });

    test('null left falls through to right shape', () {
      expect(_inferFor('null // 42', const SAny()), const SNum());
    });
  });

  group('inferShape: string interpolation', () {
    test('interpolation always returns string', () {
      expect(
        _inferFor(r'"Hello \(.name)"', const SMap({'name': SString()})),
        const SString(),
      );
    });
  });

  group('inferShape: conditionals', () {
    test('matching branch shapes propagate', () {
      const input = SMap({'flag': SBool(), 'a': SNum(), 'b': SNum()});
      expect(_inferFor('if .flag then .a else .b', input), const SNum());
    });

    test('diverging branch shapes widen to SAny', () {
      const input = SMap({'flag': SBool(), 'a': SNum(), 'b': SString()});
      expect(_inferFor('if .flag then .a else .b', input), const SAny());
    });
  });

  group('inferShape vs shapeOf(evaluated result)', () {
    // Run the query against real data, infer the query's shape against
    // the input's shape, and assert the two agree structurally.
    test('.users | map(.name) on typical data', () {
      final data = <String, Object?>{
        'users': [
          <String, Object?>{'name': 'a', 'age': 1},
          <String, Object?>{'name': 'b', 'age': 2},
        ],
      };
      final ast = _parse('.users | map(.name)');
      final inferred = inferShape(ast, shapeOf(data));
      final actual = shapeOf(query('.users | map(.name)', data));
      expect(inferred, actual);
      expect(inferred, const SList(SString()));
    });

    test('.users | filter(.active) | map({name, age}) agrees', () {
      final data = <String, Object?>{
        'users': [
          <String, Object?>{'name': 'a', 'age': 1, 'active': true},
          <String, Object?>{'name': 'b', 'age': 2, 'active': false},
        ],
      };
      final ast = _parse('.users | filter(.active) | map({name, age})');
      final inferred = inferShape(ast, shapeOf(data));
      final actual = shapeOf(
        query('.users | filter(.active) | map({name, age})', data),
      );
      expect(inferred, actual);
    });

    test('.dependencies | keys agrees', () {
      final data = <String, Object?>{
        'dependencies': <String, Object?>{'a': '1.0', 'b': '2.0'},
      };
      final ast = _parse('.dependencies | keys');
      final inferred = inferShape(ast, shapeOf(data));
      final actual = shapeOf(query('.dependencies | keys', data));
      expect(inferred, actual);
      expect(inferred, const SList(SString()));
    });
  });
}
