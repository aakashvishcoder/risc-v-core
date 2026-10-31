#!/usr/bin/env bash
# Build every core configuration and run, on each:
#   - perftest (counters and per-configuration misprediction expectations)
#   - one CoreMark iteration co-simulated against the reference model
#   - random co-simulation programs
# With --bench, also report CoreMark (10 iterations) per configuration.
#
#   tools/test_configs.sh [seeds=30] [--bench]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEEDS="${1:-30}"
BENCH=0; [[ "${2:-}" == "--bench" || "${1:-}" == "--bench" ]] && BENCH=1
[[ "$SEEDS" == "--bench" ]] && SEEDS=30
export PYTHONDONTWRITEBYTECODE=1

#        name        EARLY_JAL BPRED BHT_BITS GHR_BITS RAS_DEPTH IBTB_BITS
CONFIGS=(
  "baseline       0 0 8 8 0 0"
  "early-jal      1 0 8 8 0 0"
  "btfn           1 1 8 8 0 0"
  "bimodal        1 2 8 8 0 0"
  "gshare         1 3 8 8 0 0"
  "gshare+ras     1 3 8 8 8 0"
  "gshare+ibtb    1 3 8 8 0 4"
  "full           1 3 8 8 8 4"
  "tiny-tables    1 3 2 2 2 1"
)

# Build all configurations in parallel
for c in "${CONFIGS[@]}"; do
  read -r name ej bp bht ghr ras ib <<<"$c"
  make -s -C "$ROOT/sim" OBJ="obj_$name" EARLY_JAL=$ej BPRED=$bp BHT_BITS=$bht \
       GHR_BITS=$ghr RAS_DEPTH=$ras IBTB_BITS=$ib > "$ROOT/out/build_$name.log" 2>&1 &
done
mkdir -p "$ROOT/out"; wait

make -s -C "$ROOT/sw" PROG=perftest >/dev/null
make -s -C "$ROOT/sw" PROG=coremark ITERATIONS=1 BUILD=build/cm1 >/dev/null
cp "$ROOT/sw/build/cm1/coremark.hex" "$ROOT/out/coremark_1iter.hex"
[[ $BENCH == 1 ]] && make -s -C "$ROOT/sw" PROG=coremark ITERATIONS=10 >/dev/null

fails=0
printf '%-14s %-10s %-10s %-10s' config perftest coremark random
[[ $BENCH == 1 ]] && printf ' %-13s %-6s %-9s %-9s' CoreMark/MHz CPI br-misp jmp-redir
echo
for c in "${CONFIGS[@]}"; do
  read -r name _ <<<"$c"
  sim="$ROOT/sim/obj_$name/Vrv_soc"
  if [[ ! -x $sim ]]; then echo "$name: BUILD FAILED"; cat "$ROOT/out/build_$name.log"; fails=$((fails+1)); continue; fi
  pt=ok;  SIM=$sim "$ROOT/tools/cosim.sh" "$ROOT/sw/build/perftest.hex" >/dev/null 2>&1 || pt=FAIL
  grep -q "perftest: 0 failures" "$ROOT/out/perftest.rtl.uart" 2>/dev/null || pt=FAIL
  cm=ok;  SIM=$sim "$ROOT/tools/cosim.sh" "$ROOT/out/coremark_1iter.hex" >/dev/null 2>&1 || cm=FAIL
  rr=$(SIM=$sim "$ROOT/tools/run_random.sh" "$SEEDS" 7000 | tail -1 | awk '{print $3"/"$3+$5}')
  [[ $pt == ok && $cm == ok && $rr == "$SEEDS/$SEEDS" ]] || fails=$((fails+1))
  printf '%-14s %-10s %-10s %-10s' "$name" "$pt" "$cm" "$rr"
  if [[ $BENCH == 1 ]]; then
    r=$("$sim" +firmware="$ROOT/sw/build/coremark.hex" 2>/dev/null)
    mhz=$(sed -n 's/^CoreMark\/MHz: //p' <<<"$r")
    cpi=$(sed -n 's/^CPI: *//p' <<<"$r")
    bm=$(sed -n 's/.*mispredicted branches [0-9]* (\(.*\))/\1/p' <<<"$r")
    jr=$(sed -n 's/.*redirected jumps *[0-9]* (\(.*\))/\1/p' <<<"$r")
    printf ' %-13s %-6s %-9s %-9s' "$mhz" "$cpi" "$bm" "$jr"
  fi
  echo
done
echo "configurations failing: $fails"
[[ $fails -eq 0 ]]
