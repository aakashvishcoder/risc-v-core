#!/usr/bin/env bash
# Open-source FPGA flow for the XC7A35T-FGG484 (no Vivado needed):
#   sv2v (SystemVerilog -> Verilog) -> yosys synth_xilinx -> nextpnr-xilinx
# Prints resource use and the post-route maximum clock frequency for each
# placement seed, plus the critical path of the first seed.
#
#   fpga/build.sh [firmware.hex]
#
# Tools (override with environment variables):
#   SV2V     sv2v                   https://github.com/zachjs/sv2v
#   YOSYS    yosys
#   NEXTPNR  nextpnr-xilinx         https://github.com/openXC7/nextpnr-xilinx
#   CHIPDB   xc7a35tfgg484.bin      built from prjxray-db with nextpnr-xilinx's
#            xilinx/python/bbaexport.py --device xc7a35tfgg484-1, then bbasm
#   SEEDS    placement seeds to try (default "1 2 3 4 5")
# Output goes to build/fpga/. top.fasm is the routed design; prjxray's
# fasm2frames + xc7frames2bit turn it into a bitstream.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SV2V="${SV2V:-sv2v}"; YOSYS="${YOSYS:-yosys}"; NEXTPNR="${NEXTPNR:-nextpnr-xilinx}"
CHIPDB="${CHIPDB:?set CHIPDB to the xc7a35tfgg484 chip database}"
SEEDS="${SEEDS:-1 2 3 4 5}"
FW="${1:-$ROOT/sw/build/hello.hex}"
OUT="$ROOT/build/fpga"; mkdir -p "$OUT"; cd "$OUT"
cp "$FW" firmware.hex

R="$ROOT/rtl"
"$SV2V" -I "$R" "$R/rv_defs.svh" "$R/rv_alu.sv" "$R/rv_divider.sv" "$R/rv_regfile.sv" \
  "$R/rv_core.sv" "$R/rv_ram.sv" "$R/rv_mainmem.sv" "$R/rv_icache.sv" "$R/rv_dcache.sv" \
  "$R/uart_tx.sv" "$R/rv_clint.sv" "$R/rv_soc.sv" "$ROOT/fpga/fpga_top.sv" -w top.v
"$YOSYS" -q -l yosys.log -p "read_verilog top.v; synth_xilinx -family xc7 -flatten -abc9 -top fpga_top;
                            write_json top.json; tee -q -o utilization.txt stat"

luts=$(awk '/ LUT[1-6] /{s+=$2} END{print s}' utilization.txt)
ffs=$(awk '/ FD[RSCP]E /{s+=$2} END{print s}' utilization.txt)
lram=$(awk '/ RAM(32|64)M /{s+=4*$2} END{print s+0}' utilization.txt)
bram=$(awk '/ RAMB36E1 /{print $2}' utilization.txt)
dsp=$(awk '/ DSP48E1 /{print $2}' utilization.txt)
echo "XC7A35T: LUTs $luts + $lram as LUTRAM / 20800, FFs $ffs / 41600," \
     "RAMB36 ${bram:-0} / 50, DSP48 ${dsp:-0} / 90"

for s in $SEEDS; do
  "$NEXTPNR" --chipdb "$CHIPDB" --xdc "$ROOT/fpga/fpga_top.xdc" --json top.json \
    --fasm "top_$s.fasm" --seed "$s" --freq 50 --timing-allow-fail > "pnr_$s.log" 2>&1
  printf 'seed %s: %s\n' "$s" "$(grep 'Max frequency' "pnr_$s.log" | tail -1 | sed 's/.*: //')"
done
