/// Output format enumeration shared across the serializer, the shape
/// compatibility checker, and the error hierarchy.
library;

/// Supported output formats for `--to`.
enum OutputFormat {
  /// JSON output (default).
  json,

  /// YAML output.
  yaml,

  /// TOML output (root must be a map).
  toml,

  /// CSV output (root must be a list of maps or list of lists).
  csv,

  /// TSV output (tab-separated, same structure as CSV).
  tsv,

  /// HCL output (root must be a map).
  hcl,

  /// HOCON output. Every JSON document is valid HOCON, so the value is
  /// emitted in standard JSON form (pretty by default) — see
  /// [OutputFormat.hocon] notes in the formatOutput doc.
  hocon,
}

/// Names of all supported output formats, derived from
/// [OutputFormat.values].
///
/// Single source of truth for CLI option validation, MCP schema enums,
/// REPL help text, and completion lists.
List<String> outputFormatNames() => [
  for (final f in OutputFormat.values) f.name,
];

/// Policy for handling non-scalar cells in CSV/TSV output.
///
/// Delimited formats project rows onto a flat grid of scalar cells. A
/// list-of-maps whose cells hold nested lists or maps has no faithful
/// delimited rendering. This policy controls what the writer does when
/// it encounters such a cell, and correspondingly widens what
/// [requirementFor] accepts at shape-check time.
enum CellPolicy {
  /// Refuse to serialize: the shape check rejects non-scalar element
  /// shapes, and the writer's defensive guard throws when a non-scalar
  /// cell slips past (for example via [SAny]). This is the 0.8.0
  /// default and the safest choice.
  refuse,

  /// Encode non-scalar cells as JSON strings inline. The shape check
  /// accepts any list at the root; the writer JSON-encodes list- or
  /// map-valued cells rather than refusing them. Round-tripping the
  /// resulting CSV back into Lambë does not recover the original
  /// structure; this is an output-side escape hatch, not a faithful
  /// encoding.
  json,
}
