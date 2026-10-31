# risc-v-core

A 5-stage pipelined RISC-V (RV32I) processor written in SystemVerilog, with
gshare branch prediction, a return-address stack and an indirect jump target
buffer, built to run on my
[Artix-7 FPGA carrier board](https://github.com/aakashvishcoder/fpgacarrierboard).

## Status

Work in progress. The core runs C programs in simulation:

```
$ make -C sw PROG=hello && make -C sim run HEX=../sw/build/hello.hex
Hello from risc-v-core!
printing that took 232 cycles, 201 instructions
[tb] stop: exit  code=0  cycles=3755  retired=3575  CPI=1.050  leds=0xa5
```

| | Baseline pipeline | With branch prediction |
|---|---|---|
| CoreMark/MHz | 0.970 | **1.083** (+11.6%) |
| CPI | 1.164 | 1.043 |

## Roadmap

- [x] 5-stage RV32I pipeline (forwarding, load-use stall, branch flush)
- [x] SoC with block RAM, UART, memory-mapped I/O
- [x] Bare-metal C toolchain + Verilator testbench
- [x] Verification: instruction-set reference model, random co-simulation, mutation testing
- [x] CoreMark port, hardware performance counters, branch predictor study
- [x] Branch prediction: static, bimodal, gshare, return-address stack, indirect target buffer
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
make test-configs                          # test every predictor configuration
make bench-configs                         # ... and benchmark each one
```

The predictor is configurable at build time (defaults shown):

```
make -C sim OBJ=obj_mine EARLY_JAL=1 BPRED=3 BHT_BITS=8 GHR_BITS=8 RAS_DEPTH=8 IBTB_BITS=4
```

`BPRED` selects 0 = predict not-taken, 1 = static BTFN, 2 = bimodal, 3 = gshare.
Software can read the configuration from the `mconfig` CSR (0xFC0).

Testbench options: `+trace=<file>` writes one line per retired instruction,
`+vcd=<file>` dumps waveforms, `+max_cycles=<n>` sets a timeout.

## Verification

`make test` runs everything below in about a minute.

```
== reference model known-answer tests
16/16 reference-model tests passed
== directed programs (RTL vs reference model)
hello            MATCH: 3575 instructions | uart ok | exit  code=0  cycles=3755 ...
perftest         MATCH: 56262 instructions | uart ok | exit  code=0  cycles=58858 ...
coremark_1iter   MATCH: 999459 instructions | uart ok | exit  code=0  cycles=1042025 ...
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
values, and link-register reuse far more often than real code does. Control
flow is built to make every predictor mispredict and recover: counted loops,
a 12-deep call chain (deeper than the return-address stack), "returns" to
addresses that were never called, and indirect jumps whose target alternates.

**Every configuration.** `make test-configs` builds nine predictor
configurations side by side and runs the counter test, a co-simulated
CoreMark iteration and random programs on each, including a stress build with
4-entry tables, a 2-entry return-address stack and a 2-entry target buffer,
where aliasing and overflow happen constantly.

**Mutation testing.** Passing tests only matter if they would fail on a broken
design. `tools/mutate.py` (`make mutate`) injects realistic bugs, one at a
time, into a copy of the RTL and checks that the tests catch each. Random
co-simulation catches wrong results; the counter test (`perftest`) catches
bugs that keep results correct but cost cycles:

| Injected bug | Random seeds failing (of 20) | perftest |
|---|---|---|
| No MEM→EX forwarding | 20 | fail |
| No WB→EX forwarding | 20 | fail |
| Forwarding priority reversed (WB before MEM) | 20 | fail |
| Forwarding a result destined for x0 | 19 | fail |
| No load-use stall | 20 | fail |
| Load-use check ignores rs2 | 20 | fail |
| No flush after a taken branch | 20 | fail |
| JALR doesn't clear bit 0 | 20 | pass |
| BLTU compares signed | 13 | pass |
| LB zero-extends | 18 | pass |
| SB writes the wrong byte lane | 20 | pass |
| SRA behaves like SRL | 17 | pass |
| Register file not write-through | 20 | fail |
| Wrongly-taken branch resumes at its target, not pc+4 | 20 | fail |
| Prediction not passed to EX | 20 | fail |
| EX trusts a predicted JALR target without checking | 20 | fail |
| Decode redirect ignores a stall | 19 | fail |
| Decode redirect outranks an EX redirect | 20 | fail |
| Decode drops JAL | 20 | fail |
| Branch history table never trained | **0** | fail |
| gshare history never updated | **0** | fail |
| Return-address stack never pops | **0** | fail |
| Return-address stack pushes pc instead of pc+4 | **0** | fail |

23/23 killed. The last four are performance bugs: the core still computes the
right answers, so no amount of co-simulation can find them.

## Performance

### CoreMark

`make bench` runs EEMBC CoreMark (2K performance run, clang -O2, RV32I). The
list, matrix and state CRCs match the reference values (0xe714 / 0x1fd7 /
0x8e3a), and one full iteration is co-simulated against the reference model
in `make test`.

| Metric | Base pipeline | With branch prediction |
|---|---|---|
| CoreMark/MHz | 0.970 | 1.083 |
| CPI | 1.164 | 1.043 |

(The base-pipeline numbers are with linker relaxation enabled; see below.)

CoreMark requires a 10-second run for an official score (500M cycles at
50 MHz), which isn't practical in simulation, so these are CoreMark/MHz
measurements rather than certified results.

### Where the cycles go

The core has seven hardware performance counters (`hpmcounter3`-`9`, read
with `csrr`): load-use stall cycles, flush cycles, branches, taken branches,
jumps, branch mispredictions, and jump redirects. CoreMark reads them around
its timed region and prints a CPI stack. On the base pipeline:

```
CPI stack (share of cycles):
  retiring              8961067 (86.0%)
  load-use stalls       272264 (2.6%)
  branch/jump flushes   1186463 (11.3%)
  other                 0 (0.0%)
Control flow:
  taken branches        895742 (64.3%)
```

"Other" is exactly zero: every cycle is an instruction retiring, a load-use
stall, or a flush, so the counters account for the whole run.
`sw/perftest` checks each counter against assembly kernels with hand-computed
event counts. It also catches performance-only bugs that co-simulation can't,
such as stalling on a load into `x0`.

**Takeaway (base pipeline):** control flow is the bottleneck. 11.3% of cycles
are flushes, because the core predicts not-taken and 64% of CoreMark's branches
are taken. Load-use stalls are a distant second.

With branch prediction, flushes drop to 1.1% of cycles and load-use stalls
(2.9%) become the largest loss:

```
CPI stack (share of cycles):
  retiring              8848885 (95.8%)
  load-use stalls       272264 (2.9%)
  branch/jump flushes   110492 (1.1%)
  other                 0 (0.0%)
Control flow:
  taken branches        895742 (64.3%)
  mispredicted branches 83292 (5.9%)
  redirected jumps      27200 (9.3%)
```

### Branch prediction: study first, then hardware

Before building anything, `make study` replays CoreMark's branch and jump
outcomes through software models of each scheme, using this pipeline's
penalties, and estimates CPI. Then each scheme was built in RTL and measured
on the same run (one CoreMark iteration). The estimates matched the hardware
to within 0.001 CPI on every row:

| Configuration | Mispredicted branches | Study CPI | Hardware CPI |
|---|---|---|---|
| Baseline: predict not-taken, jumps resolve in EX | 64.6% | 1.160 | 1.160 |
| + JAL resolved in decode | 64.6% | 1.145 | 1.145 |
| + static BTFN (backward taken, forward not) | 15.0% | 1.069 | 1.069 |
| bimodal, 256 × 2-bit counters | 10.0% | 1.061 | 1.061 |
| gshare, 256 entries, 8-bit global history | 6.4% | 1.056 | 1.056 |
| + return-address stack (8 entries) | 6.4% | 1.044 | 1.044 |
| + indirect jump target buffer (16 entries) | 6.4% | 1.042 | 1.043 |
| Perfect prediction (upper bound) | 0% | 1.030 | |

CoreMark (10 iterations) across configurations, from `make bench-configs`:

| Configuration | CoreMark/MHz | CPI | Branches mispredicted | Jumps redirected |
|---|---|---|---|---|
| Baseline | 0.970 | 1.164 | 64.3% | 100% |
| Early JAL | 0.983 | 1.149 | 64.3% | 53.6% |
| BTFN | 1.055 | 1.070 | 14.1% | 53.6% |
| Bimodal | 1.061 | 1.064 | 10.1% | 53.6% |
| gshare | 1.068 | 1.057 | 5.9% | 53.6% |
| gshare + RAS | 1.081 | 1.045 | 5.9% | 15.7% |
| gshare + target buffer | 1.075 | 1.050 | 5.9% | 31.1% |
| **gshare + RAS + target buffer** | **1.083** | **1.043** | **5.9%** | **9.3%** |

What the data shows:
- **Loop structure does most of the work.** Backward branches are taken 85%
  of the time and forward ones 16%, so a free static rule (BTFN) removes
  three quarters of the mispredictions.
- **Table size barely matters; history does.** Bimodal goes from 10.1% to
  9.8% mispredicted between 64 and 1024 entries, but adding 8 bits of global
  history (gshare) brings it to 6.4%. `perftest` shows why with a branch
  that alternates taken/not-taken: a 2-bit counter is always one step behind
  and mispredicts every time (101/101), while gshare learns it (8).
- **The toolchain mattered as much as the hardware.** The study showed half
  the JALRs weren't returns but function calls emitted as `auipc`+`jalr`,
  because the build disabled linker relaxation. Enabling it turned every call
  into a single `jal` (1.25% fewer instructions) that decode follows for free.
- **Diminishing returns are measurable.** After the return-address stack,
  the only jumps left are `switch` tables whose target depends on input data.
  A 16-entry last-target buffer catches about 40% of them for +0.2%; the
  study shows 64 entries does no better.
- **Aliasing is real.** With 4-entry tables, `perftest`'s never-taken branch
  and its loop branch share one counter and thrash it: 196 of 200
  mispredicted.

### Branch prediction design

All prediction happens in decode, and all of it is checked in execute.

- **Redirects from decode are free.** The instruction RAM is synchronous, so
  IF is only an address phase: when decode decides to redirect (a `jal`, a
  branch predicted taken, a predicted return), the new address goes to the
  RAM in the same cycle and no instruction is lost. That's also why this
  core needs no branch target buffer for direct branches: decode computes
  `pc + imm` itself, in time.
- **A misprediction costs one cycle,** because branches resolve in EX, one
  stage after decode.
- **Nothing ever needs repair.** A branch resolves while the instruction
  behind it is still in decode, and everything that reaches EX retires. So
  the history table, the global history register and the return-address
  stack are only ever updated by instructions that really execute. Deeper
  pipelines have to checkpoint and restore this state on a misprediction.
- **gshare's history is updated in EX** with real outcomes, so a branch
  decoded right behind another doesn't see that branch's outcome yet. It
  costs nothing measurable here (study and hardware agree) and keeps the
  index logic off the forwarding → compare critical path.
- **The return-address stack follows the RISC-V link-register hints**
  (x1/x5): calls push, returns pop, and a `jalr` that is both pops then
  pushes. It's a circular buffer, so recursion deeper than 8 just
  mispredicts.

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
- **Control hazards:** branches are predicted in decode (gshare), returns by
  the return-address stack and other indirect jumps by the target buffer;
  `jal` is followed in decode. Everything resolves in EX, and a wrong
  prediction flushes the one instruction behind it (1-cycle penalty).
