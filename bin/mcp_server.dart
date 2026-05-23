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
        implementation: Implementation(name: 'lambe', version: lambeVersion),
        instructions:
            'Lambé is a multi-format query language for structured data. '
            'Use lambe_query to find, extract, filter, transform, or look up '
            'values from JSON, YAML, TOML, HCL, CSV, TSV, or Markdown files. '
            'Use lambe_print_shape to understand data structure before '
            'querying (returns JSON Schema). '
            'Use lambe_check to validate data against a JSON Schema. '
            'Use lambe_explain to trace a query statically before running '
            'it (returns a structured JSON report of shape at each stage). '
            'Use lambe_assert to validate or check conditions on data.\n\n'
            'Common patterns:\n'
            '  .database.host                          — extract a value\n'
            '  .users | filter(.age > 30) | map(.name) — filter and project\n'
            '  .items | sort_by(.price) | first        — sort and pick\n'
            '  .users | group_by(.role)                — group by field\n'
            '  .items | map(.price) | sum              — aggregate\n'
            '  . | has("required_field")               — check existence\n'
            '\n'
            'Common mistakes:\n'
            '  - Use && and || for boolean logic, not "and"/"or":\n'
            '      .users | filter(.age > 30 && .active)\n'
            '  - Hyphenated or dotted keys need bracket syntax:\n'
            '      .project["optional-dependencies"].dev\n'
            '      (not .project."optional-dependencies")\n'
            '  - group_by returns [{key, values}], a LIST of records (not a map).\n'
            '    Consume with map(...), not to_entries:\n'
            '      .users | group_by(.role)\n'
            '             | map({role: .key, count: .values | length})\n'
            '  - Null propagates through navigation but throws on arithmetic.\n'
            '    Use .field == null to test for missing fields.\n'
            '\n'
            'Markdown data model:\n'
            'Markdown is parsed into an AST of typed nodes. The root is '
            '{type: "document", children: [...]}. Each node has a "type" field '
            'and container nodes have "children". Node types: heading (level, '
            'children), paragraph (children), list (ordered, tight, items), '
            'list_item (children), code_block (language, code), blockquote '
            '(children), link (href, title, children), image (src, alt, title), '
            'emphasis (children), strong (children), text (text), code (code), '
            'thematic_break, hard_break, soft_break, html_block (html), '
            'html_inline (html). Links and images are inline nodes nested '
            'inside heading/paragraph children. Use the `text` pipe op to '
            'extract prose from any node tree (it walks children recursively '
            'and concatenates text/code/code_block/image.alt leaves) — '
            '`.children[0].text` only sees the first immediate child and '
            'misses nested emphasis, links, and inline code.\n'
            '\n'
            'Markdown query patterns:\n'
            '  .children | filter(.type == "heading") | map(text)\n'
            '    — extract all heading texts (handles nested formatting)\n'
            '  .children | filter(.type == "heading") | map({level, title: text})\n'
            '    — headings with levels\n'
            '  .children | filter(.type == "code_block") | map(.language)\n'
            '    — list code block languages\n'
            '  .children | filter(.type == "code_block" && .language == "python") | map(.code)\n'
            '    — code blocks for one language\n'
            '  . | text\n'
            '    — entire document as plain prose\n',
      ) {
    registerTool(_queryTool, _handleQuery);
    registerTool(_printShapeTool, _handlePrintShape);
    registerTool(_checkTool, _handleCheck);
    registerTool(_explainTool, _handleExplain);
    registerTool(_assertTool, _handleAssert);
  }

  /// Build an error-shaped [CallToolResult] (`isError: true`) wrapping
  /// [message]. Centralises the boilerplate at every handler's catch
  /// site.
  CallToolResult _errorResult(String message) =>
      CallToolResult(content: [TextContent(text: message)], isError: true);

  final _queryTool = Tool(
    name: 'lambe_query',
    description:
        'Use this tool when the user asks to find, extract, filter, query, '
        'get, look up, check, or transform data from JSON, YAML, TOML, HCL, '
        'CSV, TSV, Markdown, or any structured configuration file. Supports '
        'property chains (.users[0].name), pipeline operations (filter, map, '
        'sort_by, group_by, unique, flatten), aggregation (sum, avg, min, '
        'max, length), arithmetic, comparisons, boolean logic (&&, ||, !), '
        'conditionals (if/then/else), object construction '
        '({name, total: .price * .qty}), and string interpolation '
        '("\\(.name) is \\(.age)"). Returns JSON by default; pass '
        'output_format to convert to yaml, toml, csv, tsv, or hcl.',
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
              '  ".project[\\"optional-dependencies\\"]"    — bracket syntax for keys\n'
              '                                              with hyphens, spaces, dots\n'
              '\n'
              'Pipeline operations (| passes left result as context):\n'
              '  ".users | filter(.age > 30) | map(.name)" — filter and project\n'
              '  ".items | sort_by(.price) | first"        — sort and pick\n'
              '  ".items | map(.price) | sum"              — aggregate\n'
              '  ".users | group_by(.dept)"                — returns [{key, values}]\n'
              '  ".users | unique_by(.role) | length"      — deduplicate\n'
              '\n'
              'Boolean logic (combine predicates with && / || / !, NOT "and"/"or"):\n'
              '  ".users | filter(.active && .age > 30)"\n'
              '  ".items | filter(.status == \\"open\\" || .priority > 5)"\n'
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
              'group_by output shape:\n'
              '  group_by returns a LIST of {key, values} records, not a map.\n'
              '  Consume with map, not to_entries:\n'
              '    ".users | group_by(.role) | map({role: .key, count: .values | length})"\n'
              '\n'
              'Pipeline ops can also appear as bare expressions with implicit\n'
              '. input, so these are equivalent:\n'
              '  "has(\\"users\\")" ≡ ". | has(\\"users\\")"\n'
              '  "length" ≡ ". | length"\n'
              '  ".users | map(has(\\"email\\"))" ≡ ".users | map(. | has(\\"email\\"))"\n'
              '\n'
              'Markdown queries (data is an AST with typed nodes):\n'
              '  ".children | filter(.type == \\"heading\\") | map(.children[0].text)"\n'
              '    — extract heading texts\n'
              '  ".children | filter(.type == \\"code_block\\") | map({language, code})"\n'
              '    — extract code blocks\n'
              '  ".children | filter(.type == \\"code_block\\" && .language == \\"python\\") | map(.code)"\n'
              '    — code blocks in one language\n'
              '\n'
              'Null propagation: .missing returns null, null | op returns null.\n'
              'Arithmetic on null throws. Use .field == null to test.\n',
        ),
        'data': Schema.string(
          description:
              'The input data as a string (JSON, YAML, TOML, HCL, CSV, TSV, '
              'or Markdown)',
        ),
        'format': UntitledSingleSelectEnumSchema(
          description:
              'Input format: json, yaml, toml, hcl, csv, tsv, markdown. '
              'Auto-detected from content if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl', 'csv', 'tsv', 'markdown'],
        ),
        'output_format': UntitledSingleSelectEnumSchema(
          description:
              'Output format for the query result. Defaults to json. Pick '
              'yaml/toml/hcl for config-shaped results (root must be a map), '
              'csv/tsv for tabular results (root must be a list of maps or '
              'list of lists).',
          values: ['json', 'yaml', 'toml', 'csv', 'tsv', 'hcl'],
        ),
        'flatten_cells': UntitledSingleSelectEnumSchema(
          description:
              'CSV/TSV policy for non-scalar cells. refuse (default) '
              'rejects list- or map-valued cells with a shape error; '
              'json encodes them as JSON strings inline. Ignored for '
              'other output formats.',
          values: ['refuse', 'json'],
        ),
        'schema': Schema.string(
          description:
              'Optional inline JSON Schema subset (as a string) '
              'describing the expected shape of data. When provided, '
              'the data is validated against the schema before the '
              'query runs; a concrete-type disagreement returns an '
              'error. Accepts type, properties, items, required. '
              'Rejects structural combinators, value-level '
              'constraints, references, and additionalProperties with '
              'a per-keyword error.',
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
    final outputFormatStr = args['output_format'] as String?;
    final flattenCellsStr = args['flatten_cells'] as String?;
    final schemaStr = args['schema'] as String?;

    try {
      final format = formatStr != null ? Format.values.byName(formatStr) : null;

      // Validate data against schema first, if provided. A structural
      // disagreement returns an error before the query runs.
      if (schemaStr != null) {
        final schema = parseJsonSchema(schemaStr);
        final parsed = parseInput(data, format ?? sniffFormat(data));
        mergeSchemaWithData(schema, shapeOf(parsed));
      }

      final result = queryString(expression, data, format: format);
      final outputFormat =
          outputFormatStr != null
              ? OutputFormat.values.byName(outputFormatStr)
              : OutputFormat.json;
      final flattenCells =
          flattenCellsStr != null
              ? CellPolicy.values.byName(flattenCellsStr)
              : CellPolicy.refuse;
      final rendered =
          outputFormat == OutputFormat.json
              ? const JsonEncoder.withIndent('  ').convert(result)
              : formatOutput(result, outputFormat, flattenCells: flattenCells);
      return CallToolResult(content: [TextContent(text: rendered)]);
    } on OutputShapeError catch (e) {
      return _errorResult(renderMcpShapeErrorPayload(e, expression));
    } on QueryError catch (e) {
      return _errorResult('Error: ${e.message}');
    } on FormatException catch (e) {
      return _errorResult('Parse error: ${e.message}');
    }
  }

  // See `renderMcpShapeErrorPayload` in package:lambe/lambe.dart for
  // the payload shape this server emits on output-shape mismatches.

  final _printShapeTool = Tool(
    name: 'lambe_print_shape',
    description:
        'Use this tool to understand the structure of unfamiliar data before '
        'writing queries. Returns a JSON Schema subset document '
        '(type/properties/items/required) describing the inferred shape. Use '
        'when the user says "show me the structure", "what fields are in '
        'this", or "what does this data look like". The output round-trips '
        'with the `schema` parameter on lambe_query and with lambe_check. '
        'Renamed from the 0.8.0 lambe_schema tool; output format changed '
        'from type-name strings to JSON Schema.',
    inputSchema: Schema.object(
      properties: {
        'data': Schema.string(
          description:
              'The input data as a string (JSON, YAML, TOML, HCL, CSV, TSV, '
              'or Markdown)',
        ),
        'format': UntitledSingleSelectEnumSchema(
          description: 'Input format. Auto-detected if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl', 'csv', 'tsv', 'markdown'],
        ),
      },
      required: ['data'],
    ),
  );

  FutureOr<CallToolResult> _handlePrintShape(CallToolRequest request) {
    final args = request.arguments!;
    final data = args['data'] as String;
    final formatStr = args['format'] as String?;

    try {
      final format = formatStr != null ? Format.values.byName(formatStr) : null;
      final parsed = parseInput(data, format ?? sniffFormat(data));
      return CallToolResult(
        content: [TextContent(text: renderJsonSchema(shapeOf(parsed)))],
      );
    } on QueryError catch (e) {
      return _errorResult('Error: ${e.message}');
    }
  }

  final _checkTool = Tool(
    name: 'lambe_check',
    description:
        'Validate data against a JSON Schema subset. Use this when the user '
        'wants to verify that data matches an expected shape without '
        'running a query — API response shape checks, CI contract '
        'validation, "does this match the spec". Returns '
        '{"ok": true} on agreement, or '
        '{"ok": false, "error": "..."} naming the disagreement path. '
        'Accepts the same JSON Schema subset as lambe_query\'s schema '
        'parameter: type, properties, items, required. Structural '
        'combinators, value-level constraints, and references are '
        'rejected per-keyword.',
    inputSchema: Schema.object(
      properties: {
        'schema': Schema.string(
          description: 'Inline JSON Schema subset as a string.',
        ),
        'data': Schema.string(
          description:
              'The input data as a string (JSON, YAML, TOML, HCL, CSV, TSV, '
              'or Markdown).',
        ),
        'format': UntitledSingleSelectEnumSchema(
          description: 'Input format. Auto-detected if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl', 'csv', 'tsv', 'markdown'],
        ),
      },
      required: ['schema', 'data'],
    ),
  );

  FutureOr<CallToolResult> _handleCheck(CallToolRequest request) {
    final args = request.arguments!;
    final schemaStr = args['schema'] as String;
    final data = args['data'] as String;
    final formatStr = args['format'] as String?;

    try {
      final schema = parseJsonSchema(schemaStr);
      final format = formatStr != null ? Format.values.byName(formatStr) : null;
      final parsed = parseInput(data, format ?? sniffFormat(data));
      mergeSchemaWithData(schema, shapeOf(parsed));
      return CallToolResult(content: [TextContent(text: '{"ok": true}')]);
    } on QueryError catch (e) {
      return CallToolResult(
        content: [
          TextContent(
            text: const JsonEncoder.withIndent(
              '  ',
            ).convert({'ok': false, 'error': e.message}),
          ),
        ],
      );
    }
  }

  final _explainTool = Tool(
    name: 'lambe_explain',
    description:
        'Use this tool to trace the shape of values flowing through a '
        'Lambe query without running it. Returns a structured JSON '
        'report with one entry per pipe stage (source + inferred shape), '
        'static-analysis warnings (empty filters, runtime rejections, '
        'and optionally trivial results), and the output formats the '
        'final shape can be serialized as. Use before `lambe_query` to '
        'verify a query does what the user expects, or to find out why '
        'an unfamiliar query would fail. Data is optional: without it, '
        'the trace starts from "any" and still catches many classes of '
        'mistake. A schema, when provided, sharpens the trace further.',
    inputSchema: Schema.object(
      properties: {
        'expression': Schema.string(
          description: 'The Lambe query expression to analyze.',
        ),
        'data': Schema.string(
          description:
              'Optional input data. When present, shape inference seeds '
              'from shapeOf(data); without it, the initial shape is '
              '"any".',
        ),
        'format': UntitledSingleSelectEnumSchema(
          description: 'Input format for [data]. Auto-detected if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl', 'csv', 'tsv', 'markdown'],
        ),
        'schema': Schema.string(
          description:
              'Optional inline JSON Schema subset. When provided, the '
              'schema is merged with shapeOf(data) (or used alone when '
              'no data is given) to produce a more precise initial '
              'shape — optional fields and empty-list elements from '
              'the schema become visible in the trace.',
        ),
        'include_trivial': Schema.bool(
          description:
              'When true, includes trivial-result warnings '
              '(sort_by/group_by/map/unique_by on a missing field). '
              'Off by default because legitimate uses exist.',
        ),
        'flatten_cells': UntitledSingleSelectEnumSchema(
          description:
              'CSV/TSV cell policy for the writability summary. refuse '
              '(default) requires scalar cells; json accepts any list '
              'at the root.',
          values: ['refuse', 'json'],
        ),
      },
      required: ['expression'],
    ),
  );

  FutureOr<CallToolResult> _handleExplain(CallToolRequest request) {
    final args = request.arguments!;
    final expression = args['expression'] as String;
    final data = args['data'] as String?;
    final formatStr = args['format'] as String?;
    final schemaStr = args['schema'] as String?;
    final includeTrivial = args['include_trivial'] as bool? ?? false;
    final flattenCellsStr = args['flatten_cells'] as String?;

    try {
      final ast = parseAst(expression);
      final flattenCells =
          flattenCellsStr != null
              ? CellPolicy.values.byName(flattenCellsStr)
              : CellPolicy.refuse;

      // Build the initial shape. Four cases:
      //   - no data, no schema: SAny
      //   - data only: shapeOf(data)
      //   - schema only: parseJsonSchema(schema)
      //   - both: mergeSchemaWithData(schema, shapeOf(data))
      Shape inputShape;
      if (data == null && schemaStr == null) {
        inputShape = const SAny();
      } else if (data == null) {
        inputShape = parseJsonSchema(schemaStr!);
      } else {
        final format =
            formatStr != null ? Format.values.byName(formatStr) : null;
        final parsed = parseInput(data, format ?? sniffFormat(data));
        final dataShape = shapeOf(parsed);
        inputShape =
            schemaStr != null
                ? mergeSchemaWithData(parseJsonSchema(schemaStr), dataShape)
                : dataShape;
      }

      final report = explain(
        ast,
        inputShape,
        flattenCells: flattenCells,
        includeTrivial: includeTrivial,
      );
      return CallToolResult(
        content: [TextContent(text: renderExplainJson(report))],
      );
    } on QueryError catch (e) {
      return _errorResult('Error: ${e.message}');
    } on FormatException catch (e) {
      return _errorResult('Parse error: ${e.message}');
    }
  }

  final _assertTool = Tool(
    name: 'lambe_assert',
    description:
        'Use this tool to validate, check, or verify conditions on structured '
        'data. Returns PASS or FAIL. Use when the user says "check that", '
        '"make sure", "verify", or "assert". Examples:\n'
        '  ".version != \\"0.0.0\\""           — check version is set\n'
        '  ".users | length > 0"              — check non-empty\n'
        '  ". | has(\\"database\\")"           — check field exists at root\n'
        '  ".replicas >= 2"                   — check minimum value\n',
    inputSchema: Schema.object(
      properties: {
        'expression': Schema.string(
          description: 'The assertion expression (must evaluate to boolean)',
        ),
        'data': Schema.string(description: 'The input data as a string'),
        'format': UntitledSingleSelectEnumSchema(
          description: 'Input format. Auto-detected if omitted.',
          values: ['json', 'yaml', 'toml', 'hcl', 'csv', 'tsv', 'markdown'],
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
        return _errorResult(
          'Error: assertion expression must return boolean, '
          'got ${result.runtimeType}: $result',
        );
      }
    } on QueryError catch (e) {
      return _errorResult('Error: ${e.message}');
    }
  }
}
