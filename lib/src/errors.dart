/// Error types for query parsing and evaluation.
library;

/// Error thrown during query evaluation.
///
/// Wraps type errors, missing fields, index-out-of-bounds, and other
/// runtime failures that occur while evaluating a query against data.
class QueryError implements Exception {
  /// The error message.
  final String message;

  /// Creates a [QueryError] with [message].
  const QueryError(this.message);

  @override
  String toString() => 'QueryError: $message';
}
