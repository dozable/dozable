#!/bin/bash
# `make dozchat-check`: dozchat's unit check under AddressSanitizer and UndefinedBehaviorSanitizer (nothing recovers:
# the first finding fails the run), with the same warnings as the shipped builds. ITERATIONS fuzz rounds (default 25000).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../../.." && pwd)"
OUT="$PKG/.build/dozchat-check"
mkdir -p "$OUT"
cc -O1 -g -std=c11 -Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror -Wno-unused-function \
  -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
  "$HERE/unit-check.c" -o "$OUT/unit-check"
ASAN_OPTIONS=detect_leaks=0:abort_on_error=0 UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
  "$OUT/unit-check" --vectors "$HERE/clean-name.tsv" --iterations "${ITERATIONS:-25000}" --seed "${SEED:-20261118}"
