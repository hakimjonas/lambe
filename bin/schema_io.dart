/// CLI-only schema file loaders.
///
/// Lives in bin/ rather than lib/ so the published library has zero
/// `dart:io` imports — making it safely usable from `dart compile wasm`
/// and dart2js consumers (e.g. the lambë playground in arda-web).
///
/// The pure schema-merge logic stays in `lib/src/schema/loader.dart` as
/// [mergeSchemaWithData]; only the path-based loaders moved.
library;

import 'dart:io';

import 'package:lambe/lambe.dart';

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
