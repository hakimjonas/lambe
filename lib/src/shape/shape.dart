/// Structural shape of a value, independent of its contents.
///
/// A [Shape] describes the kind of a value (scalar, list, map) and, for
/// containers, the shape of their contents. Use [shapeOf] to infer the
/// shape of a value, and [Shape]-aware APIs such as `canWriteShapeAs` or
/// `inferShape` to reason about compatibility with output formats or with
/// query pipelines.
///
/// Shape inference is structural and intentionally lossy:
/// - Heterogeneous lists collapse to `SList(SAny())`.
/// - Empty containers carry [SAny] as their element, or no fields.
/// - Shapes never carry actual values, only structural facts.
library;

/// The structural shape of a value.
///
/// Sealed hierarchy with concrete subclasses [SAny], [SNull], [SBool],
/// [SNum], [SString], [SList], and [SMap]. Exhaustive `switch` on [Shape]
/// is supported and recommended.
sealed class Shape {
  /// Creates a new [Shape]. Use the concrete subclasses.
  const Shape();
}

/// Unknown or mixed shape.
///
/// Used for the element shape of empty or heterogeneous lists, and for
/// values whose structural kind cannot be determined. [SAny] is accepted
/// by every [ShapeRequirement]: when the shape is unknown, callers
/// cannot safely reject.
final class SAny extends Shape {
  /// Creates an [SAny] shape.
  const SAny();

  @override
  bool operator ==(Object other) => other is SAny;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'any';
}

/// Shape of a `null` value.
final class SNull extends Shape {
  /// Creates an [SNull] shape.
  const SNull();

  @override
  bool operator ==(Object other) => other is SNull;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'null';
}

/// Shape of a boolean value.
final class SBool extends Shape {
  /// Creates an [SBool] shape.
  const SBool();

  @override
  bool operator ==(Object other) => other is SBool;

  @override
  int get hashCode => 2;

  @override
  String toString() => 'bool';
}

/// Shape of a numeric value (int or double, unified).
final class SNum extends Shape {
  /// Creates an [SNum] shape.
  const SNum();

  @override
  bool operator ==(Object other) => other is SNum;

  @override
  int get hashCode => 3;

  @override
  String toString() => 'number';
}

/// Shape of a string value.
final class SString extends Shape {
  /// Creates an [SString] shape.
  const SString();

  @override
  bool operator ==(Object other) => other is SString;

  @override
  int get hashCode => 4;

  @override
  String toString() => 'string';
}

/// Shape of a list, with the shape of its elements.
///
/// The [element] is the shape of all elements if they agree, or [SAny] if
/// the list is empty or contains mixed shapes.
///
/// [sampledKinds] is non-null only when [element] is [SAny] *because of
/// observed heterogeneity* (mixed types in the sample), and lists the
/// distinct observed element shapes. It is null for the empty-list case
/// (no observations) and for any [SList] whose element is not [SAny].
/// Renderers and explainers can use it to surface what was actually
/// seen, without having to re-walk the source data.
final class SList extends Shape {
  /// Shape of each element. [SAny] for empty or heterogeneous lists.
  final Shape element;

  /// Distinct observed element shapes, when [element] is [SAny] due to
  /// heterogeneity. Null when not applicable.
  final List<Shape>? sampledKinds;

  /// Creates an [SList] shape with the given [element] shape.
  const SList(this.element, {this.sampledKinds});

  @override
  bool operator ==(Object other) =>
      other is SList &&
      other.element == element &&
      _kindsEqual(other.sampledKinds, sampledKinds);

  @override
  int get hashCode => Object.hash('list', element, _kindsHash(sampledKinds));

  @override
  String toString() => 'list<$element>';
}

bool _kindsEqual(List<Shape>? a, List<Shape>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _kindsHash(List<Shape>? kinds) {
  if (kinds == null) return 0;
  return Object.hashAll(kinds);
}

/// Shape of a map, with the shape of each known field.
///
/// [SMap] preserves field order (insertion order), which matches Dart's
/// default map iteration order and makes shape rendering stable. Empty
/// maps have an empty [fields] map; they remain valid as map-shaped
/// targets for formats that require a map root.
final class SMap extends Shape {
  /// Shape of each known field, in insertion order.
  final Map<String, Shape> fields;

  /// Creates an [SMap] shape with the given [fields].
  const SMap(this.fields);

  @override
  bool operator ==(Object other) {
    if (other is! SMap) return false;
    if (other.fields.length != fields.length) return false;
    for (final MapEntry(:key, :value) in fields.entries) {
      if (!other.fields.containsKey(key)) return false;
      if (other.fields[key] != value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
    fields.entries.map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() {
    if (fields.isEmpty) return 'map<>';
    final entries = fields.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');
    return 'map<$entries>';
  }
}

/// A value that may be absent. Used for JSON Schema properties not
/// listed in `required`, and any other statically-known optionality.
///
/// Optional appears in the shape system to let schema-declared
/// absences be represented faithfully. At evaluation time, an
/// optional field that's absent produces null through Lambe's usual
/// null-propagation; the query language itself is unchanged. The
/// variant's purpose is purely to sharpen [explain] and writer
/// compatibility checks: an optional field accessed without a null
/// guard produces a runtime-rejection warning during static analysis.
///
/// Nested optionality collapses: `SOptional(SOptional(x))` is
/// semantically identical to `SOptional(x)`. Constructors enforce
/// this by unwrapping.
final class SOptional extends Shape {
  /// The shape of the value when present.
  final Shape inner;

  /// Creates an [SOptional] shape.
  ///
  /// If [inner] is itself [SOptional], unwraps to avoid nested
  /// optionality.
  factory SOptional(Shape inner) =>
      inner is SOptional ? inner : SOptional._(inner);

  const SOptional._(this.inner);

  @override
  bool operator ==(Object other) => other is SOptional && other.inner == inner;

  @override
  int get hashCode => Object.hash('optional', inner);

  @override
  String toString() => 'optional<$inner>';
}

/// Infer the structural [Shape] of [value].
///
/// Recurses through lists and maps. Lists are sampled rather than fully
/// walked: if the first few elements agree on shape, the returned
/// [SList] carries that element shape; otherwise the element is [SAny].
/// Sampling keeps inference cost bounded by structure depth rather than
/// by total element count.
///
/// Heterogeneity detection is local to the sampling window. A list whose
/// first elements share a shape but whose later elements differ may
/// still report the first element's shape. Callers that require exact
/// per-row shape information should walk the list themselves.
Shape shapeOf(Object? value) {
  if (value == null) return const SNull();
  if (value is bool) return const SBool();
  if (value is num) return const SNum();
  if (value is String) return const SString();
  if (value is List<Object?>) return _listShape(value);
  if (value is Map<String, Object?>) return _mapShape(value);
  return const SAny();
}

Shape _listShape(List<Object?> list) {
  if (list.isEmpty) return const SList(SAny());
  final first = shapeOf(list.first);
  final limit =
      list.length < _heteroSampleLimit ? list.length : _heteroSampleLimit;
  for (var i = 1; i < limit; i++) {
    final next = shapeOf(list[i]);
    if (next != first) {
      // Heterogeneous: collect distinct shapes from the sample so the
      // schema renderer can describe what was observed instead of just
      // saying "may be heterogeneous." Stable insertion order, by-equality
      // dedup; cheap because limit is bounded by [_heteroSampleLimit].
      final kinds = <Shape>[first];
      for (var j = 1; j < limit; j++) {
        final k = shapeOf(list[j]);
        if (!kinds.contains(k)) kinds.add(k);
      }
      return SList(const SAny(), sampledKinds: kinds);
    }
  }
  return SList(first);
}

Shape _mapShape(Map<String, Object?> map) => SMap({
  for (final MapEntry(:key, :value) in map.entries) key: shapeOf(value),
});

/// Maximum number of list elements sampled by [shapeOf] when checking for
/// homogeneous element shape.
const int _heteroSampleLimit = 8;

/// Human-readable rendering of a [Shape].
///
/// Equivalent to [Shape.toString], provided as a function for callers that
/// prefer `renderShape(s)` over `s.toString()`.
String renderShape(Shape shape) => shape.toString();

/// Serialize [shape] as a JSON-shaped `Map<String, Object?>` tree.
///
/// Every shape is a map with a `kind` discriminator. List shapes carry
/// `element` (a nested shape). Map shapes carry `fields` (a
/// `Map<String, Object?>` of field-name to nested shape). Scalars carry
/// only the kind. The output is intended for `--explain-json` and
/// other programmatic consumers that want to reason about shape
/// structure without re-parsing the `renderShape` text form.
///
/// ```
/// shapeToJson(SList(SMap({'a': SNum()})))
/// // {
/// //   "kind": "list",
/// //   "element": {
/// //     "kind": "map",
/// //     "fields": {"a": {"kind": "number"}}
/// //   }
/// // }
/// ```
Map<String, Object?> shapeToJson(Shape shape) => switch (shape) {
  SAny() => const {'kind': 'any'},
  SNull() => const {'kind': 'null'},
  SBool() => const {'kind': 'bool'},
  SNum() => const {'kind': 'number'},
  SString() => const {'kind': 'string'},
  SList(:final element) => {'kind': 'list', 'element': shapeToJson(element)},
  SMap(:final fields) => {
    'kind': 'map',
    'fields': {
      for (final MapEntry(:key, :value) in fields.entries)
        key: shapeToJson(value),
    },
  },
  SOptional(:final inner) => {'kind': 'optional', 'inner': shapeToJson(inner)},
};
