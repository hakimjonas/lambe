import 'package:lambe/lambe.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

LamExpr _parse(String input) {
  final result = parse(input);
  return switch (result) {
    Success<ParseError, LamExpr>(:final value) => value,
    Partial<ParseError, LamExpr>(:final value) => value,
    Failure<ParseError, LamExpr>() => fail('Parse failed: ${result.errors}'),
  };
}

void main() {
  group('Atoms', () {
    test('identity (.)', () {
      final expr = _parse('.');
      expect(expr, isA<Identity>());
    });

    test('field (.name)', () {
      final expr = _parse('.name');
      expect(expr, isA<Field>());
      expect((expr as Field).name, 'name');
    });

    test('field with underscore', () {
      final expr = _parse('.user_name');
      expect(expr, isA<Field>());
      expect((expr as Field).name, 'user_name');
    });

    test('integer', () {
      final expr = _parse('42');
      expect(expr, isA<NumLit>());
      expect((expr as NumLit).value, 42);
    });

    test('float', () {
      final expr = _parse('3.14');
      expect(expr, isA<NumLit>());
      expect((expr as NumLit).value, 3.14);
    });

    test('negative number', () {
      final expr = _parse('-5');
      expect(expr, isA<UnaryOp>());
      final unary = expr as UnaryOp;
      expect(unary.op, '-');
      expect((unary.operand as NumLit).value, 5);
    });

    test('string literal', () {
      final expr = _parse('"hello"');
      expect(expr, isA<StrLit>());
      expect((expr as StrLit).value, 'hello');
    });

    test('true', () {
      final expr = _parse('true');
      expect(expr, isA<BoolLit>());
      expect((expr as BoolLit).value, true);
    });

    test('false', () {
      final expr = _parse('false');
      expect(expr, isA<BoolLit>());
      expect((expr as BoolLit).value, false);
    });

    test('null', () {
      final expr = _parse('null');
      expect(expr, isA<NullLit>());
    });

    test('parenthesized expression', () {
      final expr = _parse('(42)');
      expect(expr, isA<NumLit>());
      expect((expr as NumLit).value, 42);
    });
  });

  group('Left-recursive chains (Warth showcase)', () {
    test('.users.name → Access(Field, name)', () {
      final expr = _parse('.users.name');
      expect(expr, isA<Access>());
      final access = expr as Access;
      expect(access.field, 'name');
      expect(access.target, isA<Field>());
      expect((access.target as Field).name, 'users');
    });

    test('.a.b.c → Access(Access(Field(a), b), c)', () {
      final expr = _parse('.a.b.c');
      expect(expr, isA<Access>());
      final c = expr as Access;
      expect(c.field, 'c');
      expect(c.target, isA<Access>());
      final b = c.target as Access;
      expect(b.field, 'b');
      expect(b.target, isA<Field>());
      expect((b.target as Field).name, 'a');
    });

    test('.users[0] → Index(Field(users), 0)', () {
      final expr = _parse('.users[0]');
      expect(expr, isA<Index>());
      final idx = expr as Index;
      expect(idx.target, isA<Field>());
      expect((idx.target as Field).name, 'users');
      expect(idx.index, isA<NumLit>());
      expect((idx.index as NumLit).value, 0);
    });

    test('.users[0].name → Access(Index(Field(users), 0), name)', () {
      final expr = _parse('.users[0].name');
      expect(expr, isA<Access>());
      final access = expr as Access;
      expect(access.field, 'name');
      expect(access.target, isA<Index>());
      final idx = access.target as Index;
      expect((idx.target as Field).name, 'users');
      expect((idx.index as NumLit).value, 0);
    });

    test('.data[0][1] → Index(Index(Field(data), 0), 1)', () {
      final expr = _parse('.data[0][1]');
      expect(expr, isA<Index>());
      final outer = expr as Index;
      expect((outer.index as NumLit).value, 1);
      expect(outer.target, isA<Index>());
      final inner = outer.target as Index;
      expect((inner.index as NumLit).value, 0);
      expect((inner.target as Field).name, 'data');
    });
  });

  group('Binary operators', () {
    test('arithmetic precedence: .a + .b * .c', () {
      final expr = _parse('.a + .b * .c');
      expect(expr, isA<BinaryOp>());
      final add = expr as BinaryOp;
      expect(add.op, '+');
      expect(add.left, isA<Field>());
      expect(add.right, isA<BinaryOp>());
      expect((add.right as BinaryOp).op, '*');
    });

    test('comparison: .age > 30', () {
      final expr = _parse('.age > 30');
      expect(expr, isA<BinaryOp>());
      final cmp = expr as BinaryOp;
      expect(cmp.op, '>');
      expect(cmp.left, isA<Field>());
      expect(cmp.right, isA<NumLit>());
    });

    test('>= before >', () {
      final expr = _parse('.age >= 18');
      expect(expr, isA<BinaryOp>());
      expect((expr as BinaryOp).op, '>=');
    });

    test('logic: .active && .age >= 18', () {
      final expr = _parse('.active && .age >= 18');
      expect(expr, isA<BinaryOp>());
      final and = expr as BinaryOp;
      expect(and.op, '&&');
      expect(and.left, isA<Field>());
      expect(and.right, isA<BinaryOp>());
      expect((and.right as BinaryOp).op, '>=');
    });

    test('unary: !.active', () {
      final expr = _parse('!.active');
      expect(expr, isA<UnaryOp>());
      final unary = expr as UnaryOp;
      expect(unary.op, '!');
      expect(unary.operand, isA<Field>());
    });

    test('|| not confused with pipeline |', () {
      final expr = _parse('.a || .b');
      expect(expr, isA<BinaryOp>());
      expect((expr as BinaryOp).op, '||');
    });
  });

  group('Pipeline operations', () {
    test('.users | filter(.age > 30)', () {
      final expr = _parse('.users | filter(.age > 30)');
      expect(expr, isA<Pipe>());
      final pipe = expr as Pipe;
      expect(pipe.input, isA<Field>());
      expect(pipe.op, isA<FilterOp>());
      final pred = (pipe.op as FilterOp).predicate;
      expect(pred, isA<BinaryOp>());
      expect((pred as BinaryOp).op, '>');
    });

    test('.users | map(.name)', () {
      final expr = _parse('.users | map(.name)');
      expect(expr, isA<Pipe>());
      final pipe = expr as Pipe;
      expect(pipe.op, isA<MapOp>());
      expect((pipe.op as MapOp).transform, isA<Field>());
    });

    test('chained: .users | filter(.active) | map(.name) | sort', () {
      final expr = _parse('.users | filter(.active) | map(.name) | sort');
      expect(expr, isA<Pipe>());
      final sort = expr as Pipe;
      expect(sort.op, isA<SortOp>());
      expect(sort.input, isA<Pipe>());
      final map = sort.input as Pipe;
      expect(map.op, isA<MapOp>());
      expect(map.input, isA<Pipe>());
      final filter = map.input as Pipe;
      expect(filter.op, isA<FilterOp>());
      expect(filter.input, isA<Field>());
    });

    test('. | keys', () {
      final expr = _parse('. | keys');
      expect(expr, isA<Pipe>());
      final pipe = expr as Pipe;
      expect(pipe.input, isA<Identity>());
      expect(pipe.op, isA<KeysOp>());
    });

    test('. | values', () {
      final expr = _parse('. | values');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<ValuesOp>());
    });

    test('. | length', () {
      final expr = _parse('. | length');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<LengthOp>());
    });

    test('. | sort', () {
      final expr = _parse('. | sort');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<SortOp>());
    });

    test('. | reverse', () {
      final expr = _parse('. | reverse');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<ReverseOp>());
    });

    test('. | first', () {
      final expr = _parse('. | first');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<FirstOp>());
    });

    test('. | last', () {
      final expr = _parse('. | last');
      expect(expr, isA<Pipe>());
      expect((expr as Pipe).op, isA<LastOp>());
    });
  });

  group('Edge cases', () {
    test('zero', () {
      final expr = _parse('0');
      expect((expr as NumLit).value, 0);
    });

    test('0.5', () {
      final expr = _parse('0.5');
      expect((expr as NumLit).value, 0.5);
    });

    test('empty string literal', () {
      final expr = _parse('""');
      expect(expr, isA<StrLit>());
      expect((expr as StrLit).value, '');
    });

    test('deeply nested chains: .a.b.c.d.e', () {
      final expr = _parse('.a.b.c.d.e');
      expect(expr, isA<Access>());
      final e = expr as Access;
      expect(e.field, 'e');
      final d = e.target as Access;
      expect(d.field, 'd');
      final c = d.target as Access;
      expect(c.field, 'c');
      final b = c.target as Access;
      expect(b.field, 'b');
      expect((b.target as Field).name, 'a');
    });

    test('mixed chains: .users[0].addresses[1].city', () {
      final expr = _parse('.users[0].addresses[1].city');
      expect(expr, isA<Access>());
      final city = expr as Access;
      expect(city.field, 'city');
      final idx1 = city.target as Index;
      expect((idx1.index as NumLit).value, 1);
      final addresses = idx1.target as Access;
      expect(addresses.field, 'addresses');
      final idx0 = addresses.target as Index;
      expect((idx0.index as NumLit).value, 0);
      expect((idx0.target as Field).name, 'users');
    });

    test('nested pipeline in filter predicate', () {
      final expr = _parse('.users | filter(.tags | length > 0)');
      expect(expr, isA<Pipe>());
      final pipe = expr as Pipe;
      expect(pipe.op, isA<FilterOp>());
      final pred = (pipe.op as FilterOp).predicate;
      expect(pred, isA<BinaryOp>());
      final gt = pred as BinaryOp;
      expect(gt.op, '>');
      expect(gt.left, isA<Pipe>());
      final inner = gt.left as Pipe;
      expect(inner.op, isA<LengthOp>());
      expect(inner.input, isA<Field>());
    });

    test('pipeline keyword as field name: .filter', () {
      final expr = _parse('.filter');
      expect(expr, isA<Field>());
      expect((expr as Field).name, 'filter');
    });

    test('pipeline keyword as access: .data.sort', () {
      final expr = _parse('.data.sort');
      expect(expr, isA<Access>());
      final access = expr as Access;
      expect(access.field, 'sort');
      expect((access.target as Field).name, 'data');
    });

    test('map indexing with string key: .data["key"]', () {
      final expr = _parse('.data["key"]');
      expect(expr, isA<Index>());
      final idx = expr as Index;
      expect(idx.index, isA<StrLit>());
      expect((idx.index as StrLit).value, 'key');
    });

    test('whitespace tolerance', () {
      final expr = _parse('  .users  |  filter( .age > 30 )  ');
      expect(expr, isA<Pipe>());
    });

    test('double negation: --5', () {
      final expr = _parse('--5');
      expect(expr, isA<UnaryOp>());
      final outer = expr as UnaryOp;
      expect(outer.op, '-');
      expect(outer.operand, isA<UnaryOp>());
      final inner = outer.operand as UnaryOp;
      expect(inner.op, '-');
      expect((inner.operand as NumLit).value, 5);
    });
  });

  group('Parse errors', () {
    test('invalid input returns Failure', () {
      final result = parse('|||');
      expect(result, isA<Failure<ParseError, LamExpr>>());
    });

    test('empty input returns Failure', () {
      final result = parse('');
      expect(result, isA<Failure<ParseError, LamExpr>>());
    });

    test('whitespace only returns Failure', () {
      final result = parse('   ');
      expect(result, isA<Failure<ParseError, LamExpr>>());
    });

    test('unclosed bracket returns Partial (recovered)', () {
      final result = parse('.users[0');
      expect(result, isA<Partial<ParseError, LamExpr>>());
    });

    test('unclosed string returns Partial (recovered)', () {
      final result = parse('"hello');
      expect(result, isA<Partial<ParseError, LamExpr>>());
    });
  });

  // -------------------------------------------------------------------------
  // Recovery / continuation detection
  //
  // parse() returns Partial for incomplete expressions (missing closing
  // bracket), Success for complete expressions, and Failure for broken
  // syntax. The REPL uses `parse(text) is Partial` for multi-line
  // continuation detection.
  // -------------------------------------------------------------------------

  group('Recovery (Partial for continuation)', () {
    group('unclosed parens → Partial', () {
      test('missing ) in filter', () {
        expect(parse('.x | filter(.a'), isA<Partial<ParseError, LamExpr>>());
      });

      test('missing ) in map', () {
        expect(parse('.x | map(.a'), isA<Partial<ParseError, LamExpr>>());
      });

      test('missing ) in sort_by', () {
        expect(parse('.x | sort_by(.a'), isA<Partial<ParseError, LamExpr>>());
      });

      test('missing ) in group_by', () {
        expect(parse('.x | group_by(.a'), isA<Partial<ParseError, LamExpr>>());
      });

      test('missing ) in parenthesized expression', () {
        expect(parse('(.a + .b'), isA<Partial<ParseError, LamExpr>>());
      });

      test('empty filter( with no expression', () {
        expect(parse('.x | filter('), isA<Partial<ParseError, LamExpr>>());
      });
    });

    group('unclosed brackets → Partial', () {
      test('missing ] in index', () {
        expect(parse('.users[0'), isA<Partial<ParseError, LamExpr>>());
      });

      test('missing ] in slice', () {
        expect(parse('.users[1:'), isA<Partial<ParseError, LamExpr>>());
      });
    });

    group('unclosed braces → Partial', () {
      test('missing } in object construction', () {
        expect(parse('.x | map({name'), isA<Partial<ParseError, LamExpr>>());
      });

      test('missing } with explicit entry', () {
        expect(
          parse('.x | map({total: .price'),
          isA<Partial<ParseError, LamExpr>>(),
        );
      });
    });

    group('complete expressions → Success', () {
      test('simple field', () {
        expect(parse('.name'), isA<Success<ParseError, LamExpr>>());
      });

      test('pipeline with complete filter', () {
        expect(
          parse('.x | filter(.a > 1)'),
          isA<Success<ParseError, LamExpr>>(),
        );
      });

      test('index with closing bracket', () {
        expect(parse('.users[0]'), isA<Success<ParseError, LamExpr>>());
      });

      test('object construction', () {
        expect(
          parse('.x | map({name, age: .a})'),
          isA<Success<ParseError, LamExpr>>(),
        );
      });
    });

    group('unclosed strings → Partial', () {
      test('missing closing quote', () {
        expect(parse('"hello'), isA<Partial<ParseError, LamExpr>>());
      });

      test('unclosed interpolation inside string', () {
        expect(parse(r'"name: \(.na'), isA<Partial<ParseError, LamExpr>>());
      });
    });

    group('syntax errors → Failure', () {
      test('garbage after expression', () {
        expect(parse('.users +++ .name'), isA<Failure<ParseError, LamExpr>>());
      });

      test('empty input', () {
        expect(parse(''), isA<Failure<ParseError, LamExpr>>());
      });
    });
  });
}
