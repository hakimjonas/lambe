/// Tests for the Shape ADT and [shapeOf] inference.
///
/// Shape inference must be structural, cheap, and stable: the same value
/// always yields the same shape, heterogeneous lists collapse to
/// `list<any>`, and nested structures recurse predictably.
library;

import 'dart:convert';

import 'package:lambe/src/shape/shape.dart';
import 'package:test/test.dart';

void main() {
  group('shapeOf: scalars', () {
    test('null', () {
      expect(shapeOf(null), const SNull());
    });

    test('bool', () {
      expect(shapeOf(true), const SBool());
      expect(shapeOf(false), const SBool());
    });

    test('int and double unify as number', () {
      expect(shapeOf(42), const SNum());
      expect(shapeOf(3.14), const SNum());
    });

    test('string', () {
      expect(shapeOf('hello'), const SString());
    });
  });

  group('shapeOf: lists', () {
    test('empty list has SAny element', () {
      expect(shapeOf(<Object?>[]), const SList(SAny()));
    });

    test('homogeneous list of numbers', () {
      expect(shapeOf(<Object?>[1, 2, 3]), const SList(SNum()));
    });

    test('homogeneous list of strings', () {
      expect(shapeOf(<Object?>['a', 'b']), const SList(SString()));
    });

    test('heterogeneous list collapses to SAny element', () {
      expect(shapeOf(<Object?>[1, 'x', true]), const SList(SAny()));
    });

    test('nested list of lists', () {
      expect(
        shapeOf(<Object?>[
          <Object?>[1, 2],
          <Object?>[3, 4],
        ]),
        const SList(SList(SNum())),
      );
    });

    test('list of maps with identical fields', () {
      final value = <Object?>[
        <String, Object?>{'name': 'a', 'age': 1},
        <String, Object?>{'name': 'b', 'age': 2},
      ];
      expect(
        shapeOf(value),
        const SList(SMap({'name': SString(), 'age': SNum()})),
      );
    });

    test('sampling: long homogeneous list still reports the element shape', () {
      final value = List<Object?>.generate(1000, (i) => i);
      expect(shapeOf(value), const SList(SNum()));
    });

    test('sampling: heterogeneity within the sample window is detected', () {
      final value = <Object?>[1, 2, 3, 'x', 5];
      expect(shapeOf(value), const SList(SAny()));
    });
  });

  group('shapeOf: maps', () {
    test('empty map', () {
      expect(shapeOf(<String, Object?>{}), const SMap(<String, Shape>{}));
    });

    test('flat map of scalars', () {
      expect(
        shapeOf(<String, Object?>{'name': 'a', 'age': 1, 'ok': true}),
        const SMap({'name': SString(), 'age': SNum(), 'ok': SBool()}),
      );
    });

    test('nested map', () {
      expect(
        shapeOf(<String, Object?>{
          'server': <String, Object?>{'host': 'x', 'port': 80},
        }),
        const SMap({
          'server': SMap({'host': SString(), 'port': SNum()}),
        }),
      );
    });

    test('map preserves insertion order', () {
      final inferred =
          shapeOf(<String, Object?>{'z': 1, 'a': 2, 'm': 3}) as SMap;
      expect(inferred.fields.keys.toList(), <String>['z', 'a', 'm']);
    });
  });

  group('Shape equality and rendering', () {
    test('scalar shapes are equal to themselves', () {
      expect(const SNum() == const SNum(), isTrue);
      expect(const SNum() == const SString(), isFalse);
    });

    test('list shapes compare element', () {
      expect(const SList(SNum()) == const SList(SNum()), isTrue);
      expect(const SList(SNum()) == const SList(SString()), isFalse);
    });

    test('map shapes compare fields by key and value', () {
      expect(const SMap({'a': SNum()}) == const SMap({'a': SNum()}), isTrue);
      expect(
        const SMap({'a': SNum()}) == const SMap({'a': SString()}),
        isFalse,
      );
      expect(
        const SMap({'a': SNum()}) == const SMap({'a': SNum(), 'b': SBool()}),
        isFalse,
      );
    });

    test('renderShape produces readable form', () {
      expect(renderShape(const SNum()), 'number');
      expect(renderShape(const SList(SString())), 'list<string>');
      expect(
        renderShape(const SMap({'a': SNum(), 'b': SString()})),
        'map<a: number, b: string>',
      );
      expect(renderShape(const SMap(<String, Shape>{})), 'map<>');
      expect(renderShape(const SList(SAny())), 'list<any>');
    });
  });

  group('shapeToJson: structured serialization', () {
    test('scalars encode as {kind: ...}', () {
      expect(shapeToJson(const SAny()), {'kind': 'any'});
      expect(shapeToJson(const SNull()), {'kind': 'null'});
      expect(shapeToJson(const SBool()), {'kind': 'bool'});
      expect(shapeToJson(const SNum()), {'kind': 'number'});
      expect(shapeToJson(const SString()), {'kind': 'string'});
    });

    test('list encodes with nested element shape', () {
      expect(shapeToJson(const SList(SNum())), {
        'kind': 'list',
        'element': {'kind': 'number'},
      });
    });

    test('map encodes with nested fields', () {
      expect(shapeToJson(const SMap({'a': SNum(), 'b': SString()})), {
        'kind': 'map',
        'fields': {
          'a': {'kind': 'number'},
          'b': {'kind': 'string'},
        },
      });
    });

    test('nested list-of-maps round-trips the shape tree', () {
      const shape = SList(SMap({'name': SString(), 'tags': SList(SString())}));
      expect(shapeToJson(shape), {
        'kind': 'list',
        'element': {
          'kind': 'map',
          'fields': {
            'name': {'kind': 'string'},
            'tags': {
              'kind': 'list',
              'element': {'kind': 'string'},
            },
          },
        },
      });
    });

    test('empty map has empty fields', () {
      expect(shapeToJson(const SMap(<String, Shape>{})), {
        'kind': 'map',
        'fields': <String, Object?>{},
      });
    });

    test('empty list has SAny element', () {
      expect(shapeToJson(const SList(SAny())), {
        'kind': 'list',
        'element': {'kind': 'any'},
      });
    });

    test('result serializes to JSON without error', () {
      const shape = SMap({'a': SList(SNum())});
      final json = jsonEncode(shapeToJson(shape));
      expect(json, contains('"kind":"map"'));
      expect(json, contains('"kind":"list"'));
      expect(json, contains('"kind":"number"'));
    });
  });
}
