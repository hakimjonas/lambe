/// Generates lib/src/_version.dart from the version field in pubspec.yaml.
///
/// Usage: dart run tool/gen_version.dart
///
/// The generated file is committed to the repo so that `dart compile exe`
/// works on a fresh checkout without needing the generator to run first.
/// Re-run this tool after bumping the version in pubspec.yaml.
library;

import 'dart:io';

import 'package:rumil/rumil.dart';
import 'package:rumil_parsers/rumil_parsers.dart';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final version = _extractVersion(pubspec);
  if (version == null) {
    stderr.writeln('Could not find version: field in pubspec.yaml');
    exit(1);
  }

  final output = '''
// GENERATED FILE. DO NOT EDIT.
// Run `dart run tool/gen_version.dart` to regenerate after bumping
// pubspec.yaml version.

/// Lambë version, sourced from pubspec.yaml at generation time.
const lambeVersion = '$version';
''';

  File('lib/src/_version.dart').writeAsStringSync(output);
  stdout.writeln('Wrote lib/src/_version.dart (version: $version)');
}

String? _extractVersion(String pubspec) {
  final result = parseYaml(pubspec);
  final value = switch (result) {
    Success(:final value) || Partial(:final value) => value,
    Failure() => null,
  };
  if (value is! YamlMapping) return null;
  final v = value.pairs['version'];
  return switch (v) {
    YamlString(:final value) => value,
    YamlInteger(:final value) => value.toString(),
    YamlFloat(:final value) => value.toString(),
    _ => null,
  };
}
