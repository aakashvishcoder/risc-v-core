# Top-level convenience targets.
#   make test        reference-model tests + directed programs + 100 random seeds (RV32IM)
#   make test-quick  same with 20 random seeds
#   make test-configs  every predictor configuration: perftest, CoreMark, random (~4 min)
#   make bench-configs same, plus CoreMark/MHz per configuration
#   make mutate      mutation testing (slow, ~6 min)
#   make bench       CoreMark (10 iterations) with the CPI stack
#   make study       trace-driven branch predictor study on CoreMark
SEEDS ?= 100
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test test-quick test-configs bench-configs mutate bench study sim hello progs clean

sim:
	$(MAKE) -s -C sim

hello:
	$(MAKE) -s -C sw PROG=hello

PROGS = hello perftest mext
progs:
	@for p in $(PROGS); do $(MAKE) -s -C sw PROG=$$p || exit 1; done

test: sim progs
	@echo "== reference model known-answer tests"
	@PYTHONDONTWRITEBYTECODE=1 python3 tools/test_iss.py | tail -1
	@echo "== directed programs (RTL vs reference model)"
	@for p in $(PROGS); do tools/cosim.sh sw/build/$$p.hex || exit 1; done
	@$(MAKE) -s -C sw PROG=coremark ITERATIONS=1 BUILD=build/cm1
	@mkdir -p out && cp sw/build/cm1/coremark.hex out/coremark_1iter.hex
	@tools/cosim.sh out/coremark_1iter.hex
	@echo "== random programs"
	@tools/run_random.sh $(SEEDS) 1 --m

test-quick:
	@$(MAKE) -s test SEEDS=20

bench: sim
	@$(MAKE) -s -C sw PROG=coremark ITERATIONS=10
	@sim/obj_dir/Vrv_soc +firmware=sw/build/coremark.hex 2>&1 | \
	  sed -n '/^\[0\]crc/p; /^risc-v-core:/,$$p'

# The study replays a trace from the baseline configuration (no prediction)
study:
	@$(MAKE) -s -C sim OBJ=obj_base EARLY_JAL=0 BPRED=0 RAS_DEPTH=0 IBTB_BITS=0
	@$(MAKE) -s -C sw PROG=coremark ITERATIONS=1 BUILD=build/cm1
	@mkdir -p out
	@sim/obj_base/Vrv_soc +firmware=sw/build/cm1/coremark.hex +trace=out/study.rtl \
	  >/dev/null 2>out/study.rtl.log
	@python3 tools/bpred_study.py out/study.rtl

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
