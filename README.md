# risc-v-core

A 5-stage pipelined RISC-V (RV32I) processor written in SystemVerilog, built to run
on my [Artix-7 FPGA carrier board](https://github.com/aakashvishcoder/fpgacarrierboard).

## Status

Work in progress. Current milestone: base pipeline + SoC.

## Roadmap

- [ ] 5-stage RV32I pipeline (forwarding, load-use stall, branch flush)
- [ ] SoC with block RAM, UART, memory-mapped I/O
- [ ] Bare-metal C toolchain + Verilator testbench
- [ ] Verification: instruction-set reference model + random co-simulation
- [ ] CoreMark port and performance counters
- [ ] Branch prediction (static, bimodal, gshare, BTB, return-address stack)
- [ ] M extension (pipelined multiplier, iterative divider)
- [ ] Instruction and data caches in front of a slow main memory
- [ ] Machine-mode traps, CSRs, timer interrupts
- [ ] FPGA bring-up on the carrier board

## Layout

```
rtl/     SystemVerilog source
sim/     Verilator testbench
sw/      Bare-metal programs, startup code, linker script
tools/   Scripts (hex conversion, verification)
```
