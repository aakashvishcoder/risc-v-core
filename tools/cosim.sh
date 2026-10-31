#!/usr/bin/env bash
# Run a program on the RTL and on the reference model, then diff the commit
# traces and the UART output.
#   tools/cosim.sh <prog.hex> [extra iss.py args]
# The reference model always implements M: programs for a core without it are
# simply built without M instructions.
# A run passes only if the traces and UART output match AND the program reached
# its exit with code 0 (two models agreeing on a hang or a crash is not a pass).
# Env: SIM=<path to Vrv_soc> to use a different simulator build
#      MAX_CYCLES=<n> timeout (default 50M; random tests use far less)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEX="$1"; shift || true
NAME="$(basename "$HEX" .hex)"
OUT="$ROOT/out"; mkdir -p "$OUT"
SIM="${SIM:-$ROOT/sim/obj_dir/Vrv_soc}"
MAX_CYCLES="${MAX_CYCLES:-50000000}"
export PYTHONDONTWRITEBYTECODE=1

"$SIM" +firmware="$HEX" +trace="$OUT/$NAME.rtl" +max_cycles="$MAX_CYCLES" > "$OUT/$NAME.rtl.uart" 2> "$OUT/$NAME.rtl.log" || true
python3 "$ROOT/tools/iss.py" "$HEX" --trace "$OUT/$NAME.ref" --sync "$OUT/$NAME.rtl" --max "$MAX_CYCLES" --m "$@" \
  > "$OUT/$NAME.ref.uart" 2> "$OUT/$NAME.ref.log" || true

printf '%-16s ' "$NAME"
if ! res=$(python3 "$ROOT/tools/compare.py" "$OUT/$NAME.rtl" "$OUT/$NAME.ref"); then
  echo "FAILED"; echo "$res"; exit 1
fi
printf '%s ' "$res"
if ! grep -q "stop: exit  code=0 " "$OUT/$NAME.rtl.log"; then
  echo "| DID NOT EXIT CLEANLY: $(cat "$OUT/$NAME.rtl.log")"; exit 1
fi
if cmp -s "$OUT/$NAME.rtl.uart" "$OUT/$NAME.ref.uart"; then
  echo "| uart ok | $(sed 's/\[tb\] stop: //' "$OUT/$NAME.rtl.log")"
else
  echo "| UART OUTPUT DIFFERS"; exit 1
fi
