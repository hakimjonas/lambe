/// Test matchers for Lambé queries.
///
/// Provides [Matcher] implementations that let you assert on structured
/// data using Lambé's query DSL in your Dart tests.
///
/// ```dart
/// import 'package:lambe_test/lambe_test.dart';
/// import 'package:test/test.dart';
///
/// test('API response has users', () {
///   expect(response, lamWhere('.users | length > 0'));
/// });
///
/// test('first user is Alice', () {
///   expect(data, lamEquals('.users[0].name', 'Alice'));
/// });
/// ```
library;

export 'src/matchers.dart';
