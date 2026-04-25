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
}
