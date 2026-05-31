/// Generates lib/src/_skill.dart from .agents/skills/lambe/SKILL.md.
///
/// Usage: dart run tool/gen_skill.dart
///
/// The generated file embeds the skill content as a `const String`
/// so that `lam --skill` can print it without filesystem access at
/// runtime — works in WASM, in pub-installed environments where the
/// repo's .agents/ directory is not present, and on AOT binaries
/// where the source tree is not shipped.
///
/// Re-run this tool after editing the skill source. The generated file
/// is committed to the repo so `dart compile exe` works on a fresh
/// checkout without the generator pre-step.
library;

import 'dart:io';

void main() {
  final source = File('.agents/skills/lambe/SKILL.md');
  if (!source.existsSync()) {
    stderr.writeln('Source not found: ${source.path}');
    stderr.writeln('Run from the lambe repo root.');
    exit(1);
  }
  final content = source.readAsStringSync();

  // Use a raw triple-quoted string. Dart raw strings disable escape
  // processing for `\` and `$`, but the closing delimiter (`'''` here)
  // still terminates the literal. SKILL.md does not contain triple
  // single-quotes today; if it ever does, the generator will fail
  // loudly at compile time and we'll switch to a different escape.
  if (content.contains("'''")) {
    stderr.writeln(
      'SKILL.md contains a triple single-quote sequence. '
      'The embedder uses r\'\'\' delimiters and would break. '
      'Either reword the SKILL or switch the embedding scheme '
      '(e.g. base64-encode and decode at runtime).',
    );
    exit(1);
  }

  final output = '''
// GENERATED FILE. DO NOT EDIT.
// Run `dart run tool/gen_skill.dart` to regenerate after editing
// .agents/skills/lambe/SKILL.md.

/// Embedded contents of `.agents/skills/lambe/SKILL.md`, captured at
/// build time. Surfaced via `lam --skill` so an agent harness can
/// install the skill regardless of how `lam` was acquired:
///   `lam --skill > .agents/skills/lambe/SKILL.md`
const lambeSkill = r\'\'\'$content\'\'\';
''';

  File('lib/src/_skill.dart').writeAsStringSync(output);
  stdout.writeln(
    'Wrote lib/src/_skill.dart (${content.length} bytes from ${source.path})',
  );
}
