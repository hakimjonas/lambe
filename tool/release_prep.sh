#!/usr/bin/env bash
#
# Release preparation routine for Lambë.
#
# Runs the full check matrix for a release candidate: version
# consistency, quality gates, docs, release workflow sanity. Does NOT
# tag, push, or publish — those stay manual. This script is the
# "am I ready to release?" audit you run before `git tag`.
#
# Usage:
#   tool/release_prep.sh [version]
#
# Where `version` (optional) is the target version, e.g. "0.9.0". If
# omitted, read from pubspec.yaml. The script asserts every other
# place that names a version matches.
#
# Exit code 0 means ready to release. Non-zero means something is off
# and is reported to stderr.

set -euo pipefail

# ---- pretty ---------------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold)
  GREEN=$(tput setaf 2)
  RED=$(tput setaf 1)
  YELLOW=$(tput setaf 3)
  DIM=$(tput dim)
  RESET=$(tput sgr0)
else
  BOLD="" GREEN="" RED="" YELLOW="" DIM="" RESET=""
fi

# Tracks whether any check has surfaced a failure. Checks that find
# issues set this to 1 so the script can continue running later checks
# and give you the full picture, while still exiting non-zero at the end.
FAILED=0

# Run a named check. First arg is the section label; remaining args
# are the command to run. We funnel stdout/stderr through so tests that
# want to be noisy still are, but we preface each with a visible
# banner.
section() {
  label=$1
  shift
  printf "\n%s== %s ==%s\n" "${BOLD}" "${label}" "${RESET}"
}

ok() { printf "%s✓%s  %s\n" "${GREEN}" "${RESET}" "$1"; }
fail() {
  printf "%s✗%s  %s\n" "${RED}" "${RESET}" "$1"
  FAILED=1
}
warn_note() { printf "%s!%s  %s\n" "${YELLOW}" "${RESET}" "$1"; }
note() { printf "%s   %s%s\n" "${DIM}" "$1" "${RESET}"; }

# ---- repo layout sanity --------------------------------------------

section "Repo layout"

# Run from the repo root.
cd "$(dirname "$0")/.."

if [ ! -f pubspec.yaml ]; then
  fail "pubspec.yaml not found — are you running from the repo root?"
  exit 1
fi

# Read the pubspec version.
PUBSPEC_VERSION=$(sed -n 's/^version: *//p' pubspec.yaml | head -n1)
TARGET_VERSION="${1:-$PUBSPEC_VERSION}"

if [ "$TARGET_VERSION" != "$PUBSPEC_VERSION" ]; then
  fail "Argument version $TARGET_VERSION disagrees with pubspec.yaml version $PUBSPEC_VERSION"
else
  ok "pubspec.yaml version: $PUBSPEC_VERSION"
fi

# ---- version consistency -------------------------------------------

section "Version consistency"

# lib/src/_version.dart
CODE_VERSION=$(grep -oE "'[0-9]+\\.[0-9]+\\.[0-9]+[^']*'" lib/src/_version.dart | tr -d "'")
if [ "$CODE_VERSION" = "$TARGET_VERSION" ]; then
  ok "lib/src/_version.dart matches ($CODE_VERSION)"
else
  fail "lib/src/_version.dart has $CODE_VERSION, expected $TARGET_VERSION. Run: dart run tool/gen_version.dart"
fi

# Man page frontmatter source field
MAN_SOURCE_VERSION=$(sed -n 's/^source: *Lambë *//p' doc/lam.1.md | head -n1)
if [ "$MAN_SOURCE_VERSION" = "$TARGET_VERSION" ]; then
  ok "doc/lam.1.md frontmatter source matches"
else
  fail "doc/lam.1.md frontmatter source is 'Lambë $MAN_SOURCE_VERSION', expected 'Lambë $TARGET_VERSION'"
fi

# CHANGELOG.md must have a section for this version at the top
if head -n3 CHANGELOG.md | grep -qE "^## $TARGET_VERSION\$"; then
  ok "CHANGELOG.md has section '## $TARGET_VERSION' at top"
else
  fail "CHANGELOG.md does not lead with '## $TARGET_VERSION'. Got: $(head -n1 CHANGELOG.md)"
fi

# CHANGELOG must not still have a -dev suffix anywhere
if grep -qE "^## $TARGET_VERSION-dev" CHANGELOG.md; then
  fail "CHANGELOG.md still contains a '$TARGET_VERSION-dev' section. Merge/rename before release."
else
  ok "CHANGELOG.md has no leftover -dev section for this version"
fi

# README REPL banner example (if present). Read lines from the grep
# output with a newline delimiter so we compare whole banner matches,
# not whitespace-split tokens.
if grep -qE "lambe v[0-9]+\\.[0-9]+\\.[0-9]+" README.md; then
  while IFS= read -r v; do
    got="${v#lambe v}"
    if [ "$got" = "$TARGET_VERSION" ]; then
      ok "README.md REPL banner example: $v"
    else
      fail "README.md REPL banner shows '$v', expected 'lambe v$TARGET_VERSION'"
    fi
  done <<EOF
$(grep -oE "lambe v[0-9]+\\.[0-9]+\\.[0-9]+" README.md | sort -u)
EOF
fi

# ---- tracked files shouldn't include anything gitignored -----------

section "File hygiene"

# Cross-check .gitignore against ls-files: nothing tracked should
# match an ignore pattern for benchmark artifacts / secrets /
# session notes.
UNEXPECTED=$(git ls-files 2>/dev/null | grep -E '^(bench-results-.*\.json|lam-mcp|HANDOVER_.*\.md|\.mcpregistry_.*|pubspec_overrides\.yaml)$' || true)
if [ -z "$UNEXPECTED" ]; then
  ok "no gitignored patterns in tracked files"
else
  fail "these files are tracked but gitignored:"
  echo "$UNEXPECTED" | sed 's/^/    /'
fi

# ---- dependency sanity ---------------------------------------------

section "Dependencies"

# Check for path overrides in pubspec_overrides.yaml (local dev only,
# must never be committed).
if git ls-files | grep -q pubspec_overrides.yaml; then
  fail "pubspec_overrides.yaml is tracked; remove it before release (path deps break for pub.dev consumers)"
else
  ok "no tracked pubspec_overrides.yaml"
fi

# dart pub outdated (informational — don't fail, just surface)
if command -v dart >/dev/null 2>&1; then
  if dart pub get >/dev/null 2>&1; then
    ok "dart pub get succeeds"
  else
    fail "dart pub get failed"
  fi
fi

# ---- quality gates -------------------------------------------------

section "Quality gates"

if dart analyze 2>&1 | tail -n1 | grep -q "No issues found"; then
  ok "dart analyze clean"
else
  fail "dart analyze reported issues"
  dart analyze 2>&1 | tail -5 | sed 's/^/    /'
fi

if dart format --output=none --set-exit-if-changed . >/dev/null 2>&1; then
  ok "dart format clean"
else
  fail "dart format has pending changes. Run: dart format ."
fi

# dart test: must say "All tests passed!"
TEST_OUT=$(dart test 2>&1 | tail -n3)
if echo "$TEST_OUT" | grep -q "All tests passed"; then
  TEST_COUNT=$(echo "$TEST_OUT" | grep -oE '\+[0-9]+' | tr -d '+' | sort -n | tail -n1)
  ok "dart test: $TEST_COUNT tests pass"
else
  fail "dart test did not pass"
  echo "$TEST_OUT" | sed 's/^/    /'
fi

# pana 160/160
if command -v pana >/dev/null 2>&1; then
  PANA_SCORE=$(pana --no-warning --json 2>/dev/null \
    | python3 -c "
import json, sys
try:
  d = json.load(sys.stdin)
  g = sum(s['grantedPoints'] for s in d['report']['sections'])
  m = sum(s['maxPoints'] for s in d['report']['sections'])
  print(f'{g}/{m}')
except Exception as e:
  print(f'ERROR: {e}')
")
  if [ "$PANA_SCORE" = "160/160" ]; then
    ok "pana: $PANA_SCORE"
  else
    fail "pana: $PANA_SCORE (expected 160/160)"
  fi
else
  warn_note "pana not installed — skipping (install: dart pub global activate pana)"
fi

# ---- documentation -------------------------------------------------

section "Documentation"

# Man page round-trip test is part of `dart test`, but explicitly
# regenerate + diff here to catch doc/lam.1.md edits that weren't
# followed by a manpage regen.
if dart run tool/manpage.dart > /tmp/lambe-release-manpage.$$.txt 2>/dev/null \
   && diff -q /tmp/lambe-release-manpage.$$.txt doc/lam.1 >/dev/null 2>&1; then
  ok "doc/lam.1 matches tool/manpage.dart output"
  rm -f /tmp/lambe-release-manpage.$$.txt
else
  fail "doc/lam.1 is out of sync with doc/lam.1.md. Run: dart run tool/manpage.dart > doc/lam.1"
  rm -f /tmp/lambe-release-manpage.$$.txt
fi

# dart doc gen (warnings are known; fail on errors only)
DOC_OUT=$(rm -rf doc/api && dart doc --validate-links 2>&1 || true)
DOC_ERRORS=$(echo "$DOC_OUT" | grep -oE 'Found [0-9]+ warnings? and [0-9]+ errors?' || true)
if echo "$DOC_ERRORS" | grep -q "0 errors"; then
  ok "dart doc: $DOC_ERRORS"
else
  fail "dart doc reported errors: $DOC_ERRORS"
fi

# ---- release workflow references -----------------------------------

section "Release workflow"

# The workflow triggers on tags matching v*. Make sure the workflow
# file is present and the artifacts it produces match what install.sh
# expects.
if [ -f .github/workflows/release.yml ]; then
  ok ".github/workflows/release.yml present"
else
  fail ".github/workflows/release.yml missing"
fi

EXPECTED_ASSETS="lam-linux-x64 lam-linux-arm64 lam-macos-x64 lam-macos-arm64 lam-windows-x64.exe lam-mcp-linux-x64 lam-mcp-linux-arm64 lam-mcp-macos-x64 lam-mcp-macos-arm64 lam-mcp-windows-x64.exe"
MISSING_ASSETS=""
for asset in $EXPECTED_ASSETS; do
  if ! grep -q "$asset" .github/workflows/release.yml; then
    MISSING_ASSETS="$MISSING_ASSETS $asset"
  fi
done
if [ -z "$MISSING_ASSETS" ]; then
  ok "release.yml references all expected per-platform binaries"
else
  fail "release.yml is missing references to:$MISSING_ASSETS"
fi

# checksums.txt generation step
if grep -q "checksums.txt" .github/workflows/release.yml; then
  ok "release.yml generates checksums.txt (install.sh depends on this)"
else
  fail "release.yml does not generate checksums.txt — install.sh will break"
fi

# server.json description should match pubspec description
PUBSPEC_DESC=$(sed -n '/^description:/,/^[^ ]/{/^description:/!{/^[^ ]/!p;};}' pubspec.yaml | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
SERVER_DESC=$(sed -n 's/.*"description": "\(.*\)",/\1/p' server.json)
# Compare first 80 chars — descriptions differ slightly (pubspec wraps, server.json is one line).
PUBSPEC_PREFIX=$(echo "$PUBSPEC_DESC" | cut -c1-80)
SERVER_PREFIX=$(echo "$SERVER_DESC" | cut -c1-80)
if [ "$PUBSPEC_PREFIX" = "$SERVER_PREFIX" ]; then
  ok "server.json description matches pubspec.yaml"
else
  warn_note "server.json and pubspec.yaml descriptions diverge at the lead"
  note "pubspec: $PUBSPEC_PREFIX"
  note "server : $SERVER_PREFIX"
fi

# ---- git state -----------------------------------------------------

section "Git state"

if [ -z "$(git status --porcelain)" ]; then
  ok "working tree clean"
else
  fail "uncommitted changes — commit or stash before tagging:"
  git status --short | sed 's/^/    /'
fi

# Existing tag for this version?
if git rev-parse --verify "v$TARGET_VERSION" >/dev/null 2>&1; then
  fail "tag v$TARGET_VERSION already exists locally"
else
  ok "tag v$TARGET_VERSION does not yet exist"
fi

# Are we on main?
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  ok "on branch: $BRANCH"
else
  warn_note "on branch: $BRANCH (expected main/master)"
fi

# Local commits ahead of origin?
AHEAD=$(git rev-list --count "origin/$BRANCH..$BRANCH" 2>/dev/null || echo "?")
if [ "$AHEAD" != "0" ] && [ "$AHEAD" != "?" ]; then
  note "$AHEAD local commits ahead of origin/$BRANCH (push before tagging)"
fi

# ---- summary -------------------------------------------------------

printf "\n"
if [ "$FAILED" -eq 0 ]; then
  printf "%s✓ Ready to release %s%s\n" "${BOLD}${GREEN}" "$TARGET_VERSION" "${RESET}"
  printf "\n"
  printf "Next steps:\n"
  printf "  1. git push origin $BRANCH\n"
  printf "  2. git tag v$TARGET_VERSION\n"
  printf "  3. git push origin v$TARGET_VERSION\n"
  printf "  4. Watch the release workflow build binaries and publish.\n"
  printf "  5. After binaries land, verify install.sh against the new release:\n"
  printf "     LAMBE_VERSION=v$TARGET_VERSION LAMBE_PREFIX=/tmp/verify sh install.sh\n"
  exit 0
else
  printf "%s✗ Not ready to release %s%s\n" "${BOLD}${RED}" "$TARGET_VERSION" "${RESET}"
  printf "   Fix the issues above and re-run.\n"
  exit 1
fi
