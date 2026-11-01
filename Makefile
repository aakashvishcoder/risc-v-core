# Top-level convenience targets.
#   make test        reference-model tests + directed programs + 100 random seeds (RV32IM),
#                    on single-cycle RAM and on the cached memory system
#   make test-quick  same with 20 random seeds
#   make test-configs  every predictor configuration: perftest, CoreMark, random (~4 min)
#   make bench-configs same, plus CoreMark/MHz per configuration
#   make mutate      mutation testing (slow, ~6 min)
#   make bench       CoreMark (10 iterations) with the CPI stack
#   make study       trace-driven branch predictor study on CoreMark
#   make cache-study trace-driven cache study on CoreMark and memstream
SEEDS ?= 100
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: sim-cache test test-quick test-configs bench-configs mutate demo compliance bench study cache-study sim hello progs clean

sim:
	$(MAKE) -s -C sim

hello:
	$(MAKE) -s -C sw PROG=hello

PROGS = hello perftest mext cachetest coldload memstream traptest irqtest sched fencei
CACHE_SIM = sim/obj_cache/Vrv_soc
progs:
	@for p in $(PROGS); do $(MAKE) -s -C sw PROG=$$p || exit 1; done

sim-cache:
	$(MAKE) -s -C sim OBJ=obj_cache CACHES=1

test: sim sim-cache progs
	@echo "== reference model known-answer tests"
	@PYTHONDONTWRITEBYTECODE=1 python3 tools/test_iss.py | tail -1
	@$(MAKE) -s -C sw PROG=coremark ITERATIONS=1 BUILD=build/cm1
	@mkdir -p out && cp sw/build/cm1/coremark.hex out/coremark_1iter.hex
	@echo "== directed programs (RTL vs reference model), single-cycle RAM"
	@for p in $(PROGS); do tools/cosim.sh sw/build/$$p.hex || exit 1; done
	@tools/cosim.sh out/coremark_1iter.hex
	@echo "== directed programs, caches + slow main memory"
	@for p in $(PROGS); do SIM=$(CURDIR)/$(CACHE_SIM) tools/cosim.sh sw/build/$$p.hex || exit 1; done
	@SIM=$(CURDIR)/$(CACHE_SIM) tools/cosim.sh out/coremark_1iter.hex
	@echo "== random programs, single-cycle RAM"
	@tools/run_random.sh $(SEEDS) 1 --m
	@echo "== random programs, caches + slow main memory"
	@SIM=$(CURDIR)/$(CACHE_SIM) tools/run_random.sh $$(( $(SEEDS) / 2 )) 5000 --m
	@echo "== random programs with exceptions and interrupts, single-cycle RAM"
	@TRAPS=1 tools/run_random.sh $(SEEDS) 10000 --m
	@echo "== random programs with exceptions and interrupts, caches + slow main memory"
	@TRAPS=1 SIM=$(CURDIR)/$(CACHE_SIM) tools/run_random.sh $$(( $(SEEDS) / 2 )) 15000 --m

test-quick:
	@$(MAKE) -s test SEEDS=20

# Official RISC-V architecture tests (riscv-arch-test 2.7.4), on the
# single-cycle-RAM core and on the cached memory system. Clones the test
# suite into build/ on first use.
compliance:
	@python3 compliance/run.py
	@$(MAKE) -s -C sim OBJ=obj_act_cache CACHES=1 MEM_WORDS=1048576
	@python3 compliance/run.py --sim sim/obj_act_cache/Vrv_soc | tail -1

# Preemptive scheduler demo: three tasks time-sliced by the timer interrupt
demo: sim
	@$(MAKE) -s -C sw PROG=sched
	@sim/obj_dir/Vrv_soc +firmware=sw/build/sched.hex

bench: sim
	@$(MAKE) -s -C sw PROG=coremark ITERATIONS=10
	@sim/obj_dir/Vrv_soc +firmware=sw/build/coremark.hex 2>&1 | \
	  sed -n '/^\[0\]crc/p; /^risc-v-core:/,$$p'

# The study replays a trace from the baseline configuration (no prediction,
# RV32I, as in the README's study table)
study:
	@$(MAKE) -s -C sim OBJ=obj_base EARLY_JAL=0 BPRED=0 RAS_DEPTH=0 IBTB_BITS=0 M_EXT=0
	@$(MAKE) -s -C sw PROG=coremark ITERATIONS=1 MARCH=rv32i_zicsr BUILD=build/study
	@mkdir -p out
	@sim/obj_base/Vrv_soc +firmware=sw/build/study/coremark.hex +trace=out/study.rtl \
	  >/dev/null 2>out/study.rtl.log
	@python3 tools/bpred_study.py out/study.rtl

# The cache study replays each program's fetch and load/store address streams
# (fetches from the RTL commit trace, data addresses from the reference model)
CACHE_PEN ?=
cache-study: sim
	@$(MAKE) -s -C sw PROG=coremark ITERATIONS=1 BUILD=build/cm1
	@$(MAKE) -s -C sw PROG=memstream
	@mkdir -p out
	@for p in cm1/coremark memstream; do n=$$(basename $$p); \
	  sim/obj_dir/Vrv_soc +firmware=sw/build/$$p.hex +trace=out/cs_$$n.rtl >/dev/null 2>&1; \
	  PYTHONDONTWRITEBYTECODE=1 python3 tools/iss.py sw/build/$$p.hex --m --sync out/cs_$$n.rtl \
	    --mem-trace out/cs_$$n.mem >/dev/null 2>&1; \
	  echo "=== $$n"; python3 tools/cache_study.py out/cs_$$n.rtl out/cs_$$n.mem $(CACHE_PEN); done

test-configs:
	@mkdir -p out && tools/test_configs.sh 30

bench-configs:
	@mkdir -p out && tools/test_configs.sh 30 --bench

mutate: sim
	@python3 tools/mutate.py --seeds 20

clean:
	$(MAKE) -s -C sim clean
	$(MAKE) -s -C sw clean
	rm -rf out
