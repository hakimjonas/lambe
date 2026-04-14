/// Lambé MCP server: exposes query, schema, and assert tools to AI agents.
///
/// Run with: `dart run bin/mcp_server.dart`
/// Or install: `dart pub global activate lambe` → `lam-mcp`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:lambe/lambe.dart';

void main() {
  LambeServer(stdioChannel(input: io.stdin, output: io.stdout));
}

/// MCP server providing Lambé query tools to AI agents.
base class LambeServer extends MCPServer with ToolsSupport {
  /// Creates a Lambé MCP server connected to the given [channel].
  LambeServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(name: 'lambe', version: '0.1.0'),
        instructions:
            'Lambé is a universal query language for structured data. '
            'Use the query tool to find, extract, filter, transform, or look up '
            'values from JSON, YAML, TOML, or HCL files. '
            'Use the schema tool to understand data structure before querying. '
            'Use the assert tool to validate or check conditions on data.\n\n'
            'Common patterns:\n'
            '  .database.host                          — extract a value\n'
            '  .users | filter(.age > 30) | map(.name) — filter and project\n'
            '  .items | sort_by(.price) | first        — sort and pick\n'
            '  .users | group_by(.role)                 — group by field\n'
            '  .items | map(.price) | sum               — aggregate\n'
            '  .config | has("required_field")           — check existence\n',
      ) {
    registerTool(_queryTool, _handleQuery);
    registerTool(_schemaTool, _handleSchema);
    registerTool(_assertTool, _handleAssert);
  }

  // --------------------------------------------------------------------------
  // Tool: query
  // --------------------------------------------------------------------------

  final _queryTool = Tool(
    name: 'lambe_query',
    description:
        'Use this tool when the user asks to find, extract, filter, query, get, '
        'look up, check, or transform data from JSON, YAML, TOML, HCL, or any '
        'structured configuration file. Supports property chains (.users[0].name), '
        'pipeline operations (filter, map, sort_by, group_by, unique, flatten), '
        'aggregation (sum, avg, min, max, length), arithmetic, comparisons, '
        'conditionals (if/then/else), object construction ({name, total: .price * .qty}), '
        'and string interpolation ("\\(.name) is \\(.age)").',
    inputSchema: Schema.object(
      properties: {
        'expression': Schema.string(
          description:
              'The Lambe query expression. Syntax reference:\n'
              '\n'
              'Field access and indexing:\n'
              '  ".name"                                   — field access\n'
              '  ".users[0].name"                          — index then field\n'
              '  ".tags[-1]"                               — negative index\n'
              '  ".tags[1:3]"                              — slice\n'
              '\n'
              'Pipeline operations (| passes left result as context):\n'
              '  ".users | filter(.age > 30) | map(.name)" — filter and project\n'
              '  ".items | sort_by(.price) | first"        — sort and pick\n'
              '  ".items | map(.price) | sum"              — aggregate\n'
              '  ".users | group_by(.dept)"                — group by field\n'
              '  ".users | unique_by(.role) | length"      — deduplicate\n'
              '\n'
              'Object construction (| pipes into {}):\n'
              '  ".users[0] | {name, age}"                 — project fields\n'
              '  ".users | map({name, senior: .age > 65})" — transform to new shape\n'
              '\n'
              'Conditionals and string interpolation:\n'
              '  ".users | map(if .active then \\"yes\\" else \\"no\\")" — conditional\n'
              '  ".users | map(\\"\\\\(.name): \\\\(.age)\\")"          — interpolation\n'
              '\n'
              'Aggregation: sum, avg, min, max, length, first, last\n'
              'Map operations: keys, values, has("key"), to_entries, from_entries\n'
              'Map transforms: filter_values(pred), map_values(expr), filter_keys(pred)\n'
              '\n'
              'Null propagation: .missing returns null, null | op returns null.\n'
              'Arithmetic on null throws. Use .field == null to test.\n',
        ),
        'data': Schema.string(
          description: 'The input data as a string (JSON, YAML, TOML, or HCL)',
        ),
        'format': UntitledSingleSelectEnumSchema(
          description:
              'Input format: json, yaml, toml, hcl. '
              'Auto-detected from content if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl'],
        ),
      },
      required: ['expression', 'data'],
    ),
  );

  FutureOr<CallToolResult> _handleQuery(CallToolRequest request) {
    final args = request.arguments!;
    final expression = args['expression'] as String;
    final data = args['data'] as String;
    final formatStr = args['format'] as String?;

    try {
      final format = formatStr != null ? Format.values.byName(formatStr) : null;
      final result = queryString(expression, data, format: format);
      return CallToolResult(
        content: [
          TextContent(text: const JsonEncoder.withIndent('  ').convert(result)),
        ],
      );
    } on QueryError catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Error: $e')],
        isError: true,
      );
    } on FormatException catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Parse error: ${e.message}')],
        isError: true,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Tool: schema
  // --------------------------------------------------------------------------

  final _schemaTool = Tool(
    name: 'lambe_schema',
    description:
        'Use this tool to understand the structure of unfamiliar data before '
        'writing queries. Returns type names (string, number, boolean, null) '
        'instead of actual values. Use when the user says "show me the structure", '
        '"what fields are in this", or "what does this data look like".',
    inputSchema: Schema.object(
      properties: {
        'data': Schema.string(
          description: 'The input data as a string (JSON, YAML, TOML, or HCL)',
        ),
        'format': UntitledSingleSelectEnumSchema(
          description: 'Input format. Auto-detected if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl'],
        ),
      },
      required: ['data'],
    ),
  );

  FutureOr<CallToolResult> _handleSchema(CallToolRequest request) {
    final args = request.arguments!;
    final data = args['data'] as String;
    final formatStr = args['format'] as String?;

    try {
      final format = formatStr != null ? Format.values.byName(formatStr) : null;
      final parsed = parseInput(data, format ?? sniffFormat(data));
      final schema = inferSchema(parsed);
      return CallToolResult(
        content: [
          TextContent(text: const JsonEncoder.withIndent('  ').convert(schema)),
        ],
      );
    } on QueryError catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Error: $e')],
        isError: true,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Tool: assert
  // --------------------------------------------------------------------------

  final _assertTool = Tool(
    name: 'lambe_assert',
    description:
        'Use this tool to validate, check, or verify conditions on structured '
        'data. Returns PASS or FAIL. Use when the user says "check that", '
        '"make sure", "verify", or "assert". Examples:\n'
        '  ".version != \\"0.0.0\\""           — check version is set\n'
        '  ".users | length > 0"              — check non-empty\n'
        '  ".config | has(\\"database\\")"     — check field exists\n'
        '  ".replicas >= 2"                   — check minimum value\n',
    inputSchema: Schema.object(
      properties: {
        'expression': Schema.string(
          description: 'The assertion expression (must evaluate to boolean)',
        ),
        'data': Schema.string(description: 'The input data as a string'),
        'format': UntitledSingleSelectEnumSchema(
          description: 'Input format. Auto-detected if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl'],
        ),
      },
      required: ['expression', 'data'],
    ),
  );

  FutureOr<CallToolResult> _handleAssert(CallToolRequest request) {
    final args = request.arguments!;
    final expression = args['expression'] as String;
    final data = args['data'] as String;
    final formatStr = args['format'] as String?;

    try {
      final format = formatStr != null ? Format.values.byName(formatStr) : null;
      final result = queryString(expression, data, format: format);

      if (result == true) {
        return CallToolResult(content: [TextContent(text: 'PASS')]);
      } else if (result == false) {
        return CallToolResult(content: [TextContent(text: 'FAIL')]);
      } else {
        return CallToolResult(
          content: [
            TextContent(
              text:
                  'Error: assertion expression must return boolean, got ${result.runtimeType}: $result',
            ),
          ],
          isError: true,
        );
      }
    } on QueryError catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Error: $e')],
        isError: true,
      );
    }
  }
}
