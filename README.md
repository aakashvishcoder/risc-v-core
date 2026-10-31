# risc-v-core

A 5-stage pipelined RISC-V (RV32I) processor written in SystemVerilog, built to run
on my [Artix-7 FPGA carrier board](https://github.com/aakashvishcoder/fpgacarrierboard).

## Status

Work in progress. The base pipeline runs C programs in simulation:

```
$ make -C sw PROG=hello && make -C sim run HEX=../sw/build/hello.hex
Hello from risc-v-core!
printing that took 252 cycles, 203 instructions
[tb] stop: exit  code=0  cycles=4025  retired=3576  CPI=1.126  leds=0xa5
```

## Roadmap

- [x] 5-stage RV32I pipeline (forwarding, load-use stall, branch flush)
- [x] SoC with block RAM, UART, memory-mapped I/O
- [x] Bare-metal C toolchain + Verilator testbench
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

## Building

Requires Verilator (5.x), clang/lld with the RISC-V target, and Python 3.

```
make -C sw PROG=hello                      # build a program
make -C sim                                # build the simulator
make -C sim run HEX=../sw/build/hello.hex  # run it
```

Testbench options: `+trace=<file>` writes one line per retired instruction,
`+vcd=<file>` dumps waveforms, `+max_cycles=<n>` sets a timeout.

## Pipeline

```
  IF ──► ID ──► EX ──► MEM ──► WB
         │      ▲  ▲     │      │
         │      │  └─────┘      │   MEM→EX forward
         │      └───────────────┘   WB→EX forward
         └── regfile write-through (WB→ID)
```

- **Memories** are synchronous-read block RAM, so IF is the address phase and
  the instruction word arrives at the start of ID.
- **Data hazards:** full forwarding into EX. A load followed immediately by a
  consumer stalls one cycle, because load data only exists at the end of MEM.
- **Control hazards:** predict not-taken. Branches and jumps resolve in EX; a
  taken one flushes the instruction behind it (1-cycle penalty).
