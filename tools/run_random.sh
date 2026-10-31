#!/usr/bin/env bash
# Generate random programs, run each on the RTL and the reference model, and
# diff the traces. Failing seeds are kept in out/ for debugging.
#   tools/run_random.sh [count=100] [first_seed=1] [--m]
# Env: KEEP_FAILS=0 to discard failing programs (used by mutate.py)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT="${1:-100}"
FIRST="${2:-1}"
MFLAG=""; MARCH="rv32i_zicsr"
if [[ "${3:-}" == "--m" ]]; then MFLAG="--m"; MARCH="rv32im_zicsr"; fi
export PYTHONDONTWRITEBYTECODE=1
# A ~400-instruction random program finishes in ~1500 cycles; anything far
# beyond that is a hang, so don't let it write a multi-GB trace.
export MAX_CYCLES="${MAX_CYCLES:-100000}"
KEEP_FAILS="${KEEP_FAILS:-1}"

GEN="$ROOT/sw/gen_rand"; mkdir -p "$GEN" "$ROOT/out"
pass=0; fail=0
for ((s=FIRST; s<FIRST+COUNT; s++)); do
  python3 "$ROOT/tools/rand_test.py" "$s" "$GEN/main.S" $MFLAG
  if ! make -s -C "$ROOT/sw" PROG=gen_rand BUILD=build/rand MARCH="$MARCH" >/dev/null 2>&1; then
    echo "seed $s: build failed"; fail=$((fail+1)); continue
  fi
  cp "$ROOT/sw/build/rand/gen_rand.hex" "$ROOT/out/rand_$s.hex"
  if res=$("$ROOT/tools/cosim.sh" "$ROOT/out/rand_$s.hex" 2>&1); then
    pass=$((pass+1)); rm -f "$ROOT/out/rand_$s".*
  else
    fail=$((fail+1))
    if [[ $KEEP_FAILS == 1 ]]; then
      cp "$GEN/main.S" "$ROOT/out/rand_$s.S"
      echo "seed $s FAILED (program kept in out/rand_$s.S):"; echo "$res" | sed 's/^/    /'
    else
      rm -f "$ROOT/out/rand_$s".*
    fi
  fi
done
rm -rf "$ROOT/sw/build/rand"
echo "random tests: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
