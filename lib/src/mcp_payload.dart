/// MCP payload rendering for structured errors.
///
/// The functions here produce JSON strings intended to be returned as
/// the text content of an MCP `CallToolResult`'s error response. They
/// are pure (no I/O, no process state) so tests can pin the payload
/// shape without running the server.
library;

import 'dart:convert';

import 'errors.dart';
import 'shape/shape.dart' show renderShape;

/// Render an [OutputShapeError] as a JSON payload for agent consumption.
///
/// The payload has keys `error`, `message`, `format`, `got_shape`,
/// `original_expression`, `suggestions`, and `hints`. Each entry in
/// `suggestions` carries a 1-based `id`, a `label`, a `template_text`
/// (the query-fragment source), an `apply_as` (the complete query
/// formed by appending the template to the original expression via
/// `|`), and an `explanation`.
///
/// `hints` describes environmental remedies (tool parameters) that
/// would resolve the mismatch without changing the query. Each hint
/// carries a `label`, a `parameter`/`value` pair naming an argument of
/// this MCP tool, and an `explanation`. CLI-flag and REPL-command
/// forms are omitted because they do not apply to an agent calling the
/// MCP server. Empty when no such remedy exists.
String renderMcpShapeErrorPayload(OutputShapeError e, String expression) =>
    const JsonEncoder.withIndent('  ').convert({
      'error': 'output_shape_mismatch',
      'message': e.message,
      'format': e.format.name,
      'got_shape': renderShape(e.got),
      'original_expression': expression,
      'suggestions': [
        for (var i = 0; i < e.suggestions.length; i++)
          {
            'id': i + 1,
            'label': e.suggestions[i].label,
            'template_text': e.suggestions[i].display,
            'apply_as': '$expression | ${e.suggestions[i].display}',
            'explanation': e.suggestions[i].explanation,
          },
      ],
      'hints': [
        for (final h in e.hints)
          {
            'label': h.label,
            'parameter': h.mcpParameter.$1,
            'value': h.mcpParameter.$2,
            'explanation': h.explanation,
          },
      ],
    });
