#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$ROOT_DIR/bench"

for bench in $ROOT_DIR/bench/*.rv; do
  name="$(basename "$bench")"
  echo "== $name =="
  revo --bench "$bench"
  # ./zig-out/bin/revo bench "$bench"
  echo
done
