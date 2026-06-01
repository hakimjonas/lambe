#!/usr/bin/env bash
# CLI-level micro-benchmarks for lambë.
#
# Three cases drawn from the discovery report (0.8.0 baseline) plus one
# realistic third case. Runs the AOT binary so JIT warmup is out of the
# measurement; repeats N times and reports min / median / max in
# milliseconds.
#
# Run from the lambë repo root:
#   ./tool/bench/cli_bench.sh
#
# Requires:
#   - `lam` binary at ./lam (build: `dart compile exe bin/lam.dart -o lam`)
#   - `python3` for the percentile calculation
#
# The output is suitable for pasting into BENCHMARKS.md or a CHANGELOG
# entry. Each case ships the synthetic input alongside.

set -euo pipefail

if [[ ! -x ./lam ]]; then
  echo "Build the AOT binary first:"
  echo "  dart compile exe bin/lam.dart -o lam"
  exit 1
fi

RUNS=${RUNS:-10}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- Synthetic inputs --------------------------------------------------

# Case 1 + 2: a 50k-element list with numeric `value` field.
python3 - <<EOF > "$TMP/big.json"
import json
data = {"items": [{"id": i, "value": (i * 12345) % 100000} for i in range(50000)]}
print(json.dumps(data))
EOF

# Case 3: a 1k-element list of records with mixed types — realistic
# shape-inference / group_by workload.
python3 - <<EOF > "$TMP/users.json"
import json
data = [
  {"id": i,
   "name": f"user_{i}",
   "role": ["admin", "user", "guest"][i % 3],
   "active": (i % 5) != 0,
   "age": 18 + (i % 60)}
  for i in range(1000)
]
print(json.dumps(data))
EOF

# ---- Bench harness -----------------------------------------------------

bench() {
  local label=$1
  shift
  local cmd=("$@")
  local samples=()
  for ((i=0; i<RUNS; i++)); do
    local start end
    start=$(date +%s%N)
    "${cmd[@]}" >/dev/null
    end=$(date +%s%N)
    samples+=($(( (end - start) / 1000000 )))
  done
  local stats
  stats=$(python3 - <<EOF
import statistics
xs = [$(IFS=,; echo "${samples[*]}")]
xs.sort()
print(f"{min(xs):>6} ms  {statistics.median(xs):>6.1f} ms  {max(xs):>6} ms")
EOF
)
  printf "%-50s %s\n" "$label" "$stats"
}

printf "lambë CLI bench (%s runs, AOT, %s)\n" "$RUNS" "$(./lam --version 2>/dev/null || echo unknown)"
printf "%-50s %s\n" "case" "       min      median       max"
printf "%-50s %s\n" "--------------------------------------------------" "---------------------------------"

bench "--print-shape big.json" \
  ./lam --print-shape "$TMP/big.json"

bench ".items | filter(.value > 50000) | length" \
  ./lam '.items | filter(.value > 50000) | length' "$TMP/big.json"

bench ". | group_by(.role) | map({role: .key, count: .values | length})" \
  ./lam '. | group_by(.role) | map({role: .key, count: .values | length})' "$TMP/users.json"
