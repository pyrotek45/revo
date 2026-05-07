#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$ROOT_DIR/bench"

if [ ! -d "$BENCH_DIR" ]; then
  echo "missing bench directory: $BENCH_DIR" >&2
  exit 1
fi

for bench in "$BENCH_DIR"/*.rv; do
  name="$(basename "$bench")"
  echo "== $name =="
  zig build run -- bench "$bench"
  # ./zig-out/bin/revo bench "$bench"
  echo
done
