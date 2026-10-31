# Verilator build of the SoC testbench.
#   make                                 -> obj_dir/Vrv_soc
#   make run HEX=../sw/build/hello.hex
#   make run HEX=... ARGS="+trace=t.txt +vcd=wave.vcd"
RTL_DIR = ../rtl
RTL = $(RTL_DIR)/rv_alu.sv $(RTL_DIR)/rv_regfile.sv $(RTL_DIR)/rv_core.sv \
      $(RTL_DIR)/rv_ram.sv $(RTL_DIR)/uart_tx.sv $(RTL_DIR)/rv_soc.sv

OBJ ?= obj_dir
VFLAGS = --cc --exe --build -j 0 -O3 --trace -Wall -Wno-fatal \
         -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
         -I$(RTL_DIR) +define+SIMULATION --top-module rv_soc \
         -GCLKS_PER_BIT=0 -CFLAGS -O2 -Mdir $(OBJ)

$(OBJ)/Vrv_soc: $(RTL) tb_soc.cpp
	verilator $(VFLAGS) $(RTL) tb_soc.cpp 2>&1 | grep -E '%(Error|Warning)' -A3 || true
	@test -x $@

run: $(OBJ)/Vrv_soc
	./$(OBJ)/Vrv_soc +firmware=$(HEX) $(ARGS)

clean:
	rm -rf obj_dir obj_*

.PHONY: run clean
