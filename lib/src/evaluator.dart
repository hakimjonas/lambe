/// Query evaluator. Walks the AST over `Object?` JSON values.
library;

import 'package:rumil_expressions/rumil_expressions.dart'
    show applyBinaryOp, applyUnaryOp, asBool, compareValues, typeName;

import 'ast.dart';
import 'errors.dart';

/// Evaluate a [LamExpr] AST against a JSON [ctx] value.
///
/// The context flows through the expression: `.` returns it, `.field` accesses
/// a field on it, pipeline operations transform it.
///
/// **Null propagation:** navigation operations (field access, indexing,
/// pipeline) propagate `null` - if the target is absent, the result is absent.
/// Computation operations (arithmetic, comparison, conditionals) throw on
/// `null` - using a missing value in a calculation is a type error.
Object? evaluate(LamExpr expr, Object? ctx) => switch (expr) {
  Identity() => ctx,
  Field(:final name) => _field(ctx, name),
  NumLit(:final value) => value,
  StrLit(:final value) => value,
  BoolLit(:final value) => value,
  NullLit() => null,
  Access(:final target, :final field) => _field(evaluate(target, ctx), field),
  Index(:final target, :final index) => _index(
    evaluate(target, ctx),
    evaluate(index, ctx),
  ),
  Pipe(:final input, :final op) => _pipe(evaluate(input, ctx), op),
  UnaryOp(:final op, :final operand) => applyUnaryOp(
    op,
    evaluate(operand, ctx),
  ),
  BinaryOp(:final op, :final left, :final right) => applyBinaryOp(
    op,
    evaluate(left, ctx),
    evaluate(right, ctx),
  ),
  ObjConstruct(:final entries) => {
    for (final (key, valExpr) in entries) key: evaluate(valExpr, ctx),
  },
  Conditional(:final condition, :final then_, :final else_) =>
    asBool(evaluate(condition, ctx), 'if')
        ? evaluate(then_, ctx)
        : evaluate(else_, ctx),
  StringInterp(:final parts) => _interpolate(parts, ctx),
  Slice(:final target, :final start, :final end) => _slice(
    evaluate(target, ctx),
    start,
    end,
    ctx,
  ),
  FilterOp(:final predicate) => _filter(ctx, predicate),
  MapOp(:final transform) => _mapOp(ctx, transform),
  SortOp() => _sort(ctx),
  ReverseOp() => _reverse(ctx),
  KeysOp() => _keys(ctx),
  ValuesOp() => _values(ctx),
  LengthOp() => _length(ctx),
  FirstOp() => _first(ctx),
  LastOp() => _last(ctx),
  SumOp() => _sum(ctx),
  AvgOp() => _avg(ctx),
  MinOp() => _min(ctx),
  MaxOp() => _max(ctx),
  SortByOp(:final key) => _sortBy(ctx, key),
  GroupByOp(:final key) => _groupBy(ctx, key),
  UniqueOp() => _unique(ctx),
  UniqueByOp(:final key) => _uniqueBy(ctx, key),
  FlattenOp() => _flatten(ctx),
  FilterValuesOp(:final predicate) => _filterValues(ctx, predicate),
  MapValuesOp(:final transform) => _mapValues(ctx, transform),
  FilterKeysOp(:final predicate) => _filterKeys(ctx, predicate),
  HasOp(:final key) => _has(ctx, key),
  ToEntriesOp() => _toEntries(ctx),
  FromEntriesOp() => _fromEntries(ctx),
};

Object? _field(Object? target, String name) {
  if (target == null) return null;
  if (target is Map<String, Object?>) return target[name];
  throw QueryError('Cannot access .$name on ${typeName(target)}');
}

Object? _index(Object? target, Object? idx) {
  if (target == null) return null;
  if (target is List<Object?>) {
    if (idx is num) {
      final i = idx.toInt();
      final resolved = i < 0 ? target.length + i : i;
      if (resolved < 0 || resolved >= target.length) return null;
      return target[resolved];
    }
    throw QueryError('Cannot index list with ${typeName(idx)}');
  }
  if (target is Map<String, Object?>) {
    if (idx is String) return target[idx];
    throw QueryError('Cannot index map with ${typeName(idx)}');
  }
  throw QueryError('Cannot index ${typeName(target)}');
}

Object? _pipe(Object? input, LamExpr op) {
  if (input == null) return null;
  return evaluate(op, input);
}

List<Object?> _filter(Object? input, LamExpr predicate) {
  final list = _asList(input, 'filter');
  return [
    for (final item in list)
      if (evaluate(predicate, item) == true) item,
  ];
}

List<Object?> _mapOp(Object? input, LamExpr transform) {
  final list = _asList(input, 'map');
  return [for (final item in list) evaluate(transform, item)];
}

List<Object?> _sort(Object? input) {
  final list = List<Object?>.of(_asList(input, 'sort'));
  list.sort(compareValues);
  return list;
}

List<Object?> _reverse(Object? input) =>
    List<Object?>.of(_asList(input, 'reverse').reversed);

List<Object?> _keys(Object? input) {
  if (input is Map<String, Object?>) return input.keys.toList();
  if (input is List<Object?>) {
    return [for (var i = 0; i < input.length; i++) i];
  }
  throw QueryError('keys: expected map or list, got ${typeName(input)}');
}

List<Object?> _values(Object? input) {
  if (input is Map<String, Object?>) return input.values.toList();
  if (input is List<Object?>) return input;
  throw QueryError('values: expected map or list, got ${typeName(input)}');
}

int _length(Object? input) {
  if (input is List<Object?>) return input.length;
  if (input is Map<String, Object?>) return input.length;
  if (input is String) return input.length;
  throw QueryError(
    'length: expected list, map, or string, got ${typeName(input)}',
  );
}

Object? _first(Object? input) {
  final list = _asList(input, 'first');
  return list.isEmpty ? null : list.first;
}

Object? _last(Object? input) {
  final list = _asList(input, 'last');
  return list.isEmpty ? null : list.last;
}

num _sum(Object? input) {
  final list = _asList(input, 'sum');
  num total = 0;
  for (final item in list) {
    if (item is! num) {
      throw QueryError('sum: expected number, got ${typeName(item)}');
    }
    total += item;
  }
  return total;
}

double _avg(Object? input) {
  final list = _asList(input, 'avg');
  if (list.isEmpty) throw const QueryError('avg: empty list');
  return _sum(list).toDouble() / list.length;
}

Object? _min(Object? input) {
  final list = _asList(input, 'min');
  if (list.isEmpty) throw const QueryError('min: empty list');
  var best = list.first;
  for (var i = 1; i < list.length; i++) {
    if (compareValues(list[i], best) < 0) best = list[i];
  }
  return best;
}

Object? _max(Object? input) {
  final list = _asList(input, 'max');
  if (list.isEmpty) throw const QueryError('max: empty list');
  var best = list.first;
  for (var i = 1; i < list.length; i++) {
    if (compareValues(list[i], best) > 0) best = list[i];
  }
  return best;
}

List<Object?> _sortBy(Object? input, LamExpr key) {
  final list = List<Object?>.of(_asList(input, 'sort_by'));
  list.sort((a, b) => compareValues(evaluate(key, a), evaluate(key, b)));
  return list;
}

List<Map<String, Object?>> _groupBy(Object? input, LamExpr key) {
  final list = _asList(input, 'group_by');
  final groups = <Object?, List<Object?>>{};
  for (final item in list) {
    final k = evaluate(key, item);
    (groups[k] ??= []).add(item);
  }
  return [
    for (final MapEntry(:key, :value) in groups.entries)
      {'key': key, 'values': value},
  ];
}

List<Object?> _unique(Object? input) {
  final list = _asList(input, 'unique');
  final seen = <Object?>{};
  return [
    for (final item in list)
      if (seen.add(item)) item,
  ];
}

List<Object?> _uniqueBy(Object? input, LamExpr key) {
  final list = _asList(input, 'unique_by');
  final seen = <Object?>{};
  return [
    for (final item in list)
      if (seen.add(evaluate(key, item))) item,
  ];
}

List<Object?> _flatten(Object? input) {
  final list = _asList(input, 'flatten');
  return [
    for (final item in list)
      if (item is List<Object?>) ...item else item,
  ];
}

Map<String, Object?> _filterValues(Object? input, LamExpr predicate) {
  final map = _asMap(input, 'filter_values');
  return {
    for (final MapEntry(:key, :value) in map.entries)
      if (evaluate(predicate, value) == true) key: value,
  };
}

Map<String, Object?> _mapValues(Object? input, LamExpr transform) {
  final map = _asMap(input, 'map_values');
  return {
    for (final MapEntry(:key, :value) in map.entries)
      key: evaluate(transform, value),
  };
}

Map<String, Object?> _filterKeys(Object? input, LamExpr predicate) {
  final map = _asMap(input, 'filter_keys');
  return {
    for (final MapEntry(:key, :value) in map.entries)
      if (evaluate(predicate, key) == true) key: value,
  };
}

String _interpolate(List<LamExpr> parts, Object? ctx) {
  final buffer = StringBuffer();
  for (final part in parts) {
    final value = evaluate(part, ctx);
    buffer.write(value ?? 'null');
  }
  return buffer.toString();
}

Object? _slice(
  Object? target,
  LamExpr? startExpr,
  LamExpr? endExpr,
  Object? ctx,
) {
  if (target == null) return null;
  if (target is List<Object?>) {
    final len = target.length;
    final start = _resolveSliceIndex(startExpr, ctx, len, 0);
    final end = _resolveSliceIndex(endExpr, ctx, len, len);
    if (start >= end || start >= len) return <Object?>[];
    return target.sublist(start.clamp(0, len), end.clamp(0, len));
  }
  if (target is String) {
    final len = target.length;
    final start = _resolveSliceIndex(startExpr, ctx, len, 0);
    final end = _resolveSliceIndex(endExpr, ctx, len, len);
    if (start >= end || start >= len) return '';
    return target.substring(start.clamp(0, len), end.clamp(0, len));
  }
  throw QueryError('Cannot slice ${typeName(target)}');
}

int _resolveSliceIndex(
  LamExpr? expr,
  Object? ctx,
  int length,
  int defaultValue,
) {
  if (expr == null) return defaultValue;
  final value = evaluate(expr, ctx);
  if (value is num) {
    final i = value.toInt();
    return i < 0 ? length + i : i;
  }
  throw QueryError('Slice index must be a number, got ${typeName(value)}');
}

bool _has(Object? input, LamExpr key) {
  if (input is Map<String, Object?>) {
    final k = evaluate(key, input);
    if (k is String) return input.containsKey(k);
    throw QueryError('has: key must be a string, got ${typeName(k)}');
  }
  if (input is List<Object?>) {
    final k = evaluate(key, input);
    if (k is num) return k.toInt() >= 0 && k.toInt() < input.length;
    throw QueryError('has: index must be a number, got ${typeName(k)}');
  }
  throw QueryError('has: expected map or list, got ${typeName(input)}');
}

List<Map<String, Object?>> _toEntries(Object? input) {
  final map = _asMap(input, 'to_entries');
  return [
    for (final MapEntry(:key, :value) in map.entries)
      {'key': key, 'value': value},
  ];
}

Map<String, Object?> _fromEntries(Object? input) {
  final list = _asList(input, 'from_entries');
  return {
    for (final item in list)
      if (item is Map<String, Object?>)
        (item['key'] as String? ??
                (throw const QueryError(
                  'from_entries: entry missing "key" field',
                ))):
            item['value'],
  };
}

List<Object?> _asList(Object? v, String ctx) {
  if (v is List<Object?>) return v;
  throw QueryError('$ctx: expected list, got ${typeName(v)}');
}

Map<String, Object?> _asMap(Object? v, String ctx) {
  if (v is Map<String, Object?>) return v;
  throw QueryError('$ctx: expected map, got ${typeName(v)}');
}
