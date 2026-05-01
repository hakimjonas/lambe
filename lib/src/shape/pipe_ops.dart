/// Single source of truth for pipe-op metadata.
///
/// Each [PipeOpInfo] record describes one pipe operation: its canonical
/// name, which input [Shape]s it accepts (structurally; element-level
/// constraints are not modelled), and how it transforms the input shape
/// into an output shape. The parser's [pipeOpNames], the completer's
/// shape-gated candidate filter, and [inferShape]'s per-op cases all
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

import '../ast.dart';
import 'shape.dart';

/// How the parser should build a grammar rule for this op.
///
/// - [zeroArg]: bare keyword followed by a word boundary — `sort`,
///   `length`, `to_entries`. Constructed via the spec's `zeroArgCtor`.
/// - [oneArg]: keyword followed by `(expr)` with tolerant inner and
///   close paren — `filter(...)`, `map(...)`. Constructed via the
///   spec's `oneArgCtor`.
/// - [custom]: the op has grammar the generic rules cannot express
///   (e.g. `as(fmt)` takes a keyword set, not an arbitrary expression).
///   The parser hand-writes these rules and the spec table provides
///   metadata only.
enum PipeOpParseKind {
  /// Bare keyword followed by a word boundary — `sort`, `length`,
  /// `to_entries`. Parser builds `_kw(name).as(zeroArgCtor())`.
  zeroArg,

  /// Keyword followed by `(expr)` with a tolerant inner expression and
  /// close paren — `filter(.x)`, `map(.y)`, `sort_by(.name)`. Parser
  /// builds `_paramOp(name, oneArgCtor)`.
  oneArg,

  /// Op has custom grammar not expressible as `zeroArg` or `oneArg`,
  /// e.g. `as(fmt)` takes a closed keyword set instead of an arbitrary
  /// expression. Parser hand-writes the rule; the spec table supplies
  /// only the name and shape-inference metadata.
  custom,
}

/// Metadata for one pipe operation.
///
/// The `accepts` field is a structural predicate on the input shape.
/// The `infer` field is the shape transformer — given the input shape
/// and the AST node for this op (so parameterized ops can recurse
/// into their inner expression), it returns the output shape.
///
/// The `parseKind`, `zeroArgCtor`, and `oneArgCtor` fields let the
/// parser build its pipe-op grammar rules from this table rather
/// than hand-writing them per op. A spec's `parseKind` determines
/// which constructor reference is consulted:
///
/// - `zeroArg` → `zeroArgCtor!()` produces the AST node.
/// - `oneArg` → `oneArgCtor!(innerExpr)` produces the AST node.
/// - `custom` → the parser handles it with a hand-written rule; both
///   ctor fields may be null.
///
/// The `infer` function receives the op AST node itself, not the
/// surrounding [Pipe] — callers must destructure the specific op type
/// they expect. Since [PipeOpInfo] is looked up by AST runtime type,
/// the match is exhaustive at registration time.
typedef PipeOpInfo =
    ({
      String name,
      bool Function(Shape input) accepts,
      Shape Function(Shape input, LamExpr op) infer,
      PipeOpParseKind parseKind,
      LamExpr Function()? zeroArgCtor,
      LamExpr Function(LamExpr)? oneArgCtor,
    });

/// Look up the spec for a pipe-op AST node, or `null` if [node] is not
/// a pipe op.
///
/// Returns `null` for non-op expressions that happen to appear on the
/// right-hand side of a pipe (object constructors, literals, etc.).
/// The shape inference and completer code paths that consume the spec
/// must handle `null` by falling back to generic expression inference.
PipeOpInfo? pipeOpInfoFor(LamExpr node) => switch (node) {
  FilterOp _ => _filterSpec,
  MapOp _ => _mapSpec,
  SortOp _ => _sortSpec,
  ReverseOp _ => _reverseSpec,
  KeysOp _ => _keysSpec,
  ValuesOp _ => _valuesSpec,
  LengthOp _ => _lengthSpec,
  FirstOp _ => _firstSpec,
  LastOp _ => _lastSpec,
  SumOp _ => _sumSpec,
  AvgOp _ => _avgSpec,
  MinOp _ => _minSpec,
  MaxOp _ => _maxSpec,
  SortByOp _ => _sortBySpec,
  GroupByOp _ => _groupBySpec,
  UniqueOp _ => _uniqueSpec,
  UniqueByOp _ => _uniqueBySpec,
  FlattenOp _ => _flattenSpec,
  FilterValuesOp _ => _filterValuesSpec,
  MapValuesOp _ => _mapValuesSpec,
  FilterKeysOp _ => _filterKeysSpec,
  HasOp _ => _hasSpec,
  ToEntriesOp _ => _toEntriesSpec,
  FromEntriesOp _ => _fromEntriesSpec,
  ToNumberOp _ => _toNumberSpec,
  TypeOp _ => _typeSpec,
  As _ => _asSpec,
  _ => null,
};

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
Shape inferPipeOpShape(Shape input, LamExpr op) {
  final info = pipeOpInfoFor(op);
  if (info == null) return const SAny();
  if (!info.accepts(input)) return const SAny();
  return info.infer(input, op);
}

// Sentinel specs. Each is a one-shot record whose `infer` closes over
// its own op-type expectations; the AST parameter is destructured
// where needed (parameterized ops only).
//
// Conventions:
// - `identity` in `infer` means "this op does not change the shape"
//   (e.g. `sort` on a list). Ops whose output shape equals the input
//   shape by design use this.
// - For ops that only work on one shape kind, `accepts` is the
//   positive predicate and `infer` can rely on the input matching.
//   [inferPipeOpShape] has already gated on `accepts`, so the pattern
//   match on `input` is exhaustive against the accepted cases.

// Every predicate treats [SAny] as accepted. Inference cannot prove
// an SAny input will fail at runtime, so rejecting it would hide
// correct candidates from the completer — a violation of the
// design invariant documented at the top of this file.
//
// Putting the SAny check inside every predicate, rather than at the
// call site, keeps the invariant a property of the spec table
// itself: any new spec defined via these helpers inherits it.

bool _acceptsList(Shape s) => s is SList || s is SAny;
bool _acceptsMap(Shape s) => s is SMap || s is SAny;
bool _acceptsListOrMap(Shape s) => s is SList || s is SMap || s is SAny;
bool _acceptsListMapOrString(Shape s) =>
    s is SList || s is SMap || s is SString || s is SAny;
bool _acceptsStringOrNum(Shape s) => s is SString || s is SNum || s is SAny;
bool _acceptsAny(Shape _) => true;

// --- List-consuming ops --------------------------------------------

final PipeOpInfo _filterSpec = (
  name: 'filter',
  accepts: _acceptsList,
  // `filter` preserves the list-of-elements shape.
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: FilterOp.new,
);

final PipeOpInfo _mapSpec = (
  name: 'map',
  accepts: _acceptsList,
  infer:
      (input, op) => switch ((input, op)) {
        (SList(element: final e), MapOp(:final transform)) => SList(
          _inferSubExpr(transform, e),
        ),
        _ => const SAny(),
      },
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: MapOp.new,
);

final PipeOpInfo _sortSpec = (
  name: 'sort',
  accepts: _acceptsList,
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: SortOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _reverseSpec = (
  name: 'reverse',
  accepts: _acceptsList,
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: ReverseOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _sortBySpec = (
  name: 'sort_by',
  accepts: _acceptsList,
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: SortByOp.new,
);

final PipeOpInfo _uniqueSpec = (
  name: 'unique',
  accepts: _acceptsList,
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: UniqueOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _uniqueBySpec = (
  name: 'unique_by',
  accepts: _acceptsList,
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: UniqueByOp.new,
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
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: FlattenOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _firstSpec = (
  name: 'first',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: FirstOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _lastSpec = (
  name: 'last',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: LastOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _sumSpec = (
  name: 'sum',
  accepts: _acceptsList,
  infer: (_, _) => const SNum(),
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: SumOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _avgSpec = (
  name: 'avg',
  accepts: _acceptsList,
  infer: (_, _) => const SNum(),
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: AvgOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _minSpec = (
  name: 'min',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: MinOp.new,
  oneArgCtor: null,
);

final PipeOpInfo _maxSpec = (
  name: 'max',
  accepts: _acceptsList,
  infer:
      (input, _) => switch (input) {
        SList(element: final e) => e,
        _ => const SAny(),
      },
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: MaxOp.new,
  oneArgCtor: null,
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
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: GroupByOp.new,
);

final PipeOpInfo _fromEntriesSpec = (
  name: 'from_entries',
  accepts: _acceptsList,
  // Runtime keys are dynamic, so the resulting map has no known fields.
  // Callers that only need to know "is it a map" (e.g. TOML/HCL
  // writability) still get a correct answer.
  infer: (_, _) => const SMap(<String, Shape>{}),
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: FromEntriesOp.new,
  oneArgCtor: null,
);

// --- Map-consuming ops ---------------------------------------------

final PipeOpInfo _filterValuesSpec = (
  name: 'filter_values',
  accepts: _acceptsMap,
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: FilterValuesOp.new,
);

final PipeOpInfo _mapValuesSpec = (
  name: 'map_values',
  accepts: _acceptsMap,
  infer:
      (input, op) => switch ((input, op)) {
        (SMap(fields: final fields), MapValuesOp(:final transform)) => SMap({
          for (final MapEntry(:key, :value) in fields.entries)
            key: _inferSubExpr(transform, value),
        }),
        _ => const SAny(),
      },
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: MapValuesOp.new,
);

final PipeOpInfo _filterKeysSpec = (
  name: 'filter_keys',
  accepts: _acceptsMap,
  infer: (input, _) => input,
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: FilterKeysOp.new,
);

final PipeOpInfo _hasSpec = (
  name: 'has',
  accepts: _acceptsMap,
  infer: (_, _) => const SBool(),
  parseKind: PipeOpParseKind.oneArg,
  zeroArgCtor: null,
  oneArgCtor: HasOp.new,
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
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: ToEntriesOp.new,
  oneArgCtor: null,
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
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: KeysOp.new,
  oneArgCtor: null,
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
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: ValuesOp.new,
  oneArgCtor: null,
);

// --- List, map, or string ------------------------------------------

final PipeOpInfo _lengthSpec = (
  name: 'length',
  accepts: _acceptsListMapOrString,
  infer: (_, _) => const SNum(),
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: LengthOp.new,
  oneArgCtor: null,
);

// --- String or number ----------------------------------------------

final PipeOpInfo _toNumberSpec = (
  name: 'to_number',
  accepts: _acceptsStringOrNum,
  infer: (_, _) => const SNum(),
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: ToNumberOp.new,
  oneArgCtor: null,
);

// --- Universal ops -------------------------------------------------

final PipeOpInfo _typeSpec = (
  name: 'type',
  accepts: _acceptsAny,
  infer: (_, _) => const SString(),
  parseKind: PipeOpParseKind.zeroArg,
  zeroArgCtor: TypeOp.new,
  oneArgCtor: null,
);

/// `as(target)` is structurally universal: it accepts any shape and
/// returns the input shape when already writable, or [SAny] when the
/// bridging path is ambiguous or missing. The concrete logic lives in
/// [inferShape] because it needs access to `synthesize`, which this
/// module does not import to avoid a cycle. `infer` here returns
/// [SAny] as a safe default; the real computation happens in
/// `infer.dart` for the [As] case.
///
/// `parseKind` is `custom` because `as(fmt)` takes a keyword set
/// (`json`, `yaml`, etc.) rather than an arbitrary expression — the
/// generic `oneArg` rule cannot express that. The parser hand-writes
/// `_asOp` and this spec provides the name/shape metadata only.
final PipeOpInfo _asSpec = (
  name: 'as',
  accepts: _acceptsAny,
  infer: (_, _) => const SAny(),
  parseKind: PipeOpParseKind.custom,
  zeroArgCtor: null,
  oneArgCtor: null,
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
