import 'package:lambe_test/lambe_test.dart';
import 'package:test/test.dart';

void main() {
  final data = {
    'users': [
      {'name': 'Alice', 'age': 25, 'active': true},
      {'name': 'Bob', 'age': 35, 'active': false},
    ],
    'version': '1.0.0',
  };

  group('lamWhere', () {
    test('passes when expression is true', () {
      expect(data, lamWhere('.users | length > 0'));
    });

    test('fails when expression is false', () {
      expect(
        () => expect(data, lamWhere('.users | length > 10')),
        throwsA(isA<TestFailure>()),
      );
    });

    test('with compound predicate', () {
      expect(data, lamWhere('.version != "0.0.0"'));
    });

    test('with pipeline', () {
      expect(data, lamWhere('.users | filter(.active) | length > 0'));
    });
  });

  group('lamEquals', () {
    test('matches scalar value', () {
      expect(data, lamEquals('.version', '1.0.0'));
    });

    test('matches nested value', () {
      expect(data, lamEquals('.users[0].name', 'Alice'));
    });

    test('matches list', () {
      expect(data, lamEquals('.users | map(.name)', ['Alice', 'Bob']));
    });

    test('fails on mismatch', () {
      expect(
        () => expect(data, lamEquals('.version', '2.0.0')),
        throwsA(isA<TestFailure>()),
      );
    });

    test('matches null', () {
      expect(data, lamEquals('.missing', null));
    });

    test('matches number', () {
      expect(data, lamEquals('.users[0].age', 25));
    });
  });

  group('lamMatches', () {
    test('with greaterThan', () {
      expect(data, lamMatches('.users | length', greaterThan(0)));
    });

    test('with contains', () {
      expect(data, lamMatches('.users | map(.name)', contains('Alice')));
    });

    test('with isA', () {
      expect(data, lamMatches('.users', isA<List<Object?>>()));
    });

    test('fails when inner matcher fails', () {
      expect(
        () => expect(data, lamMatches('.users | length', greaterThan(100))),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('lamHas', () {
    test('passes when field exists', () {
      expect(data, lamHas('.version'));
    });

    test('passes when nested field exists', () {
      expect(data, lamHas('.users[0].name'));
    });

    test('fails when field is null', () {
      expect(
        () => expect(data, lamHas('.missing')),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('real-world patterns', () {
    test('API response validation', () {
      final response = {
        'status': 200,
        'data': {
          'items': [
            {'id': 1, 'name': 'Widget'},
          ],
        },
        'errors': <Object?>[],
      };
      expect(response, lamWhere('.status == 200'));
      expect(response, lamEquals('.errors | length', 0));
      expect(response, lamHas('.data.items[0].name'));
    });

    test('config validation', () {
      final config = {
        'database': {'host': 'localhost', 'port': 5432},
        'debug': false,
      };
      expect(config, lamHas('.database.host'));
      expect(config, lamEquals('.database.port', 5432));
      expect(config, lamWhere('.debug == false'));
    });
  });
}
