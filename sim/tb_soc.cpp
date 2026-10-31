// Verilator testbench for rv_soc.
//   +firmware=<hex>      program image ($readmemh format)
//   +trace=<file>        write a commit trace: one line per retired instruction,
//                        "<pc> <instr>[ x<rd>=<value>]", and one per trap taken,
//                        "trap <mcause> pc=<mepc> tval=<mtval>"
//   +max_traps=<n>       stop after this many traps (default 100k: a trap loop)
//   +max_cycles=<n>      timeout (default 50M)
//   +vcd=<file>          dump waveforms
// Prints UART output to stdout; stats to stderr. Exit status = program's exit code.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <memory>
#include "Vrv_soc.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char **argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(argc, argv);
  auto top = std::make_unique<Vrv_soc>(ctx.get());

  const char *arg;
  FILE *trace = nullptr;
  if ((arg = ctx->commandArgsPlusMatch("trace=")) && *arg) {
    trace = fopen(strchr(arg, '=') + 1, "w");
  }
  uint64_t max_cycles = 50'000'000;
  if ((arg = ctx->commandArgsPlusMatch("max_cycles=")) && *arg) {
    max_cycles = strtoull(strchr(arg, '=') + 1, nullptr, 0);
  }
  std::unique_ptr<VerilatedVcdC> vcd;
  if ((arg = ctx->commandArgsPlusMatch("vcd=")) && *arg) {
    ctx->traceEverOn(true);
    vcd = std::make_unique<VerilatedVcdC>();
    top->trace(vcd.get(), 99);
    vcd->open(strchr(arg, '=') + 1);
  }

  uint64_t t = 0;
  auto tick = [&]() {
    top->clk = 0; top->eval(); if (vcd) vcd->dump(t++);
    top->clk = 1; top->eval(); if (vcd) vcd->dump(t++);
  };

  top->rst = 1;
  for (int i = 0; i < 5; i++) tick();
  top->rst = 0;

  uint64_t max_traps = 100'000;
  if ((arg = ctx->commandArgsPlusMatch("max_traps=")) && *arg) {
    max_traps = strtoull(strchr(arg, '=') + 1, nullptr, 0);
  }

  uint64_t cycles = 0, retired = 0, traps = 0;
  int exit_code = -1;
  bool done = false;
  int drain = -1;  // SIM_EXIT is written from EX; let that store retire (2 more cycles)
  const char *why = "timeout";

  while (!done && cycles < max_cycles) {
    if (drain == 0) break;
    if (drain > 0) drain--;

    // Sample combinational outputs for this cycle before the clock edge
    top->clk = 0; top->eval(); if (vcd) vcd->dump(t++);

    if (top->commit_valid) {
      retired++;
      if (trace) {
        if (top->commit_rd_we)
          fprintf(trace, "%08x %08x x%d=%08x\n", top->commit_pc, top->commit_instr,
                  top->commit_rd, top->commit_rd_val);
        else
          fprintf(trace, "%08x %08x\n", top->commit_pc, top->commit_instr);
      }
    }
    if (top->commit_trap) {
      traps++;
      if (trace)
        fprintf(trace, "trap %08x pc=%08x tval=%08x\n", top->commit_cause, top->commit_pc,
                top->commit_tval);
      if (traps >= max_traps) { why = "trap storm"; done = true; }
    }
    if (drain < 0 && top->tx_valid) { putchar(top->tx_byte); fflush(stdout); }
    if (drain < 0 && top->exit_valid) { exit_code = (int)top->exit_code; why = "exit"; drain = 2; }

    top->clk = 1; top->eval(); if (vcd) vcd->dump(t++);
    cycles++;
  }

  fprintf(stderr, "[tb] stop: %s  code=%d  cycles=%llu  retired=%llu  CPI=%.3f  traps=%llu  leds=0x%02x\n",
          why, exit_code, (unsigned long long)cycles, (unsigned long long)retired,
          retired ? (double)cycles / retired : 0.0, (unsigned long long)traps, top->leds);

  if (trace) fclose(trace);
  if (vcd) vcd->close();
  top->final();
  return exit_code < 0 ? 2 : exit_code;
}
