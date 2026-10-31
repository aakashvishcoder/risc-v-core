#!/usr/bin/env bash
# Build every core configuration and run, on each:
#   - perftest (counters and per-configuration misprediction expectations),
#     the cache test, and the M-extension directed test where the core has M
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

# Programs are compiled for each configuration's instruction set
# (M_EXT 0: rv32i, 1: rv32i_zmmul, 2: rv32im). CACHES=0 is single-cycle RAM;
# CACHES=1 is caches in front of a 20-cycle main memory (IC = I-cache lines,
# DCS x DCW = D-cache sets x ways, 16-byte lines; DCS=0: no D-cache).
#        name        EJ BP BHT GHR RAS IB M CACHES IC DCS DCW
CONFIGS=(
  "baseline       0 0 8 8 0 0 0 0 0 0 0"
  "early-jal      1 0 8 8 0 0 0 0 0 0 0"
  "btfn           1 1 8 8 0 0 0 0 0 0 0"
  "bimodal        1 2 8 8 0 0 0 0 0 0 0"
  "gshare         1 3 8 8 0 0 0 0 0 0 0"
  "gshare+ras     1 3 8 8 8 0 0 0 0 0 0"
  "gshare+ibtb    1 3 8 8 0 4 0 0 0 0 0"
  "predict-all    1 3 8 8 8 4 0 0 0 0 0"
  "+multiply      1 3 8 8 8 4 1 0 0 0 0"
  "+divide (full) 1 3 8 8 8 4 2 0 0 0 0"
  "tiny-tables    1 3 2 2 2 1 2 0 0 0 0"
  "I\$1K no-D\$     1 3 8 8 8 4 2 1 64 0 1"
  "I\$1K D\$1K DM   1 3 8 8 8 4 2 1 64 64 1"
  "I\$1K D\$1K 2w   1 3 8 8 8 4 2 1 64 32 2"
  "I\$2K D\$2K 2w   1 3 8 8 8 4 2 1 128 64 2"
  "tiny caches    1 3 8 8 8 4 2 1 4 2 2"
)
MARCHES=(rv32i_zicsr rv32i_zmmul_zicsr rv32im_zicsr)

# Build the configurations, a few at a time (each Verilator C++ build is
# memory-hungry; all of them at once can starve the compiler)
objname() { tr ' +()$' '_p___' <<<"$1"; }
mkdir -p "$ROOT/out"
for c in "${CONFIGS[@]}"; do
  name="${c:0:14}"; read -r ej bp bht ghr ras ib m ca ic dcs dcw <<<"${c:15}"
  o=$(objname "$name")
  make -s -C "$ROOT/sim" OBJ="obj_$o" EARLY_JAL=$ej BPRED=$bp BHT_BITS=$bht GHR_BITS=$ghr \
       RAS_DEPTH=$ras IBTB_BITS=$ib M_EXT=$m CACHES=$ca IC_LINES=$((ic>0?ic:128)) \
       DC_SETS=$dcs DC_WAYS=$((dcw>0?dcw:1)) > "$ROOT/out/build_$o.log" 2>&1 &
  (( $(jobs -rp | wc -l) >= 4 )) && wait -n
done
wait

# Programs, once per instruction set
for ma in "${MARCHES[@]}"; do
  make -s -C "$ROOT/sw" PROG=perftest MARCH=$ma BUILD=build/$ma >/dev/null
  make -s -C "$ROOT/sw" PROG=mext MARCH=$ma BUILD=build/$ma >/dev/null 2>&1 || true
  make -s -C "$ROOT/sw" PROG=cachetest MARCH=$ma BUILD=build/$ma >/dev/null
  make -s -C "$ROOT/sw" PROG=coldload MARCH=$ma BUILD=build/$ma >/dev/null
  make -s -C "$ROOT/sw" PROG=coremark ITERATIONS=1 MARCH=$ma BUILD=build/$ma/cm1 >/dev/null
  cp "$ROOT/sw/build/$ma/cm1/coremark.hex" "$ROOT/out/coremark_1iter_$ma.hex"
  [[ $BENCH == 1 ]] && make -s -C "$ROOT/sw" PROG=coremark ITERATIONS=10 MARCH=$ma BUILD=build/$ma/cm10 >/dev/null
done

fails=0
printf '%-15s %-3s %-9s %-9s %-9s' config M perftest coremark random
[[ $BENCH == 1 ]] && printf ' %-13s %-6s %-8s %-9s %-7s %-7s' CoreMark/MHz CPI br-misp jmp-redir I\$-stl D\$-stl
echo
for c in "${CONFIGS[@]}"; do
  name="${c:0:14}"; read -r _ _ _ _ _ _ m _ <<<"${c:15}"
  o=$(objname "$name"); ma=${MARCHES[$m]}; B="$ROOT/sw/build/$ma"
  sim="$ROOT/sim/obj_$o/Vrv_soc"
  if [[ ! -x $sim ]]; then echo "$name: BUILD FAILED"; cat "$ROOT/out/build_$o.log"; fails=$((fails+1)); continue; fi
  pt=ok;  SIM=$sim "$ROOT/tools/cosim.sh" "$B/perftest.hex" >/dev/null 2>&1 || pt=FAIL
  grep -q "perftest: 0 failures" "$ROOT/out/perftest.rtl.uart" 2>/dev/null || pt=FAIL
  SIM=$sim "$ROOT/tools/cosim.sh" "$B/cachetest.hex" >/dev/null 2>&1 || pt=FAIL
  grep -q "cachetest: 0 failures" "$ROOT/out/cachetest.rtl.uart" 2>/dev/null || pt=FAIL
  SIM=$sim "$ROOT/tools/cosim.sh" "$B/coldload.hex" >/dev/null 2>&1 || pt=FAIL
  if [[ $m -ge 1 ]]; then
    SIM=$sim "$ROOT/tools/cosim.sh" "$B/mext.hex" >/dev/null 2>&1 || pt=FAIL
    grep -q " 0 failures" "$ROOT/out/mext.rtl.uart" 2>/dev/null || pt=FAIL
  fi
  cm=ok;  SIM=$sim "$ROOT/tools/cosim.sh" "$ROOT/out/coremark_1iter_$ma.hex" >/dev/null 2>&1 || cm=FAIL
  mflag=""; [[ $m -eq 2 ]] && mflag="--m"
  rr=$(SIM=$sim "$ROOT/tools/run_random.sh" "$SEEDS" 7000 $mflag | tail -1 | awk '{print $3"/"$3+$5}')
  [[ $pt == ok && $cm == ok && $rr == "$SEEDS/$SEEDS" ]] || fails=$((fails+1))
  printf '%-15s %-3s %-9s %-9s %-9s' "$name" "$m" "$pt" "$cm" "$rr"
  if [[ $BENCH == 1 ]]; then
    r=$("$sim" +firmware="$B/cm10/coremark.hex" 2>/dev/null)
    mhz=$(sed -n 's/^CoreMark\/MHz: //p' <<<"$r")
    cpi=$(sed -n 's/^CPI: *//p' <<<"$r")
    bm=$(sed -n 's/.*mispredicted branches [0-9]* (\(.*\))/\1/p' <<<"$r")
    jr=$(sed -n 's/.*redirected jumps *[0-9]* (\(.*\))/\1/p' <<<"$r")
    is=$(sed -n 's/.*I-cache stalls *[0-9]* (\(.*\))/\1/p' <<<"$r")
    ds=$(sed -n 's/.*D-cache stalls *[0-9]* (\(.*\))/\1/p' <<<"$r")
    printf ' %-13s %-6s %-8s %-9s %-7s %-7s' "$mhz" "$cpi" "$bm" "$jr" "$is" "$ds"
  fi
  echo
done
echo "configurations failing: $fails"
[[ $fails -eq 0 ]]
