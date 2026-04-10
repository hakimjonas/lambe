/// Query expression AST types.
library;

/// A query expression node.
sealed class LamExpr {
  /// Base constructor.
  const LamExpr();
}

/// Identity: `.` - returns the current context value.
final class Identity extends LamExpr {
  /// Creates an identity expression.
  const Identity();
}

/// Field access on the current context: `.name`.
final class Field extends LamExpr {
  /// The field name.
  final String name;

  /// Creates a field access for [name].
  const Field(this.name);
}

/// Numeric literal, e.g. `42` or `3.14`.
final class NumLit extends LamExpr {
  /// The numeric value.
  final num value;

  /// Creates a numeric literal with [value].
  const NumLit(this.value);
}

/// String literal, e.g. `"hello"`.
final class StrLit extends LamExpr {
  /// The string value.
  final String value;

  /// Creates a string literal with [value].
  const StrLit(this.value);
}

/// Boolean literal: `true` or `false`.
final class BoolLit extends LamExpr {
  /// The boolean value.
  final bool value;

  /// Creates a boolean literal with [value].
  const BoolLit(this.value);
}

/// Null literal: `null`.
final class NullLit extends LamExpr {
  /// Creates a null literal.
  const NullLit();
}

/// Property access on an expression: `expr.field`.
final class Access extends LamExpr {
  /// The target expression to access a field on.
  final LamExpr target;

  /// The field name to access.
  final String field;

  /// Creates a property access of [field] on [target].
  const Access(this.target, this.field);
}

/// Index into an expression: `expr[index]`.
final class Index extends LamExpr {
  /// The target expression to index into.
  final LamExpr target;

  /// The index expression.
  final LamExpr index;

  /// Creates an index operation on [target] with [index].
  const Index(this.target, this.index);
}

/// Pipeline expression: `expr | operation`.
final class Pipe extends LamExpr {
  /// The input expression.
  final LamExpr input;

  /// The pipeline operation to apply.
  final PipeOp op;

  /// Creates a pipeline of [input] through [op].
  const Pipe(this.input, this.op);
}

/// Unary operator application, e.g. `-x` or `!flag`.
final class UnaryOp extends LamExpr {
  /// The operator (`-` or `!`).
  final String op;

  /// The operand expression.
  final LamExpr operand;

  /// Creates a unary operation.
  const UnaryOp(this.op, this.operand);
}

/// Binary operator application, e.g. `a + b` or `x == y`.
final class BinaryOp extends LamExpr {
  /// The operator.
  final String op;

  /// The left operand.
  final LamExpr left;

  /// The right operand.
  final LamExpr right;

  /// Creates a binary operation.
  const BinaryOp(this.op, this.left, this.right);
}

/// A pipeline operation applied via `|`.
sealed class PipeOp {
  /// Base constructor.
  const PipeOp();
}

/// Filter elements by predicate: `filter(.age > 30)`.
final class FilterOp extends PipeOp {
  /// The predicate expression, evaluated per element.
  final LamExpr predicate;

  /// Creates a filter operation with [predicate].
  const FilterOp(this.predicate);
}

/// Transform each element: `map(.name)`.
final class MapOp extends PipeOp {
  /// The transform expression, evaluated per element.
  final LamExpr transform;

  /// Creates a map operation with [transform].
  const MapOp(this.transform);
}

/// Sort elements naturally: `sort`.
final class SortOp extends PipeOp {
  /// Creates a sort operation.
  const SortOp();
}

/// Reverse element order: `reverse`.
final class ReverseOp extends PipeOp {
  /// Creates a reverse operation.
  const ReverseOp();
}

/// Get keys of a map or indices of a list: `keys`.
final class KeysOp extends PipeOp {
  /// Creates a keys operation.
  const KeysOp();
}

/// Get values of a map (or identity for a list): `values`.
final class ValuesOp extends PipeOp {
  /// Creates a values operation.
  const ValuesOp();
}

/// Get length of a list, map, or string: `length`.
final class LengthOp extends PipeOp {
  /// Creates a length operation.
  const LengthOp();
}

/// Get first element of a list: `first`.
final class FirstOp extends PipeOp {
  /// Creates a first operation.
  const FirstOp();
}

/// Get last element of a list: `last`.
final class LastOp extends PipeOp {
  /// Creates a last operation.
  const LastOp();
}

/// Sum all numeric elements: `sum`.
final class SumOp extends PipeOp {
  /// Creates a sum operation.
  const SumOp();
}

/// Average of all numeric elements: `avg`.
final class AvgOp extends PipeOp {
  /// Creates an avg operation.
  const AvgOp();
}

/// Minimum element: `min`.
final class MinOp extends PipeOp {
  /// Creates a min operation.
  const MinOp();
}

/// Maximum element: `max`.
final class MaxOp extends PipeOp {
  /// Creates a max operation.
  const MaxOp();
}

/// Sort by a key expression: `sort_by(.age)`.
final class SortByOp extends PipeOp {
  /// The key expression, evaluated per element.
  final LamExpr key;

  /// Creates a sort_by operation with [key].
  const SortByOp(this.key);
}

/// Group elements by a key expression: `group_by(.type)`.
///
/// Returns `[{key: k, values: [items]}, ...]`.
final class GroupByOp extends PipeOp {
  /// The key expression, evaluated per element.
  final LamExpr key;

  /// Creates a group_by operation with [key].
  const GroupByOp(this.key);
}

/// Remove duplicate elements: `unique`.
final class UniqueOp extends PipeOp {
  /// Creates a unique operation.
  const UniqueOp();
}

/// Remove duplicates by key: `unique_by(.name)`.
final class UniqueByOp extends PipeOp {
  /// The key expression, evaluated per element.
  final LamExpr key;

  /// Creates a unique_by operation with [key].
  const UniqueByOp(this.key);
}

/// Flatten one level of nesting: `flatten`.
final class FlattenOp extends PipeOp {
  /// Creates a flatten operation.
  const FlattenOp();
}

/// Filter map values by predicate: `filter_values(. > 5)`.
final class FilterValuesOp extends PipeOp {
  /// The predicate expression, evaluated per value.
  final LamExpr predicate;

  /// Creates a filter_values operation with [predicate].
  const FilterValuesOp(this.predicate);
}

/// Transform map values: `map_values(. * 2)`.
final class MapValuesOp extends PipeOp {
  /// The transform expression, evaluated per value.
  final LamExpr transform;

  /// Creates a map_values operation with [transform].
  const MapValuesOp(this.transform);
}

/// Check if a key exists: `has("name")` or `has(.key_field)`.
///
/// The key expression is evaluated and must produce a `String`.
/// Returns `true` if the input map contains the key.
final class HasOp extends PipeOp {
  /// The key expression (must evaluate to a string).
  final LamExpr key;

  /// Creates a has operation with [key].
  const HasOp(this.key);
}

/// Convert a map to a list of `{key, value}` entries: `to_entries`.
final class ToEntriesOp extends PipeOp {
  /// Creates a to_entries operation.
  const ToEntriesOp();
}

/// Convert a list of `{key, value}` entries back to a map: `from_entries`.
final class FromEntriesOp extends PipeOp {
  /// Creates a from_entries operation.
  const FromEntriesOp();
}

/// Filter map keys by predicate: `filter_keys(. != "internal")`.
final class FilterKeysOp extends PipeOp {
  /// The predicate expression, evaluated per key.
  final LamExpr predicate;

  /// Creates a filter_keys operation with [predicate].
  const FilterKeysOp(this.predicate);
}

/// Object construction: `{name, total: .price * .qty}`.
///
/// Each entry is either a shorthand (`{name}` = `{name: .name}`) or
/// explicit (`{total: .price * .qty}`).
final class ObjConstruct extends LamExpr {
  /// The key-value entries. Each key is a string, each value is an expression.
  final List<(String, LamExpr)> entries;

  /// Creates an object construction with [entries].
  const ObjConstruct(this.entries);
}

/// String interpolation: `"\(.name) is \(.age) years old"`.
///
/// The [parts] alternate between literal strings and expressions:
/// `"Hello \(.name)!"` → `[StrLit("Hello "), Field("name"), StrLit("!")]`.
final class StringInterp extends LamExpr {
  /// The interpolation parts - literal strings and embedded expressions.
  final List<LamExpr> parts;

  /// Creates a string interpolation with [parts].
  const StringInterp(this.parts);
}

/// Slice into a list: `expr[start:end]`.
final class Slice extends LamExpr {
  /// The target expression to slice.
  final LamExpr target;

  /// The start index (inclusive), or `null` for start of list.
  final LamExpr? start;

  /// The end index (exclusive), or `null` for end of list.
  final LamExpr? end;

  /// Creates a slice on [target] from [start] to [end].
  const Slice(this.target, this.start, this.end);
}

/// Conditional expression: `if cond then a else b`.
final class Conditional extends LamExpr {
  /// The condition (must evaluate to bool).
  final LamExpr condition;

  /// The expression when condition is true.
  final LamExpr then_;

  /// The expression when condition is false.
  final LamExpr else_;

  /// Creates a conditional expression.
  const Conditional(this.condition, this.then_, this.else_);
}
