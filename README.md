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
- [x] Verification: instruction-set reference model, random co-simulation, mutation testing
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
tools/   Reference model, co-simulation, random tests, mutation testing
```

## Building

Requires Verilator (5.x), clang/lld with the RISC-V target, and Python 3.

```
make -C sw PROG=hello                      # build a program
make -C sim                                # build the simulator
make -C sim run HEX=../sw/build/hello.hex  # run it
make test                                  # full test suite
```

Testbench options: `+trace=<file>` writes one line per retired instruction,
`+vcd=<file>` dumps waveforms, `+max_cycles=<n>` sets a timeout.

## Verification

`make test` runs everything below in about 45 seconds.

```
== reference model known-answer tests
16/16 reference-model tests passed
== directed programs (RTL vs reference model)
hello            MATCH: 3576 instructions | uart ok | exit  code=0  cycles=4025 ...
== random programs
random tests: 100 passed, 0 failed
```

**Reference model.** `tools/iss.py` is an instruction-set simulator with no
pipeline: it executes one instruction at a time, exactly as the spec describes.
It is itself checked against hand-computed results (`tools/test_iss.py`), so a
misunderstanding of the spec can't hide by being shared between the model and
the RTL.

**Co-simulation.** The testbench and the model both write a commit trace, one
line per retired instruction (`pc`, encoding, destination register, value).
`tools/cosim.sh` diffs them and reports the first divergence with the
instructions leading up to it. A run only passes if the program also reaches
its exit cleanly.

**Random programs.** `tools/rand_test.py` generates ~400-instruction programs
using only 8 registers, so nearly every instruction depends on one of the last
few. That forces back-to-back forwarding, load-use stalls, branches on just-loaded
values, and link-register reuse far more often than real code does.

**Mutation testing.** Passing tests only matter if they would fail on a broken
design. `tools/mutate.py` (`make mutate`) injects realistic pipeline bugs, one
at a time, into a copy of the RTL and checks that the random tests catch each:

| Injected bug | Seeds failing (of 20) |
|---|---|
| No MEM→EX forwarding | 20 |
| No WB→EX forwarding | 20 |
| Forwarding priority reversed (WB before MEM) | 20 |
| Forwarding a result destined for x0 | 10 |
| No load-use stall | 20 |
| Load-use check ignores rs2 | 20 |
| No flush after a taken branch | 20 |
| JALR doesn't clear bit 0 | 20 |
| BLTU compares signed | 18 |
| LB zero-extends | 19 |
| SB writes the wrong byte lane | 20 |
| SRA behaves like SRL | 16 |
| Register file not write-through | 20 |

13/13 killed.

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
