/// Query expression AST types.
library;

import 'output_format.dart';

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

/// Pipeline expression: `expr | expr`.
///
/// Evaluates [op] with the result of [input] as context. This is expression
/// composition: the right side sees `.` bound to the left side's result.
final class Pipe extends LamExpr {
  /// The input expression.
  final LamExpr input;

  /// The expression to evaluate with the input's result as context.
  final LamExpr op;

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

/// A built-in pipe operation: `filter(...)`, `map(...)`, `sort`, `length`, ...
///
/// The [name] corresponds to a spec in `shape/pipe_ops.dart`, which is the
/// single source of truth for the op's input acceptance, shape inference,
/// runtime evaluation, and parser arity. Adding a new op is a one-file
/// change to that table.
///
/// [args] holds parsed sub-expressions: empty for zero-arg ops like
/// `length`, single-element for one-arg ops like `filter(predicate)` or
/// `map(transform)`. Custom-arity ops (currently just `as(fmt)` with its
/// typed [OutputFormat] argument) keep dedicated AST classes; see [As].
final class BuiltinPipeOp extends LamExpr {
  /// The canonical op name (matches a [PipeOpInfo.name] in the spec table).
  final String name;

  /// Parsed argument expressions, in source order. Empty for zero-arg ops.
  final List<LamExpr> args;

  /// Creates a built-in pipe op.
  const BuiltinPipeOp(this.name, this.args);
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

/// Shape-directed bridge to an output format: `as(toml)`, `as(csv)`.
///
/// At runtime the spec-table dispatch (`shape/pipe_ops.dart:_asSpec`)
/// infers the shape of the current context and checks it against the
/// target format's requirement. If the shape is already compatible,
/// [As] returns the context unchanged. If a curated remediation
/// exists for the mismatch, it is applied. Otherwise evaluation
/// throws a [QueryError].
///
/// The curated remediation table in `shape/check.dart:_suggestionsFor`
/// returns at most one bridge per `(input shape, format)` pair, so in
/// practice "no curated bridge" is the only failure mode users hit.
/// A defensive multi-bridge branch in `_asSpec.eval` guards against
/// future curation errors that might add competing bridges; if that
/// path ever fires the user will get a listing and a request to pick
/// one explicitly.
///
/// [As] keeps a dedicated AST class because its argument is the typed
/// [OutputFormat] enum rather than an arbitrary [LamExpr]. Inference
/// and runtime dispatch flow through the same spec-table pathway as
/// every [BuiltinPipeOp], so per-op invariants (null short-circuit,
/// completer gating, trivial-warning detection) apply uniformly.
final class As extends LamExpr {
  /// The target output format the pipeline should fit.
  final OutputFormat target;

  /// Creates an `as(target)` combinator.
  const As(this.target);
}

/// Alternative: `a // b` — evaluate [left]; if it is `null`, evaluate
/// [right] instead. Otherwise return [left]'s result unchanged.
///
/// Lambé's semantics differ deliberately from jq's: jq's `//` fires on
/// "null or false". Lambé's fires only on `null`. A genuine `false`
/// passes through — matching Lambé's broader strictness stance.
///
/// Because field access on a missing key already yields `null` via
/// null-propagation, `//` doubles as a missing-key fallback:
/// `.user.email // .user.contact.email // "unknown"`.
final class Alternative extends LamExpr {
  /// The primary expression, tried first.
  final LamExpr left;

  /// The fallback, evaluated only when [left] yields `null`.
  final LamExpr right;

  /// Creates an alternative expression.
  const Alternative(this.left, this.right);
}

/// List construction: `[expr, expr, ...]`.
///
/// Each [parts] expression is evaluated against the current context
/// and the results are collected into a list. Empty list literals
/// `[]` produce the empty list.
///
/// Distinct from [Index] (postfix `expr[i]`): list construction has
/// no target on the left, so it can never parse in a context where
/// indexing would apply.
final class ListConstruct extends LamExpr {
  /// The member expressions, evaluated per-call against the context.
  final List<LamExpr> parts;

  /// Creates a list construction.
  const ListConstruct(this.parts);
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
