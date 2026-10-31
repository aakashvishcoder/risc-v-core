# Build RV32I programs with clang + ld.lld.
#   make PROG=hello          -> build/hello.{elf,bin,hex,dis}
#   make PROG=coremark ITERATIONS=10
#   make PROG=hello MARCH=rv32i_zicsr      -> for a core without multiply/divide
#   make PROG=hello MARCH=rv32i_zmmul_zicsr -> multiply only
PROG   ?= hello
MARCH  ?= rv32im_zicsr
OPT    ?= -O2
BUILD  ?= build

# CoreMark: iteration count and the flags string it reports
ITERATIONS ?= 10
ifeq ($(PROG),coremark)
CFLAGS_EXTRA += -DITERATIONS=$(ITERATIONS) -DFLAGS_STR='"$(OPT) $(MARCH)"' \
                -Wno-implicit-function-declaration
endif

# Tell the runtime which libgcc helpers the hardware makes unnecessary
ifneq ($(findstring zmmul,$(MARCH))$(findstring im,$(MARCH)),)
CFLAGS_EXTRA += -DHAVE_MUL
endif
ifneq ($(findstring im,$(MARCH)),)
CFLAGS_EXTRA += -DHAVE_DIV
endif

CC      = clang
OBJCOPY = llvm-objcopy
OBJDUMP = llvm-objdump

CFLAGS  = --target=riscv32-unknown-elf -march=$(MARCH) -mabi=ilp32 $(OPT) \
          -ffreestanding -fno-builtin -nostdlib -Wall \
          -Icommon -I$(PROG) $(CFLAGS_EXTRA)
LDFLAGS = -fuse-ld=lld -Wl,-T,common/link.ld -static

SRCS = common/crt0.S common/rt.c $(wildcard $(PROG)/*.c) $(wildcard $(PROG)/*.S)

all: $(BUILD)/$(PROG).hex

$(BUILD)/$(PROG).elf: $(SRCS) common/link.ld common/rt.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $@

$(BUILD)/$(PROG).bin: $(BUILD)/$(PROG).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/$(PROG).hex: $(BUILD)/$(PROG).bin
	python3 ../tools/bin2hex.py $< $@
	$(OBJDUMP) -d --no-show-raw-insn $(BUILD)/$(PROG).elf > $(BUILD)/$(PROG).dis

clean:
	rm -rf $(BUILD)

.PHONY: all clean
