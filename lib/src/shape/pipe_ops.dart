/// Single source of truth for pipe-op metadata, runtime, and parsing.
///
/// Each [PipeOpInfo] record describes one pipe operation: its canonical
/// name, which input [Shape]s it accepts (structurally; element-level
/// constraints are not modelled), how it transforms the input shape into
/// an output shape, and how it evaluates at runtime. The parser's
/// [pipeOpNames], the completer's shape-gated candidate filter,
/// [inferShape]'s per-op cases, and the evaluator's per-op dispatch all
/// derive from these specs, so adding or renaming an op is a single-
/// file change.
///
/// # Design invariants
///
/// - `accepts(SAny)` must return `true`. Inference cannot prove an
///   [SAny] input will fail, so the completer must not hide candidates
///   that might succeed.
/// - `infer(input, ast)` may return [SAny] when inference loses
///   precision (dynamic keys, heterogeneous elements, etc.), but must
///   not return a shape that would be incorrect for every runtime
///   value matching `input`. When `accepts(input)` returns `false`,
///   `infer` should return [SAny] — the query will throw at runtime
///   and downstream inference should not pretend otherwise.
/// - The spec's acceptance predicate must match the runtime evaluator's
///   type checks. `pipe_ops_consistency_test.dart` pins this by
///   running every op against representative values of every shape
///   kind and cross-checking with the evaluator.
library;

import 'dart:convert';

import 'package:rumil_expressions/rumil_expressions.dart'
    show compareValues, typeName;

import '../ast.dart';
import '../errors.dart';
import '../output_format.dart';
import 'check.dart';
import 'shape.dart';
import 'synthesize.dart';

/// Recursive evaluator callback. The spec's `eval` field invokes this to
/// evaluate sub-expressions (predicates, key extractors, transforms)
/// against a given context. Pipe ops do not import the evaluator
/// directly; they reach back through this callback to keep the
/// dependency direction acyclic.
typedef PipeOpEval = Object? Function(LamExpr expr, Object? ctx);

/// How the parser should build a grammar rule for this op.
///
/// - [zeroArg]: bare keyword followed by a word boundary — `sort`,
///   `length`, `to_entries`. Parser builds `BuiltinPipeOp(name, [])`.
/// - [oneArg]: keyword followed by `(expr)` with tolerant inner and
///   close paren — `filter(...)`, `map(...)`. Parser builds
///   `BuiltinPipeOp(name, [innerExpr])`.
/// - [custom]: the op has grammar the generic rules cannot express
///   (e.g. `as(fmt)` takes a closed keyword set, not an arbitrary
///   expression). The parser hand-writes these rules and the spec
///   provides shape metadata only; runtime dispatch lives outside
///   [BuiltinPipeOp] (see [As]).
enum PipeOpParseKind {
  /// Bare keyword followed by a word boundary — `sort`, `length`,
  /// `to_entries`. Parser builds `BuiltinPipeOp(name, const [])`.
  zeroArg,

  /// Keyword followed by `(expr)` with a tolerant inner expression and
  /// close paren — `filter(.x)`, `map(.y)`, `sort_by(.name)`. Parser
  /// builds `BuiltinPipeOp(name, [innerExpr])`.
  oneArg,

  /// Op has custom grammar not expressible as `zeroArg` or `oneArg`,
  /// e.g. `as(fmt)` takes a closed keyword set instead of an arbitrary
  /// expression. Parser hand-writes the rule; runtime dispatch lives
  /// in a dedicated AST node (see [As]).
  custom,
}

/// Metadata for one pipe operation.
///
/// The `accepts` field is a structural predicate on the input shape.
/// The `infer` field is the shape transformer — given the input shape
/// and the AST node for this op (so parameterized ops can recurse into
/// their inner expression), it returns the output shape. The `eval`
/// field is the runtime evaluator — given the input value, the AST
/// node, and the recursive [PipeOpEval] callback, it returns the op's
/// result. Eval implementations that need argument expressions
/// destructure the node: `(op as BuiltinPipeOp).args[0]` for the
/// generic dispatch, or pattern-match on a custom node like [As] when
/// the spec covers a typed-argument op.
///
/// `parseKind` tells the parser which generic rule shape this op uses.
/// `custom` ops are hand-written in the parser and may use a dedicated
/// AST class for their typed argument (currently only [As]). Their
/// `infer` and `eval` flow through the same spec-table dispatch as
/// every other op, so per-op invariants (null short-circuit, completer
/// gating, trivial-warning detection) apply uniformly.
typedef PipeOpInfo =
    ({
      String name,
      bool Function(Shape input) accepts,
      Shape Function(Shape input, LamExpr op) infer,
      Object? Function(Object? ctx, LamExpr op, PipeOpEval eval) eval,
      PipeOpParseKind parseKind,
    });

/// Pipe ops that opt out of the [Pipe] evaluator's null short-circuit.
///
/// The default `Pipe` contract is "navigation on null returns null":
/// when a pipe's left side evaluates to null, the right-hand op is
/// skipped entirely and the result is null. That is correct for most
/// ops (`.field`, `flatten`, `length`, `map`, …) — they walk structure
/// they don't have. But it is wrong for ops whose semantics are
/// *defined* over a null context. The canonical example is `type`,
/// which inspects any context — including null — and returns a string
/// describing it. Such ops are listed here; `_pipe` in `evaluator.dart`
/// consults this set and forwards the null instead of short-circuiting.
///
/// Add an op to this set when:
/// - the spec's `eval` has a deliberate branch for `null` input, AND
/// - the spec's `infer` returns a non-null shape for null input
///   (so the `--explain` contract matches the runtime behaviour).
const Set<String> nullSafePipeOpNames = {'type'};

/// Look up the spec for a pipe-op AST node, or `null` if [node] is not
/// a pipe op.
///
/// Recognises the unified [BuiltinPipeOp] dispatch and the dedicated
/// [As] node (the only custom-arity op). Returns `null` for non-op
/// expressions that happen to appear on the right-hand side of a pipe
/// (object constructors, literals, etc.). The shape inference and
/// completer code paths that consume the spec must handle `null` by
/// falling back to generic expression inference.
PipeOpInfo? pipeOpInfoFor(LamExpr node) {
  if (node is BuiltinPipeOp) return _specsByName[node.name];
  if (node is As) return _asSpec;
  return null;
}

/// Spec lookup by op name. Returns `null` for names that are not in
/// the spec table.
///
/// Used by the completer to filter pipe-op candidates: when the user
/// types `.x | <prefix>`, candidates whose spec's `accepts` returns
/// `false` for the input shape are dropped. [SAny] inputs pass the
/// filter for every op.
PipeOpInfo? pipeOpInfoForName(String name) => _specsByName[name];

/// All pipe-op names, sorted alphabetically.
///
/// Derived from the spec table at module-load time. The canonical source
/// consumed by the parser (for misspelling suggestions) and by the
/// completer (for candidate enumeration).
final List<String> pipeOpNames = List<String>.unmodifiable(
  _specsByName.keys.toList()..sort(),
);

/// All pipe-op specs, ordered so the parser can build grammar rules
/// without manual disambiguation.
///
/// Longer names come first so `sort_by` is tried before `sort` and
/// `filter_values` before `filter`. With a word-boundary keyword
/// matcher this would not be strictly necessary, but ordering by
/// length-descending is robust against future changes to the
/// boundary rule and matches how the grammar was originally written
/// by hand.
final List<PipeOpInfo> pipeOpSpecs = List<PipeOpInfo>.unmodifiable(
  _specsByName.values.toList()
    ..sort((a, b) => b.name.length.compareTo(a.name.length)),
);

/// Whether [opName] accepts an input of [shape].
///
/// Unknown names return `true` (conservative default) so a future op
/// added to the parser but missing from this table is never hidden
/// from the completer. [SAny] inputs pass the filter for every op —
/// the acceptance predicates enforce this invariant themselves, so it
/// holds for every registered op without needing a wrapper check.
///
/// Used by the REPL completer to shape-gate pipe-op candidates at
/// `.x | <TAB>`.
bool acceptsInputShape(String opName, Shape shape) =>
    pipeOpInfoForName(opName)?.accepts(shape) ?? true;

/// Infer the output shape of a pipe op.
///
/// Given the input shape flowing into [op] (the shape of the value
/// produced by the left side of the enclosing [Pipe]) and the op AST
/// node itself, returns the output shape.
///
/// Returns [SAny] if [op] is not a recognised pipe op (the caller's
/// cue to fall back to generic expression inference). Returns [SAny]
/// if the input shape is not accepted by the op; this is the
/// structural-failure case — at runtime the evaluator would throw, and
/// downstream inference must not pretend the output has a concrete
/// shape it cannot have.
///
/// Models the [Pipe] evaluator's null short-circuit: when the input
/// shape is [SNull] and the op is not in [nullSafePipeOpNames], the
/// runtime returns null without invoking the op, so the inferred
/// shape is [SNull] rather than the op's nominal output. This keeps
/// `--explain` honest about the documented "navigation on null
/// returns null" contract instead of warning that the op will throw.
Shape inferPipeOpShape(Shape input, LamExpr op) {
  final info = pipeOpInfoFor(op);
  if (info == null) return const SAny();
  if (input is SNull && !_isNullSafe(op)) return const SNull();
  if (!info.accepts(input)) return const SAny();
  return info.infer(input, op);
}

/// Whether [op] opts out of the [Pipe] evaluator's null short-circuit.
///
/// True for [BuiltinPipeOp]s whose name is in [nullSafePipeOpNames].
/// The custom-arity [As] node is never null-safe — bridging null to
/// a target format is the responsibility of the caller, not `as`.
bool _isNullSafe(LamExpr op) =>
    op is BuiltinPipeOp && nullSafePipeOpNames.contains(op.name);

/// Evaluate any pipe-op AST node against [ctx].
///
/// Dispatches through the spec table for both [BuiltinPipeOp] (the
/// generic dispatch) and [As] (the one custom-AST op). Throws
/// [QueryError] if the AST node is not a pipe op or its name has no
/// registered spec — that means the parser produced a node the table
/// does not know about, which is a programmer error rather than a
/// user-input error.
///
/// Eval implementations destructure [op] themselves to read whatever
/// arguments they need: `BuiltinPipeOp.args` for the generic case,
/// `As.target` for the typed-format case.
Object? evalPipeOp(LamExpr op, Object? ctx, PipeOpEval eval) {
  final spec = pipeOpInfoFor(op);
  if (spec == null) {
    throw QueryError(
      'evalPipeOp: ${op.runtimeType} is not a registered pipe-op AST',
    );
  }
  return spec.eval(ctx, op, eval);
}

// Every predicate treats [SAny] as accepted. Inference cannot prove
// an SAny input will fail at runtime, so rejecting it would hide
// correct candidates from the completer — a violation of the
// design invariant documented at the top of this file.

// Optional wraps the value's potential absence. For acceptance
// purposes, unwrap: if the inner shape is accepted, so is the
// optional. The runtime-rejection warning in `explain.dart` is the
// user-visible note that "may be absent at runtime." Downstream
// inference still sees the optional propagated by [inferShape] so
// warnings keep firing along the chain.
Shape _unwrap(Shape s) => s is SOptional ? s.inner : s;

bool _acceptsList(Shape s) {
  s = _unwrap(s);
  return s is SList || s is SAny;
}

bool _acceptsMap(Shape s) {
  s = _unwrap(s);
  return s is SMap || s is SAny;
}

bool _acceptsListOrMap(Shape s) {
  s = _unwrap(s);
  return s is SList || s is SMap || s is SAny;
}

bool _acceptsListMapOrString(Shape s) {
  s = _unwrap(s);
  return s is SList || s is SMap || s is SString || s is SAny;
}

bool _acceptsStringOrNum(Shape s) {
  s = _unwrap(s);
  return s is SString || s is SNum || s is SAny;
}

bool _acceptsAny(Shape _) => true;

// ------------------------------------------------------------------
// Runtime helpers shared across op evals.
// ------------------------------------------------------------------

List<Object?> _asList(Object? v, String ctx) {
  if (v is List<Object?>) return v;
  throw QueryError('$ctx: expected list, got ${typeName(v)}');
}

Map<String, Object?> _asMap(Object? v, String ctx) {
  if (v is Map<String, Object?>) return v;
  throw QueryError('$ctx: expected map, got ${typeName(v)}');
}

/// Canonical string representation of [value] for use as a hash key.
///
/// Dart's native equality on `List` and `Map` is reference-based, so
/// structurally-equal collections compare as unequal. `unique`,
/// `unique_by`, and `group_by` need structural equality to behave
/// sensibly. Encoding the value as JSON with sorted map keys gives a
/// stable, equality-friendly key.
String _canonicalKey(Object? value) => jsonEncode(_sortKeys(value));

Object? _sortKeys(Object? value) {
  if (value is Map<String, Object?>) {
    final sorted = <String, Object?>{};
    final keys = value.keys.toList()..sort();
    for (final k in keys) {
      sorted[k] = _sortKeys(value[k]);
    }
    return sorted;
  }
  if (value is List<Object?>) {
    return [for (final e in value) _sortKeys(e)];
  }
  return value;
}

// --- List-consuming ops --------------------------------------------

final PipeOpInfo _filterSpec = (
  name: 'filter',
  accepts: _acceptsList,
  // `filter` preserves the list-of-elements shape.
  infer: (input, _) => input,
  eval: (ctx, op, eval) {
    final list = _asList(ctx, 'filter');
    final pred = (op as BuiltinPipeOp).args[0];
    return [
      for (final item in list)
        if (eval(pred, item) == true) item,
    ];
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _mapSpec = (
  name: 'map',
  accepts: _acceptsList,
  infer:
      (input, op) => switch ((input, op)) {
        (
          SList(element: final e),
          BuiltinPipeOp(name: 'map', args: [final transform]),
        ) =>
          SList(_inferSubExpr(transform, e)),
        _ => const SAny(),
      },
  eval: (ctx, op, eval) {
    final list = _asList(ctx, 'map');
    final transform = (op as BuiltinPipeOp).args[0];
    return [for (final item in list) eval(transform, item)];
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _sortSpec = (
  name: 'sort',
  accepts: _acceptsList,
  infer: (input, _) => input,
  eval: (ctx, _, _) {
    final list = List<Object?>.of(_asList(ctx, 'sort'));
    list.sort(compareValues);
    return list;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _reverseSpec = (
  name: 'reverse',
  accepts: _acceptsList,
  infer: (input, _) => input,
  eval: (ctx, _, _) => List<Object?>.of(_asList(ctx, 'reverse').reversed),
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _sortBySpec = (
  name: 'sort_by',
  accepts: _acceptsList,
  infer: (input, _) => input,
  eval: (ctx, op, eval) {
    final list = List<Object?>.of(_asList(ctx, 'sort_by'));
    final key = (op as BuiltinPipeOp).args[0];
    list.sort((a, b) => compareValues(eval(key, a), eval(key, b)));
    return list;
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _uniqueSpec = (
  name: 'unique',
  accepts: _acceptsList,
  infer: (input, _) => input,
  // `unique` distinguishes int from double even when numerically
  // equal: `unique([1, 1.0])` keeps both because the canonical
  // encodings differ. Use `unique_by(.)` with `to_number` if numeric
  // equality is required.
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'unique');
    final seen = <String>{};
    return [
      for (final item in list)
        if (seen.add(_canonicalKey(item))) item,
    ];
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _uniqueBySpec = (
  name: 'unique_by',
  accepts: _acceptsList,
  infer: (input, _) => input,
  eval: (ctx, op, eval) {
    final list = _asList(ctx, 'unique_by');
    final key = (op as BuiltinPipeOp).args[0];
    final seen = <String>{};
    return [
      for (final item in list)
        if (seen.add(_canonicalKey(eval(key, item)))) item,
    ];
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _flattenSpec = (
  name: 'flatten',
  accepts: _acceptsList,
  // `flatten` removes one level of nesting. If elements are lists
  // their element shape becomes the result's element shape;
  // otherwise the output is SList(SAny).
  infer:
      (input, _) => switch (input) {
        SList(element: SList(element: final inner)) => SList(inner),
        SList() => const SList(SAny()),
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'flatten');
    return [
      for (final item in list)
        if (item is List<Object?>) ...item else item,
    ];
  },
  parseKind: PipeOpParseKind.zeroArg,
);

// Empty-list policy:
// - Operations with an identity element (sum -> 0) return that.
// - Operations that pick an existing element (first, last) return
//   null.
// - Operations that compute a property of the elements (min, max,
//   avg) throw, because no sensible result exists.
//
// This mirrors how most languages handle the same situations.
final PipeOpInfo _firstSpec = (
  name: 'first',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'first');
    return list.isEmpty ? null : list.first;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _lastSpec = (
  name: 'last',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'last');
    return list.isEmpty ? null : list.last;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _sumSpec = (
  name: 'sum',
  accepts: _acceptsList,
  infer: (_, _) => const SNum(),
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'sum');
    num total = 0;
    for (final item in list) {
      if (item is! num) {
        throw QueryError('sum: expected number, got ${typeName(item)}');
      }
      total += item;
    }
    return total;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _avgSpec = (
  name: 'avg',
  accepts: _acceptsList,
  infer: (_, _) => const SNum(),
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'avg');
    if (list.isEmpty) throw const QueryError('avg: empty list');
    num total = 0;
    for (final item in list) {
      if (item is! num) {
        throw QueryError('avg: expected number, got ${typeName(item)}');
      }
      total += item;
    }
    return total.toDouble() / list.length;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _minSpec = (
  name: 'min',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'min');
    if (list.isEmpty) throw const QueryError('min: empty list');
    var best = list.first;
    for (var i = 1; i < list.length; i++) {
      if (compareValues(list[i], best) < 0) best = list[i];
    }
    return best;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _maxSpec = (
  name: 'max',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'max');
    if (list.isEmpty) throw const QueryError('max: empty list');
    var best = list.first;
    for (var i = 1; i < list.length; i++) {
      if (compareValues(list[i], best) > 0) best = list[i];
    }
    return best;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _groupBySpec = (
  name: 'group_by',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => SList(
          SMap({'key': const SAny(), 'values': SList(e)}),
        ),
        _ => const SAny(),
      },
  eval: (ctx, op, eval) {
    final list = _asList(ctx, 'group_by');
    final key = (op as BuiltinPipeOp).args[0];
    // Group on a canonical string representation so structurally-equal
    // Maps and Lists compare as equal. A side map preserves the
    // original key value for the output record.
    final groups = <String, List<Object?>>{};
    final originalKeys = <String, Object?>{};
    for (final item in list) {
      final k = eval(key, item);
      final canonical = _canonicalKey(k);
      originalKeys[canonical] = k;
      (groups[canonical] ??= []).add(item);
    }
    return [
      for (final entry in groups.entries)
        {'key': originalKeys[entry.key], 'values': entry.value},
    ];
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _fromEntriesSpec = (
  name: 'from_entries',
  accepts: _acceptsList,
  // Runtime keys are dynamic, so the resulting map has no known fields.
  // Callers that only need to know "is it a map" (e.g. TOML/HCL
  // writability) still get a correct answer.
  infer: (_, _) => const SMap(<String, Shape>{}),
  // Non-map entries are rejected explicitly. Earlier silent skipping
  // hid bugs where upstream pipelines emitted the wrong shape.
  eval: (ctx, _, _) {
    final list = _asList(ctx, 'from_entries');
    final result = <String, Object?>{};
    for (final item in list) {
      if (item is! Map<String, Object?>) {
        throw QueryError(
          'from_entries: entry must be a map, got ${typeName(item)}',
        );
      }
      final key = item['key'];
      if (key is! String) {
        throw QueryError(
          'from_entries: entry "key" must be a string, got ${typeName(key)}',
        );
      }
      result[key] = item['value'];
    }
    return result;
  },
  parseKind: PipeOpParseKind.zeroArg,
);

// --- Map-consuming ops ---------------------------------------------

final PipeOpInfo _filterValuesSpec = (
  name: 'filter_values',
  accepts: _acceptsMap,
  infer: (input, _) => input,
  eval: (ctx, op, eval) {
    final map = _asMap(ctx, 'filter_values');
    final predicate = (op as BuiltinPipeOp).args[0];
    return {
      for (final MapEntry(:key, :value) in map.entries)
        if (eval(predicate, value) == true) key: value,
    };
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _mapValuesSpec = (
  name: 'map_values',
  accepts: _acceptsMap,
  infer:
      (input, op) => switch ((input, op)) {
        (
          SMap(fields: final fields),
          BuiltinPipeOp(name: 'map_values', args: [final transform]),
        ) =>
          SMap({
            for (final MapEntry(:key, :value) in fields.entries)
              key: _inferSubExpr(transform, value),
          }),
        _ => const SAny(),
      },
  eval: (ctx, op, eval) {
    final map = _asMap(ctx, 'map_values');
    final transform = (op as BuiltinPipeOp).args[0];
    return {
      for (final MapEntry(:key, :value) in map.entries)
        key: eval(transform, value),
    };
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _filterKeysSpec = (
  name: 'filter_keys',
  accepts: _acceptsMap,
  infer: (input, _) => input,
  eval: (ctx, op, eval) {
    final map = _asMap(ctx, 'filter_keys');
    final predicate = (op as BuiltinPipeOp).args[0];
    return {
      for (final MapEntry(:key, :value) in map.entries)
        if (eval(predicate, key) == true) key: value,
    };
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _hasSpec = (
  name: 'has',
  accepts: _acceptsMap,
  infer: (_, _) => const SBool(),
  eval: (ctx, op, eval) {
    final key = (op as BuiltinPipeOp).args[0];
    if (ctx is Map<String, Object?>) {
      final k = eval(key, ctx);
      if (k is String) return ctx.containsKey(k);
      throw QueryError('has: key must be a string, got ${typeName(k)}');
    }
    if (ctx is List<Object?>) {
      final k = eval(key, ctx);
      if (k is num) return k.toInt() >= 0 && k.toInt() < ctx.length;
      throw QueryError('has: index must be a number, got ${typeName(k)}');
    }
    throw QueryError('has: expected map or list, got ${typeName(ctx)}');
  },
  parseKind: PipeOpParseKind.oneArg,
);

final PipeOpInfo _toEntriesSpec = (
  name: 'to_entries',
  accepts: _acceptsMap,
  infer:
      (input, _) => switch (input) {
        SMap(fields: final fields) when fields.isEmpty => const SList(
          SMap({'key': SString(), 'value': SAny()}),
        ),
        SMap(fields: final fields) => SList(
          SMap({'key': const SString(), 'value': _joinAll(fields.values)}),
        ),
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    final map = _asMap(ctx, 'to_entries');
    return [
      for (final MapEntry(:key, :value) in map.entries)
        {'key': key, 'value': value},
    ];
  },
  parseKind: PipeOpParseKind.zeroArg,
);

// --- List-or-map ops -----------------------------------------------

final PipeOpInfo _keysSpec = (
  name: 'keys',
  accepts: _acceptsListOrMap,
  infer:
      (input, _) => switch (input) {
        SMap() => const SList(SString()),
        SList() => const SList(SNum()),
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    if (ctx is Map<String, Object?>) return ctx.keys.toList();
    if (ctx is List<Object?>) {
      return [for (var i = 0; i < ctx.length; i++) i];
    }
    throw QueryError('keys: expected map or list, got ${typeName(ctx)}');
  },
  parseKind: PipeOpParseKind.zeroArg,
);

final PipeOpInfo _valuesSpec = (
  name: 'values',
  accepts: _acceptsListOrMap,
  infer:
      (input, _) => switch (input) {
        SMap(fields: final fields) when fields.isEmpty => const SList(SAny()),
        SMap(fields: final fields) => SList(_joinAll(fields.values)),
        SList() => input,
        _ => const SAny(),
      },
  eval: (ctx, _, _) {
    if (ctx is Map<String, Object?>) return ctx.values.toList();
    if (ctx is List<Object?>) return ctx;
    throw QueryError('values: expected map or list, got ${typeName(ctx)}');
  },
  parseKind: PipeOpParseKind.zeroArg,
);

// --- List, map, or string ------------------------------------------

final PipeOpInfo _lengthSpec = (
  name: 'length',
  accepts: _acceptsListMapOrString,
  infer: (_, _) => const SNum(),
  eval: (ctx, _, _) {
    if (ctx is List<Object?>) return ctx.length;
    if (ctx is Map<String, Object?>) return ctx.length;
    if (ctx is String) return ctx.length;
    throw QueryError(
      'length: expected list, map, or string, got ${typeName(ctx)}',
    );
  },
  parseKind: PipeOpParseKind.zeroArg,
);

// --- String or number ----------------------------------------------

final PipeOpInfo _toNumberSpec = (
  name: 'to_number',
  accepts: _acceptsStringOrNum,
  infer: (_, _) => const SNum(),
  eval: (ctx, _, _) {
    if (ctx is num) return ctx;
    if (ctx is String) {
      final parsed = num.tryParse(ctx);
      if (parsed != null) return parsed;
      throw QueryError('to_number: cannot parse "$ctx" as a number');
    }
    throw QueryError(
      'to_number: expected string or number, got ${typeName(ctx)}',
    );
  },
  parseKind: PipeOpParseKind.zeroArg,
);

// --- Universal ops -------------------------------------------------

final PipeOpInfo _typeSpec = (
  name: 'type',
  accepts: _acceptsAny,
  infer: (_, _) => const SString(),
  eval:
      (ctx, _, _) => switch (ctx) {
        null => 'null',
        bool() => 'boolean',
        num() => 'number',
        String() => 'string',
        List<Object?>() => 'array',
        Map<String, Object?>() => 'object',
        _ =>
          throw QueryError(
            'type: data contains a non-JSON value (${ctx.runtimeType}). '
            'Lambé queries operate on JSON-shaped data — pass results of '
            'parseInput, jsonDecode, or canonical literals.',
          ),
      },
  parseKind: PipeOpParseKind.zeroArg,
);

/// Markdown text extraction.
///
/// Walks the typed-node tree produced by `parseInput` on a Markdown
/// document and concatenates every prose-bearing leaf — `text`, `code`,
/// `code_block`, and `image.alt` — in document order. Container nodes
/// recurse element-wise through their `children`. `html_block` and
/// `html_inline` are skipped (the `Node.textContent` trap of dragging
/// raw HTML, scripts, and styles into "give me the text").
/// `soft_break` contributes a single space (preserves word
/// separation across source line wraps); `hard_break` contributes
/// `'\n'` (preserves the authorial intent — `\` at end of line or two
/// trailing spaces is an explicit break in the source). Users wanting
/// a fully flat string can post-process with a newline replacer. This
/// is a deliberate divergence from `mdast-util-to-string`'s
/// empty-on-break default; the divergence trades strict precedent for
/// the more typical use case of "produce readable prose".
/// Maps that are not markdown nodes (no recognised `type`) yield the
/// empty string; non-map non-list values throw.
///
/// PRECEDENT: this is the only op whose `eval` switches on a value's
/// `type` field. The behaviour is bounded to markdown's node-type
/// vocabulary as defined in `lib/src/input.dart`'s `_nodeToNative`. It
/// does NOT authorise content-level dispatch in any other op.
final PipeOpInfo _textSpec = (
  name: 'text',
  accepts: _acceptsListOrMap,
  infer: (_, _) => const SString(),
  eval: (ctx, _, _) {
    if (ctx is! List<Object?> && ctx is! Map<String, Object?>) {
      throw QueryError('text: expected map or list, got ${typeName(ctx)}');
    }
    final buf = StringBuffer();
    _appendMarkdownText(buf, ctx);
    return buf.toString();
  },
  parseKind: PipeOpParseKind.zeroArg,
);

void _appendMarkdownText(StringBuffer buf, Object? node) {
  if (node is List<Object?>) {
    for (final child in node) {
      _appendMarkdownText(buf, child);
    }
    return;
  }
  if (node is! Map<String, Object?>) {
    throw QueryError(
      'text: child must be a markdown node (map) or list of nodes, '
      'got ${typeName(node)}',
    );
  }
  final type = node['type'];
  switch (type) {
    case 'text':
      final t = node['text'];
      if (t is String) buf.write(t);
    case 'code':
      final c = node['code'];
      if (c is String) buf.write(c);
    case 'code_block':
      final c = node['code'];
      if (c is String) buf.write(c);
    case 'image':
      final alt = node['alt'];
      if (alt is String) buf.write(alt);
    case 'soft_break':
      buf.write(' ');
      return;
    case 'hard_break':
      buf.write('\n');
      return;
    case 'html_block':
    case 'html_inline':
    case 'thematic_break':
      return;
    default:
      final children = node['children'];
      if (children is List<Object?>) {
        for (final child in children) {
          _appendMarkdownText(buf, child);
        }
      }
  }
}

/// `as(target)` is structurally universal: it accepts any shape and
/// returns the input shape when already writable, or [SAny] when the
/// bridging path is ambiguous or missing. The concrete logic lives in
/// [inferShape] because it needs access to `synthesize`, which this
/// module does not import to avoid a cycle. `infer` here returns
/// [SAny] as a safe default; the real computation happens in
/// `infer.dart` for the [As] case.
///
/// `parseKind` is `custom` because `as(fmt)` takes a closed keyword
/// set (`json`, `yaml`, etc.) rather than an arbitrary expression — the
/// generic `oneArg` rule cannot express that. The parser hand-writes
/// `_asOp` and emits an [As] AST node carrying the typed [OutputFormat]
/// argument.
///
/// Both `infer` and `eval` here are real implementations. They
/// destructure the [As] node to read the typed target and consult the
/// shape-bridge synthesis table (`canWriteAs` / `synthesize`). With
/// this in place, the [As] AST flows through the same `pipeOpInfoFor`
/// → spec.eval / spec.infer dispatch as every other pipe op, so per-op
/// invariants (null short-circuit, completer gating, trivial-warning
/// suppression) apply uniformly without an `if (expr is As)` branch in
/// the inference or evaluator code paths.
final PipeOpInfo _asSpec = (
  name: 'as',
  accepts: _acceptsAny,
  infer: (input, op) {
    final target = (op as As).target;
    final report = canWriteShapeAs(input, target);
    if (report is Writable) return input;
    final bridges = synthesize(input, target);
    if (bridges.length == 1) return _inferSubExpr(bridges.first, input);
    return const SAny();
  },
  eval: (ctx, op, eval) {
    final target = (op as As).target;
    final report = canWriteAs(ctx, target);
    if (report is Writable) return ctx;
    final nw = report as NotWritable;
    if (nw.suggestions.isEmpty) {
      throw QueryError(
        'as(${target.name}): no known bridge from '
        '${renderShape(nw.got)} to ${target.name}. ',
      );
    }
    if (nw.suggestions.length > 1) {
      final listing = nw.suggestions
          .map((r) => '  | ${r.display}    # ${r.explanation}')
          .join('\n');
      throw QueryError(
        'as(${target.name}): ambiguous bridge from '
        '${renderShape(nw.got)}. Pick one explicitly:\n$listing',
      );
    }
    return eval(nw.suggestions.first.template, ctx);
  },
  parseKind: PipeOpParseKind.custom,
);

// ------------------------------------------------------------------
// Derived tables
// ------------------------------------------------------------------

final Map<String, PipeOpInfo> _specsByName = Map.unmodifiable({
  for (final s in <PipeOpInfo>[
    _filterSpec,
    _mapSpec,
    _sortSpec,
    _reverseSpec,
    _sortBySpec,
    _uniqueSpec,
    _uniqueBySpec,
    _flattenSpec,
    _firstSpec,
    _lastSpec,
    _sumSpec,
    _avgSpec,
    _minSpec,
    _maxSpec,
    _groupBySpec,
    _fromEntriesSpec,
    _filterValuesSpec,
    _mapValuesSpec,
    _filterKeysSpec,
    _hasSpec,
    _toEntriesSpec,
    _keysSpec,
    _valuesSpec,
    _lengthSpec,
    _toNumberSpec,
    _typeSpec,
    _textSpec,
    _asSpec,
  ])
    s.name: s,
});

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

/// Late-bound recursive call into `inferShape`.
///
/// Parameterized ops (`map`, `map_values`) need to infer the output
/// shape of an inner expression. Rather than inlining the full
/// `inferShape` recursion here (which would duplicate the expression-
/// level cases this file does not own), we forward through a function
/// pointer set by [registerSubExprInferrer] during library
/// initialization. This keeps `pipe_ops.dart` independent of
/// `infer.dart` and avoids a circular import.
Shape Function(LamExpr, Shape)? _subExprInferrer;

/// Install the callback [inferShape] uses to recurse into inner
/// expressions of parameterized ops.
///
/// Called once from `infer.dart` at library initialization. A second
/// call overwrites the previous inferrer; callers that need to swap
/// (e.g. tests simulating a custom shape algebra) can do so.
void registerSubExprInferrer(Shape Function(LamExpr, Shape) inferrer) {
  _subExprInferrer = inferrer;
}

Shape _inferSubExpr(LamExpr expr, Shape context) {
  final inferrer = _subExprInferrer;
  if (inferrer == null) return const SAny();
  return inferrer(expr, context);
}

/// Join shapes to a structural upper bound. Two equal shapes pass
/// through; otherwise the join is [SAny]. Matches `_joinBranches` in
/// `infer.dart`; inlined here to keep this file standalone.
Shape _joinAll(Iterable<Shape> shapes) {
  final iterator = shapes.iterator;
  if (!iterator.moveNext()) return const SAny();
  final first = iterator.current;
  while (iterator.moveNext()) {
    if (iterator.current != first) return const SAny();
  }
  return first;
}
