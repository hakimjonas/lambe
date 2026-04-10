/// Lambé test matchers.
library;

import 'package:lambe/lambe.dart';
import 'package:matcher/matcher.dart';

/// Matches when the Lambé [expression] evaluates to `true` against the data.
///
/// ```dart
/// expect(data, lamWhere('.users | length > 0'));
/// expect(config, lamWhere('.database | has("host")'));
/// ```
Matcher lamWhere(String expression) => _LamWhereMatcher(expression);

/// Matches when the Lambé [expression] evaluates to [expected] against the
/// data.
///
/// ```dart
/// expect(data, lamEquals('.users[0].name', 'Alice'));
/// expect(config, lamEquals('.database.port', 5432));
/// ```
Matcher lamEquals(String expression, Object? expected) =>
    _LamEqualsMatcher(expression, expected);

/// Matches when the Lambé [expression] evaluates to a value that satisfies
/// [matcher].
///
/// ```dart
/// expect(data, lamMatches('.users | length', greaterThan(0)));
/// expect(data, lamMatches('.users | map(.name)', contains('Alice')));
/// ```
Matcher lamMatches(String expression, Matcher matcher) =>
    _LamMatchesMatcher(expression, matcher);

/// Matches when the Lambé [expression] evaluates to a non-null value.
///
/// ```dart
/// expect(data, lamHas('.users[0].email'));
/// ```
Matcher lamHas(String expression) => _LamHasMatcher(expression);

// ---------------------------------------------------------------------------
// Implementations
// ---------------------------------------------------------------------------

class _LamWhereMatcher extends Matcher {
  final String _expression;
  const _LamWhereMatcher(this._expression);

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    try {
      final result = query(_expression, item);
      return result == true;
    } on Exception catch (e) {
      matchState['error'] = e;
      return false;
    }
  }

  @override
  Description describe(Description description) =>
      description.add('lambe query "$_expression" evaluates to true');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatch,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) {
    if (matchState.containsKey('error')) {
      return mismatch.add('query threw: ${matchState['error']}');
    }
    try {
      final result = query(_expression, item);
      return mismatch.add('evaluated to $result');
    } on Exception catch (e) {
      return mismatch.add('query threw: $e');
    }
  }
}

class _LamEqualsMatcher extends Matcher {
  final String _expression;
  final Object? _expected;
  const _LamEqualsMatcher(this._expression, this._expected);

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    try {
      final result = query(_expression, item);
      matchState['result'] = result;
      return _deepEquals(result, _expected);
    } on Exception catch (e) {
      matchState['error'] = e;
      return false;
    }
  }

  @override
  Description describe(Description description) =>
      description.add('lambe query "$_expression" equals $_expected');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatch,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) {
    if (matchState.containsKey('error')) {
      return mismatch.add('query threw: ${matchState['error']}');
    }
    return mismatch.add('evaluated to ${matchState['result']}');
  }
}

class _LamMatchesMatcher extends Matcher {
  final String _expression;
  final Matcher _inner;
  const _LamMatchesMatcher(this._expression, this._inner);

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    try {
      final result = query(_expression, item);
      matchState['result'] = result;
      return _inner.matches(result, matchState);
    } on Exception catch (e) {
      matchState['error'] = e;
      return false;
    }
  }

  @override
  Description describe(Description description) =>
      description.add('lambe query "$_expression" ').addDescriptionOf(_inner);

  @override
  Description describeMismatch(
    Object? item,
    Description mismatch,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) {
    if (matchState.containsKey('error')) {
      return mismatch.add('query threw: ${matchState['error']}');
    }
    final result = matchState['result'];
    mismatch.add('evaluated to $result which ');
    _inner.describeMismatch(result, mismatch, matchState, verbose);
    return mismatch;
  }
}

class _LamHasMatcher extends Matcher {
  final String _expression;
  const _LamHasMatcher(this._expression);

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    try {
      final result = query(_expression, item);
      return result != null;
    } on Exception catch (e) {
      matchState['error'] = e;
      return false;
    }
  }

  @override
  Description describe(Description description) =>
      description.add('lambe query "$_expression" is non-null');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatch,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) {
    if (matchState.containsKey('error')) {
      return mismatch.add('query threw: ${matchState['error']}');
    }
    return mismatch.add('evaluated to null');
  }
}

/// Deep equality that handles List and Map comparison.
bool _deepEquals(Object? a, Object? b) {
  if (a == b) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return false;
}
