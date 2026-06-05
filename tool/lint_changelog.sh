#!/usr/bin/env bash
# Validate CHANGELOG.md structural invariants using lambë itself.
#
# Each invariant is an independent --assert call. Failures are reported
# inline with the invariant name; the script keeps running so all
# problems surface in one go. Exits 1 if any invariant failed.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ -x "./lam" ]; then
  LAM=("./lam")
else
  LAM=(dart run bin/lam.dart)
fi

CHANGELOG="CHANGELOG.md"
PUBSPEC="pubspec.yaml"

if [ ! -f "$CHANGELOG" ]; then
  echo "lint_changelog.sh: $CHANGELOG not found in $repo_root" >&2
  exit 1
fi
if [ ! -f "$PUBSPEC" ]; then
  echo "lint_changelog.sh: $PUBSPEC not found in $repo_root" >&2
  exit 1
fi

VERSION="$(grep '^version:' "$PUBSPEC" | awk '{print $2}')"
if [ -z "$VERSION" ]; then
  echo "lint_changelog.sh: could not read version from $PUBSPEC" >&2
  exit 1
fi

failed=0

run_invariant() {
  local name="$1"
  local query="$2"
  local output
  if ! output=$("${LAM[@]}" --assert "$query" "$CHANGELOG" 2>&1); then
    echo "FAIL [$name]" >&2
    echo "  query: $query" >&2
    if [ -n "$output" ]; then
      echo "  output: $output" >&2
    fi
    failed=1
  fi
}

run_invariant "at-least-one-h2" \
  '.children | filter(.type == "heading" and .level == 2) | length > 0'

run_invariant "no-duplicate-h2" \
  '.children | filter(.type == "heading" and .level == 2) | map(text) | length == (.children | filter(.type == "heading" and .level == 2) | map(text) | unique | length)'

run_invariant "first-heading-is-h2" \
  '.children | filter(.type == "heading") | first | .level == 2'

# A leading "## Unreleased" section is allowed to collect changes that
# have landed but aren't cut yet; the version-match check then applies
# to the first *versioned* heading below it.
run_invariant "latest-versioned-h2-matches-pubspec-version" \
  ".children | filter(.type == \"heading\" and .level == 2) | map(text) | filter(. != \"Unreleased\") | first == \"$VERSION\""

if [ "$failed" -eq 0 ]; then
  echo "lint_changelog.sh: all invariants pass (version $VERSION)"
  exit 0
fi

echo "lint_changelog.sh: one or more invariants failed" >&2
exit 1
