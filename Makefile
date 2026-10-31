# Top-level convenience targets.
#   make test        reference-model tests + directed programs + 100 random seeds
#   make test-quick  same with 20 random seeds
#   make mutate      mutation testing (slow, ~3 min)
SEEDS ?= 100
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: test test-quick mutate sim hello progs clean

sim:
	$(MAKE) -s -C sim

hello:
	$(MAKE) -s -C sw PROG=hello

PROGS = hello perftest
progs:
	@for p in $(PROGS); do $(MAKE) -s -C sw PROG=$$p || exit 1; done

test: sim progs
	@echo "== reference model known-answer tests"
	@PYTHONDONTWRITEBYTECODE=1 python3 tools/test_iss.py | tail -1
	@echo "== directed programs (RTL vs reference model)"
	@for p in $(PROGS); do tools/cosim.sh sw/build/$$p.hex || exit 1; done
	@echo "== random programs"
	@tools/run_random.sh $(SEEDS) 1

test-quick:
	@$(MAKE) -s test SEEDS=20

mutate: sim
	@python3 tools/mutate.py --seeds 20

clean:
	$(MAKE) -s -C sim clean
	$(MAKE) -s -C sw clean
	rm -rf out
