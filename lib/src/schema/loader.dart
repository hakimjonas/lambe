/// Load and merge schemas for the `--schema` entry point.
///
/// [loadSchemaFromFile] reads a schema file (JSON) and returns the
/// parsed [Shape], after a JSON-Schema-looking sanity check.
/// [loadSchemaForData] adds sibling auto-detection: given a data file
/// path, it looks for `<datafile>.schema.json` next to it and loads
/// that when present.
///
/// [mergeSchemaWithData] combines a user-declared schema with the
/// shape inferred from actual data. See `doc/schema-design.md` section
/// on "Disagreement semantics" for the rules; the short version is
/// "schema augments, never contradicts" — agreements pass, schema
/// fills in what data can't express (empty-list elements, optional
/// fields), concrete-type disagreements error at load time.
library;

import 'dart:io';

import '../errors.dart';
import '../shape/shape.dart';
import 'parser.dart';

/// Load a schema from a file path, parsing it as a JSON Schema subset.
///
/// Throws [QueryError] if the file is missing or unreadable, or if
/// the schema parser rejects the content.
Shape loadSchemaFromFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw QueryError('schema file not found: $path');
  }
  final source = file.readAsStringSync();
  return parseJsonSchema(source);
}

/// Load a schema for [dataPath], preferring [explicitSchemaPath] when
/// provided and falling back to a `<dataPath>.schema.json` sibling.
///
/// Returns `null` when no explicit path is given and no sibling
/// exists. Throws [QueryError] for explicit paths that fail to load.
Shape? loadSchemaForData({String? explicitSchemaPath, String? dataPath}) {
  if (explicitSchemaPath != null) {
    return loadSchemaFromFile(explicitSchemaPath);
  }
  if (dataPath != null) {
    final sibling = _siblingSchemaPath(dataPath);
    if (sibling != null && File(sibling).existsSync()) {
      return loadSchemaFromFile(sibling);
    }
  }
  return null;
}

/// Compute the sibling schema path for [dataPath].
///
/// Strips the data file's extension and appends `.schema.json`:
/// `data.json` → `data.schema.json`, `events.ndjson` → `events.schema.json`.
/// Returns `null` for paths without a recognizable extension.
String? _siblingSchemaPath(String dataPath) {
  final lastDot = dataPath.lastIndexOf('.');
  if (lastDot < 0) return null;
  final base = dataPath.substring(0, lastDot);
  return '$base.schema.json';
}

/// Merge a schema-declared [schema] shape with a data-inferred [data]
/// shape. Schema augments data:
///
/// - Both agree on a concrete type: that type.
/// - Either side is [SAny]: use the other side.
/// - Schema-only field: keep the schema's shape (possibly optional).
/// - Data-only field: use the data's shape.
/// - Schema optional + data present: strip optional, use the merged
///   inner shape (the field is definitely there for this run).
/// - List elements merge recursively; empty-data lists take the
///   schema's element.
///
/// Throws [QueryError] with a JSON-path when schema and data disagree
/// on a concrete type. Error path is rooted at `$` (the whole value).
Shape mergeSchemaWithData(Shape schema, Shape data) =>
    _merge(schema, data, r'$');

Shape _merge(Shape schema, Shape data, String path) {
  // SAny: the other side wins. Both-any falls through to equality
  // below.
  if (schema is SAny) return data;
  if (data is SAny) return schema;

  // Optional handling. Schema-side optional: if data has the value,
  // strip the optional and merge inners; if data is null, keep the
  // schema's optional as-is (field may still be absent at other call
  // sites, though this particular data has null for it).
  if (schema is SOptional) {
    if (data is SNull) return schema;
    return _merge(schema.inner, data, path);
  }
  if (data is SOptional) {
    // Data is never an SOptional from shapeOf (shapeOf has no
    // optionality signal). Included for defensive symmetry.
    return _merge(schema, data.inner, path);
  }

  if (schema is SList) {
    if (data is! SList) {
      throw _disagree(path, schema, data);
    }
    return SList(_merge(schema.element, data.element, '$path[*]'));
  }

  if (schema is SMap) {
    if (data is! SMap) {
      throw _disagree(path, schema, data);
    }
    return _mergeMaps(schema, data, path);
  }

  // Scalar shapes: must match, or disagree.
  if (schema.runtimeType == data.runtimeType) {
    return schema;
  }
  throw _disagree(path, schema, data);
}

Shape _mergeMaps(SMap schema, SMap data, String path) {
  final merged = <String, Shape>{};

  // Schema fields: merge with data if present, keep as-is otherwise.
  for (final MapEntry(:key, value: schemaField) in schema.fields.entries) {
    final dataField = data.fields[key];
    if (dataField == null) {
      merged[key] = schemaField;
      continue;
    }
    merged[key] = _merge(schemaField, dataField, '$path.$key');
  }

  // Data-only fields: pass through unchanged. Schema is a partial
  // description by design; extras are fine.
  for (final MapEntry(:key, value: dataField) in data.fields.entries) {
    if (!schema.fields.containsKey(key)) {
      merged[key] = dataField;
    }
  }

  return SMap(merged);
}

QueryError _disagree(String path, Shape schema, Shape data) => QueryError(
  'schema disagreement at $path: schema says ${renderShape(schema)}, '
  'data is ${renderShape(data)}',
);
