#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

RUNS=3
NUM_RECORDS=${1:-50000000}

# ── Build ────────────────────────────────────────────────────────────

printf "=== Building C++ ===\n"
(cd cpp && make --quiet)

printf "=== Building Rust ===\n"
(cd rust && cargo build --release --quiet)

printf "=== Building TypeScript ===\n"
(cd ts && npm install --silent && npm run build --silent)

printf "\n"

# ── Helpers ──────────────────────────────────────────────────────────
extract_ms() {
  grep '^TOTAL_MS:' | head -1 | cut -d: -f2
}

# run_n LABEL CMD... → prints per-run lines, sets _avg/_best/_worst vars
run_n() {
  local label=$1; shift
  local cmd=("$@")

  printf -- "--- %s (warmup) ---\n" "$label"
  "${cmd[@]}" 2>/dev/null || true

  local sum=0
  _best=999999 _worst=0
  for i in $(seq 1 "$RUNS"); do
    ms=$("${cmd[@]}" 2>&1 >/dev/null | extract_ms)
    printf "  run %d: %dms\n" "$i" "$ms"
    sum=$((sum + ms))
    (( ms < _best ))  && _best=$ms
    (( ms > _worst )) && _worst=$ms
  done
  _avg=$((sum / RUNS))
  printf "  => avg=%dms  best=%dms  worst=%dms\n\n" "$_avg" "$_best" "$_worst"
}

# ── Run ──────────────────────────────────────────────────────────────
printf "=== Benchmarking (%d runs each, %d records) ===\n\n" "$RUNS" "$NUM_RECORDS"

run_n "C++"         cpp/main "$NUM_RECORDS"
cpp_avg=$_avg cpp_best=$_best

RUST_BIN="rust/target/aarch64-apple-darwin/release/rust-bench"
[ -x "$RUST_BIN" ] || RUST_BIN="rust/target/release/rust-bench"
run_n "Rust"        "$RUST_BIN" "$NUM_RECORDS"
rust_avg=$_avg rust_best=$_best

BUN_BIN="$(command -v bun || true)"
if [ -n "$BUN_BIN" ]; then
  run_n "TS (Bun)"    "$BUN_BIN" ts/src/main.ts "$NUM_RECORDS"
  bun_avg=$_avg bun_best=$_best
else
  echo "--- TS (Bun) skipped: 'bun' not on PATH ---"
  bun_avg=0 bun_best=0
fi

run_n "TS (Node)"   node ts/dist/main.js "$NUM_RECORDS"
node_avg=$_avg node_best=$_best

run_n "Python"      python3 py/main.py "$NUM_RECORDS"
py_avg=$_avg py_best=$_best

# ── Summary table ────────────────────────────────────────────────────
rust_ratio=$(awk "BEGIN { printf \"%.1f\", $rust_avg / $cpp_avg }")
if [ "$bun_avg" -gt 0 ]; then
  bun_ratio=$(awk "BEGIN { printf \"%.1f\", $bun_avg / $cpp_avg }")
else
  bun_ratio="n/a"
fi
node_ratio=$(awk "BEGIN { printf \"%.1f\", $node_avg / $cpp_avg }")
py_ratio=$(awk "BEGIN { printf \"%.1f\", $py_avg / $cpp_avg }")

printf "┌────────────┬────────┬────────┬─────────────────────┬──────────┐\n"
printf "│            │        │        │     TypeScript      │          │\n"
printf "│            │  C++   │  Rust  ├──────────┬──────────┤  Python  │\n"
printf "│            │        │        │   Bun    │  Node.js │          │\n"
printf "├────────────┼────────┼────────┼──────────┼──────────┼──────────┤\n"
printf "│ avg        │ %4dms │ %4dms │   %4dms │   %4dms │ %6dms │\n" "$cpp_avg" "$rust_avg" "$bun_avg" "$node_avg" "$py_avg"
printf "│ best       │ %4dms │ %4dms │   %4dms │   %4dms │ %6dms │\n" "$cpp_best" "$rust_best" "$bun_best" "$node_best" "$py_best"
printf "│ vs C++     │  1.0x  │ %4sx  │   %4sx  │   %4sx  │  %5sx  │\n" "$rust_ratio" "$bun_ratio" "$node_ratio" "$py_ratio"
printf "└────────────┴────────┴────────┴──────────┴──────────┴──────────┘\n"
