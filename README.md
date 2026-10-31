# risc-v-core

A 5-stage pipelined RISC-V (RV32IM) processor written in SystemVerilog, with
gshare branch prediction, a return-address stack, an indirect jump target
buffer and a hardware multiplier and divider, built to run on my
[Artix-7 FPGA carrier board](https://github.com/aakashvishcoder/fpgacarrierboard).

## Status

Work in progress. The core runs C programs in simulation:

```
$ make -C sw PROG=hello && make -C sim run HEX=../sw/build/hello.hex
Hello from risc-v-core!
printing that took 232 cycles, 201 instructions
[tb] stop: exit  code=0  cycles=956  retired=788  CPI=1.213  leds=0xa5
```

| | Baseline pipeline | + branch prediction | + multiply/divide |
|---|---|---|---|
| CoreMark/MHz | 0.970 | 1.083 (+11.6%) | **2.372** (2.45× baseline) |
| CPI | 1.164 | 1.043 | 1.140 |
| Instructions (10 iterations) | 8.85M | 8.85M | 3.70M |

## Roadmap

- [x] 5-stage RV32I pipeline (forwarding, load-use stall, branch flush)
- [x] SoC with block RAM, UART, memory-mapped I/O
- [x] Bare-metal C toolchain + Verilator testbench
- [x] Verification: instruction-set reference model, random co-simulation, mutation testing
- [x] CoreMark port, hardware performance counters, branch predictor study
- [x] Branch prediction: static, bimodal, gshare, return-address stack, indirect target buffer
- [x] M extension: pipelined multiplier, iterative divider
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
make -C sim OBJ=obj_mine EARLY_JAL=1 BPRED=3 BHT_BITS=8 GHR_BITS=8 RAS_DEPTH=8 IBTB_BITS=4 M_EXT=2
```

`BPRED` selects 0 = predict not-taken, 1 = static BTFN, 2 = bimodal, 3 = gshare.
`M_EXT` selects 0 = no M extension, 1 = multiply only (Zmmul), 2 = full M.
Software can read the configuration from the `mconfig` CSR (0xFC0). Programs
build for `rv32im` by default; pass `MARCH=rv32i_zicsr` (or
`rv32i_zmmul_zicsr`) to `make -C sw` for a core without M.

Testbench options: `+trace=<file>` writes one line per retired instruction,
`+vcd=<file>` dumps waveforms, `+max_cycles=<n>` sets a timeout.

## Verification

`make test` runs everything below in about a minute.

```
== reference model known-answer tests
16/16 reference-model tests passed
== directed programs (RTL vs reference model)
hello            MATCH: 788 instructions | uart ok | exit  code=0  cycles=956 ...
perftest         MATCH: 21589 instructions | uart ok | exit  code=0  cycles=28800 ...
mext             MATCH: 1037 instructions | uart ok | exit  code=0  cycles=3038 ...
coremark_1iter   MATCH: 408859 instructions | uart ok | exit  code=0  cycles=469314 ...
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

**Multiply/divide corner cases.** `sw/mext` checks 30 results the spec
defines exactly: MULH/MULHSU/MULHU on extreme operands, divide by zero,
`INT_MIN / -1`, and every sign combination of DIV and REM. Random programs
also mix in M instructions. Some bugs need both: a REM that takes the
divisor's sign fails only 5 of 20 random seeds, but the directed test every
time.

**Every configuration.** `make test-configs` builds eleven configurations side
by side, from the baseline pipeline up to full prediction with RV32IM, and
runs the counter test, the M test (where the core has M), a co-simulated
CoreMark iteration and random programs on each. Programs are compiled for
each configuration's instruction set. One build has 4-entry tables, a 2-entry
return-address stack and a 2-entry target buffer, so aliasing and overflow
happen constantly.

**Mutation testing.** Passing tests only matter if they would fail on a broken
design. `tools/mutate.py` (`make mutate`) injects realistic bugs, one at a
time, into a copy of the RTL and checks that the tests catch each. Random
co-simulation (RV32IM) catches wrong results, `sw/mext` checks multiply/divide
results directly, and the counter test (`perftest`) catches bugs that keep
results correct but cost cycles:

| Injected bug | Random seeds failing (of 20) | perftest | mext |
|---|---|---|---|
| No MEM→EX forwarding | 20 | fail | fail |
| No WB→EX forwarding | 20 | fail | fail |
| Forwarding priority reversed (WB before MEM) | 20 | fail | fail |
| Forwarding a result destined for x0 | 20 | fail | pass |
| No load-use stall | 20 | fail | fail |
| Load-use check ignores rs2 | 20 | fail | fail |
| No flush after a taken branch | 20 | fail | fail |
| JALR doesn't clear bit 0 | 19 | pass | pass |
| BLTU compares signed | 14 | pass | pass |
| LB zero-extends | 20 | pass | pass |
| SB writes the wrong byte lane | 20 | pass | pass |
| SRA behaves like SRL | 17 | pass | pass |
| Register file not write-through | 20 | fail | fail |
| Wrongly-taken branch resumes at its target, not pc+4 | 20 | fail | fail |
| Prediction not passed to EX | 20 | fail | fail |
| EX trusts a predicted JALR target without checking | 20 | fail | fail |
| Decode redirect ignores a stall | 20 | fail | pass |
| Decode redirect outranks an EX redirect | 20 | fail | pass |
| Decode drops JAL | 20 | fail | fail |
| No multiply-use stall | 6 | fail | fail |
| MULHSU treats rs2 as signed | 8 | pass | fail |
| MULH* return the low word | 20 | fail | fail |
| Divide doesn't hold EX | 20 | fail | fail |
| No MEM bubbles while dividing | 20 | pass | pass |
| Divide by zero returns 0 | 17 | pass | fail |
| REM takes the divisor's sign | 5 | pass | fail |
| Branch history table never trained | **0** | fail | pass |
| gshare history never updated | **0** | fail | pass |
| Return-address stack never pops | **0** | fail | pass |
| Return-address stack pushes pc instead of pc+4 | **0** | fail | pass |
| Divide by zero runs all 32 iterations | **0** | fail | pass |

31/31 killed. The five marked **0** are performance bugs: the core still
computes the right answers, so no amount of co-simulation can find them.

## Performance

### CoreMark

`make bench` runs EEMBC CoreMark (2K performance run, clang -O2, RV32IM). The
list, matrix and state CRCs match the reference values (0xe714 / 0x1fd7 /
0x8e3a), and one full iteration is co-simulated against the reference model
in `make test`.

| Metric | Base pipeline (RV32I) | + branch prediction | + multiply/divide (RV32IM) |
|---|---|---|---|
| CoreMark/MHz | 0.970 | 1.083 | 2.372 |
| CPI | 1.164 | 1.043 | 1.140 |

(All with linker relaxation enabled; see below.)

CoreMark requires a 10-second run for an official score (500M cycles at
50 MHz), which isn't practical in simulation, so these are CoreMark/MHz
measurements rather than certified results.

### Where the cycles go

The core has nine hardware performance counters (`hpmcounter3`-`11`, read
with `csrr`): load-use stall cycles, flush cycles, branches, taken branches,
jumps, branch mispredictions, jump redirects, multiply-use stall cycles and
divider stall cycles. CoreMark reads them around its timed region and prints
a CPI stack. On the base pipeline:

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

With branch prediction (still RV32I), flushes drop to 1.1% of cycles and
load-use stalls (2.9%) become the largest loss:

```
CPI stack (share of cycles):
  retiring              8848891 (95.8%)
  load-use stalls       272264 (2.9%)
  multiply-use stalls   0 (0.0%)
  divider stalls        0 (0.0%)
  branch/jump flushes   110709 (1.1%)
  other                 0 (0.0%)
Control flow:
  taken branches        895742 (64.3%)
  mispredicted branches 83509 (6.0%)
  redirected jumps      27200 (9.3%)
```

With multiply and divide in hardware, the instruction count drops by 58% and
every remaining stall weighs more. Load-use stalls are now 7.9% of cycles, the
clear next target:

```
CPI stack (share of cycles):
  retiring              3697411 (87.7%)
  load-use stalls       336344 (7.9%)
  multiply-use stalls   94680 (2.2%)
  divider stalls        0 (0.0%)
  branch/jump flushes   86632 (2.0%)
  other                 0 (0.0%)
Control flow:
  taken branches        313222 (50.5%)
  mispredicted branches 59432 (9.5%)
```

### Branch prediction: study first, then hardware

Before building anything, `make study` replays CoreMark's branch and jump
outcomes through software models of each scheme, using this pipeline's
penalties, and estimates CPI. Then each scheme was built in RTL and measured
on the same run (one CoreMark iteration, RV32I build, before the M extension).
The estimates matched the hardware to within 0.002 CPI on every row:

| Configuration | Mispredicted branches (study) | Study CPI | Hardware CPI |
|---|---|---|---|
| Baseline: predict not-taken, jumps resolve in EX | 64.6% | 1.160 | 1.160 |
| + JAL resolved in decode | 64.6% | 1.144 | 1.144 |
| + static BTFN (backward taken, forward not) | 15.1% | 1.069 | 1.069 |
| bimodal, 256 × 2-bit counters | 10.0% | 1.061 | 1.061 |
| gshare, 256 entries, 8-bit global history | 7.3% | 1.057 | 1.056 |
| + return-address stack (8 entries) | 7.3% | 1.046 | 1.044 |
| + indirect jump target buffer (16 entries) | 7.3% | 1.044 | 1.042 |
| Perfect prediction (upper bound) | 0% | 1.030 | |

The static and bimodal rows match exactly. In the gshare rows the hardware
does slightly better than the model; the two differ in when the global
history sees each outcome, which changes which branches share counters.

CoreMark (10 iterations, RV32I) across configurations, from `make bench-configs`:

| Configuration | CoreMark/MHz | CPI | Branches mispredicted | Jumps redirected |
|---|---|---|---|---|
| Baseline | 0.970 | 1.164 | 64.3% | 100% |
| Early JAL | 0.983 | 1.149 | 64.3% | 53.6% |
| BTFN | 1.055 | 1.070 | 14.1% | 53.6% |
| Bimodal | 1.061 | 1.064 | 10.1% | 53.6% |
| gshare | 1.068 | 1.057 | 6.0% | 53.6% |
| gshare + RAS | 1.081 | 1.045 | 6.0% | 15.7% |
| gshare + target buffer | 1.075 | 1.050 | 6.0% | 31.1% |
| **gshare + RAS + target buffer** | **1.083** | **1.043** | **6.0%** | **9.3%** |

What the data shows:
- **Loop structure does most of the work.** Backward branches are taken 85%
  of the time and forward ones 16%, so a free static rule (BTFN) removes
  three quarters of the mispredictions.
- **Table size barely matters; history does.** Bimodal goes from 10.1% to
  9.7% mispredicted between 64 and 1024 entries, but adding 8 bits of global
  history (gshare) brings it to 7.3%. `perftest` shows why with a branch
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

### Multiply and divide

| Configuration (with full prediction) | CoreMark/MHz | CPI | Instructions | Branches mispredicted |
|---|---|---|---|---|
| RV32I (software multiply/divide) | 1.083 | 1.043 | 8.85M | 6.0% |
| + multiplier (Zmmul) | 2.372 | 1.139 | 3.70M | 9.5% |
| + divider (full M) | 2.372 | 1.140 | 3.70M | 9.5% |

- **The multiplier more than doubles performance (2.19×).** On RV32I every
  multiply is a call to a shift-and-add loop; that loop was 58% of every
  instruction CoreMark executed.
- **CPI goes up, and that's expected.** The instructions that disappeared
  were cheap, predictable loop instructions, so the stalls that remain are a
  bigger share of fewer cycles. Branch misprediction rises from 6.0% to 9.5%
  for the same reason: the multiply loop's branches were easy to predict, and
  what's left is CoreMark's real control flow.
- **The divider doesn't change CoreMark at all**, because its timed region
  contains no divides (divider stall cycles: 0). It only speeds up code like
  `printf`. So for this workload a faster divider (radix-4, early
  termination) would be wasted area, and the simple radix-2 divider stays.

Design:
- **Multiplier.** Operands are sign- or zero-extended to 33 bits in EX, so a
  single signed 33×33 multiply covers MUL, MULH, MULHSU and MULHU. The
  multiply happens in MEM, between the EX/MEM and MEM/WB pipeline registers,
  which is the shape of a Xilinx DSP48 with input and output registers. Like
  a load, the product only exists at the end of MEM, so it can't be
  forwarded from MEM, and an instruction that needs it immediately stalls
  one cycle (`perftest` checks this exactly).
- **Divider.** Radix-2 restoring division on magnitudes, one quotient bit
  per cycle, with signs fixed at the end. A divide holds EX for 33 cycles
  (1 to start + 32 iterations); everything behind it waits and MEM gets
  bubbles. Divide by zero returns the spec's defined result in 1 cycle;
  `INT_MIN / -1` falls out of the magnitude arithmetic with no special case.
  The quotient leaves EX like an ALU result, so a dependent instruction gets
  it by forwarding with no extra stall.

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
- **Multiply** results are produced in MEM (like loads); a **divide** holds
  EX for 33 cycles.
