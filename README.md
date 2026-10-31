# risc-v-core

A 5-stage pipelined RISC-V (RV32I) processor written in SystemVerilog, built to run
on my [Artix-7 FPGA carrier board](https://github.com/aakashvishcoder/fpgacarrierboard).

## Status

Work in progress. The base pipeline runs C programs in simulation:

```
$ make -C sw PROG=hello && make -C sim run HEX=../sw/build/hello.hex
Hello from risc-v-core!
printing that took 252 cycles, 203 instructions
[tb] stop: exit  code=0  cycles=4041  retired=3590  CPI=1.126  leds=0xa5
```

## Roadmap

- [x] 5-stage RV32I pipeline (forwarding, load-use stall, branch flush)
- [x] SoC with block RAM, UART, memory-mapped I/O
- [x] Bare-metal C toolchain + Verilator testbench
- [x] Verification: instruction-set reference model, random co-simulation, mutation testing
- [x] CoreMark port, hardware performance counters, branch predictor study
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
make bench                                 # CoreMark with a CPI breakdown
make study                                 # branch predictor what-if study
```

Testbench options: `+trace=<file>` writes one line per retired instruction,
`+vcd=<file>` dumps waveforms, `+max_cycles=<n>` sets a timeout.

## Verification

`make test` runs everything below in about a minute.

```
== reference model known-answer tests
16/16 reference-model tests passed
== directed programs (RTL vs reference model)
hello            MATCH: 3590 instructions | uart ok | exit  code=0  cycles=4041 ...
perftest         MATCH: 34989 instructions | uart ok | exit  code=0  cycles=39775 ...
coremark_1iter   MATCH: 1001007 instructions | uart ok | exit  code=0  cycles=1159930 ...
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

## Performance

### CoreMark

`make bench` runs EEMBC CoreMark (2K performance run, clang -O2, RV32I). The
list, matrix and state CRCs match the reference values (0xe714 / 0x1fd7 /
0x8e3a), and one full iteration is co-simulated against the reference model
in `make test`.

| Metric | Base pipeline |
|---|---|
| CoreMark/MHz | 0.959 |
| CPI | 1.162 |

CoreMark requires a 10-second run for an official score (500M cycles at
50 MHz), which isn't practical in simulation, so these are CoreMark/MHz
measurements rather than certified results.

### Where the cycles go

The core has five hardware performance counters (`hpmcounter3`-`7`, read with
`csrr`): load-use stall cycles, flush cycles, branches, taken branches, and
jumps. CoreMark reads them around its timed region and prints a CPI stack:

```
CPI stack (share of cycles):
  retiring             8961067 (86.0%)
  load-use stalls      272264 (2.6%)
  branch/jump flushes  1186463 (11.3%)
  other                0 (0.0%)
Control flow:
  taken branches       895742 (64.3%)
```

"Other" is exactly zero: every cycle is an instruction retiring, a load-use
stall, or a flush, so the counters account for the whole run.
`sw/perftest` checks each counter against assembly kernels with hand-computed
event counts. It also catches performance-only bugs that co-simulation can't,
such as stalling on a load into `x0`.

**Takeaway:** control flow is the bottleneck. 11.3% of cycles are flushes,
because the core predicts not-taken and 64% of CoreMark's branches are taken.
Load-use stalls are a distant second.

### Branch predictor study

Before building a predictor, `make study` replays CoreMark's branch outcomes
through software models of several predictors, using this pipeline's
penalties. It's calibrated so the first row reproduces the measured CPI:

| Scheme | Mispredict rate | CPI |
|---|---|---|
| Predict not-taken, jumps resolve in EX (current) | 64.5% | 1.159 |
| Predict not-taken, JAL resolved in decode | 64.5% | 1.155 |
| Static backward-taken / forward-not-taken | 15.0% | 1.080 |
| Bimodal 2-bit, 256 entries | 9.9% | 1.073 |
| gshare, 256 entries, 8-bit history | 7.3% | 1.069 |
| Bimodal 256 + perfect return prediction | 9.9% | 1.061 |
| Perfect prediction (upper bound) | 0% | 1.030 |

What the study shows:
- Loop structure explains most of it: backward branches are taken 85% of the
  time and forward ones 16%, so even a free static rule removes three quarters
  of the mispredictions.
- Table size barely matters (64 to 1024 entries: 10.1% to 9.8%), so CoreMark's
  working set of branches is small. Global history (gshare) helps more than
  extra entries.
- Indirect jumps are now a large share of what's left. Of 27,824 JALRs, 11,484
  are returns, 11,484 are function calls emitted as `auipc`+`jalr` (the build
  disables linker relaxation), and 4,856 are other indirect jumps.

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
