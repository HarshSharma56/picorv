
RISCV_GNU_TOOLCHAIN_REV = 7e48594
NEWLIB_URL = ftp://sourceware.org/pub/newlib/newlib-2.2.0.tar.gz

SHELL = bash
TEST_OBJS = $(addsuffix .o,$(basename $(wildcard tests/*.S)))
FIRMWARE_OBJS = firmware/start.o firmware/irq.o firmware/print.o firmware/sieve.o firmware/multest.o firmware/stats.o
GCC_WARNS  = -Werror -Wall -Wextra -Wshadow -Wundef -Wpointer-arith -Wcast-qual -Wcast-align -Wwrite-strings
GCC_WARNS += -Wredundant-decls -Wstrict-prototypes -Wmissing-prototypes -pedantic # -Wconversion
TOOLCHAIN_PREFIX = /opt/riscv32i/bin/riscv32-unknown-elf-
COMPRESSED_ISA = C

test: testbench.vvp firmware/firmware.hex
	vvp -N testbench.vvp

testbench.vcd: testbench.vvp firmware/firmware.hex
	vvp -N $< +vcd +trace +noerror

view: testbench.vcd
	gtkwave $< testbench.gtkw

check: check-yices

check-%: check.smt2
	yosys-smtbmc -s $(subst check-,,$@) -t 30 --dump-vcd check.vcd check.smt2
	yosys-smtbmc -s $(subst check-,,$@) -t 25 --dump-vcd check.vcd -i check.smt2

check.smt2: picorv32.v
	yosys -v2 -p 'read_verilog -formal picorv32.v' \
	          -p 'prep -top picorv32 -nordff' \
		  -p 'assertpmux -noinit; opt -fast' \
		  -p 'write_smt2 -wires check.smt2'

test_sp: testbench_sp.vvp firmware/firmware.hex
	vvp -N testbench_sp.vvp

test_axi: testbench.vvp firmware/firmware.hex
	vvp -N testbench.vvp +axi_test

test_synth: testbench_synth.vvp firmware/firmware.hex
	vvp -N testbench_synth.vvp

testbench.vvp: testbench.v picorv32.v
	iverilog -o testbench.vvp $(subst C,-DCOMPRESSED_ISA,$(COMPRESSED_ISA)) -DRISCV_FORMAL testbench.v picorv32.v
	chmod -x testbench.vvp

testbench_sp.vvp: testbench.v picorv32.v
	iverilog -o testbench_sp.vvp $(subst C,-DCOMPRESSED_ISA,$(COMPRESSED_ISA)) -DRISCV_FORMAL -DSP_TEST testbench.v picorv32.v
	chmod -x testbench_sp.vvp

testbench_synth.vvp: testbench.v synth.v
	iverilog -o testbench_synth.vvp testbench.v synth.v
	chmod -x testbench_synth.vvp

synth.v: picorv32.v scripts/yosys/synth_sim.ys
	yosys -qv3 -l synth.log scripts/yosys/synth_sim.ys

firmware/firmware.hex: firmware/firmware.bin firmware/makehex.py
	python3 firmware/makehex.py $< 16384 > $@

firmware/firmware.bin: firmware/firmware.elf
	$(TOOLCHAIN_PREFIX)objcopy -O binary $< $@
	chmod -x $@

firmware/firmware.elf: $(FIRMWARE_OBJS) $(TEST_OBJS) firmware/sections.lds
	$(TOOLCHAIN_PREFIX)gcc -Os -m32 -ffreestanding -nostdlib -o $@ \
		-Wl,-Bstatic,-T,firmware/sections.lds,-Map,firmware/firmware.map,--strip-debug \
		$(FIRMWARE_OBJS) $(TEST_OBJS) -lgcc
	chmod -x $@

firmware/start.o: firmware/start.S
	$(TOOLCHAIN_PREFIX)gcc -c -m32 -march=RV32IM$(COMPRESSED_ISA)Xcustom -o $@ $<

firmware/%.o: firmware/%.c
	$(TOOLCHAIN_PREFIX)gcc -c -m32 -march=RV32I$(COMPRESSED_ISA) -Os --std=c99 $(GCC_WARNS) -ffreestanding -nostdlib -o $@ $<

tests/%.o: tests/%.S tests/riscv_test.h tests/test_macros.h
	$(TOOLCHAIN_PREFIX)gcc -c -m32 -march=RV32IM -o $@ -DTEST_FUNC_NAME=$(notdir $(basename $<)) \
		-DTEST_FUNC_TXT='"$(notdir $(basename $<))"' -DTEST_FUNC_RET=$(notdir $(basename $<))_ret $<

download-tools:
	sudo bash -c 'set -ex; mkdir -p /var/cache/distfiles; $(foreach URL,$(NEWLIB_URL), \
		if ! test -f /var/cache/distfiles/$(notdir $(URL)); then wget -O /var/cache/distfiles/$(notdir $(URL)).part $(URL); \
			mv /var/cache/distfiles/$(notdir $(URL)).part /var/cache/distfiles/$(notdir $(URL)); fi;) \
	$(foreach REPO,riscv-gnu-toolchain riscv-binutils-gdb riscv-dejagnu riscv-gcc riscv-glibc, \
		if ! test -d /var/cache/distfiles/$(REPO).git; then rm -rf /var/cache/distfiles/$(REPO).git.part; \
			git clone --bare https://github.com/riscv/$(REPO) /var/cache/distfiles/$(REPO).git.part; \
			mv /var/cache/distfiles/$(REPO).git.part /var/cache/distfiles/$(REPO).git; else \
			(cd /var/cache/distfiles/$(REPO).git; git fetch https://github.com/riscv/$(REPO)); fi;)'

define build_tools_template
build-$(1)-tools:
	@read -p "This will remove all existing data from /opt/$(1). Type YES to continue: " reply && [[ "$$$$reply" == [Yy][Ee][Ss] || "$$$$reply" == [Yy] ]]
	sudo bash -c "set -ex; rm -rf /opt/$(1); mkdir -p /opt/$(1); chown $$$${USER}. /opt/$(1)"
	$(MAKE) build-$(1)-tools-bh

build-$(1)-tools-bh:
	+set -ex; \
	if [ -d /var/cache/distfiles/riscv-gnu-toolchain.git ]; then reference_riscv_gnu_toolchain="--reference /var/cache/distfiles/riscv-gnu-toolchain.git"; else reference_riscv_gnu_toolchain=""; fi; \
	if [ -d /var/cache/distfiles/riscv-binutils-gdb.git ]; then reference_riscv_binutils_gdb="--reference /var/cache/distfiles/riscv-binutils-gdb.git"; else reference_riscv_binutils_gdb=""; fi; \
	if [ -d /var/cache/distfiles/riscv-dejagnu.git ]; then reference_riscv_dejagnu="--reference /var/cache/distfiles/riscv-dejagnu.git"; else reference_riscv_dejagnu=""; fi; \
	if [ -d /var/cache/distfiles/riscv-gcc.git ]; then reference_riscv_gcc="--reference /var/cache/distfiles/riscv-gcc.git"; else reference_riscv_gcc=""; fi; \
	if [ -d /var/cache/distfiles/riscv-glibc.git ]; then reference_riscv_glibc="--reference /var/cache/distfiles/riscv-glibc.git"; else reference_riscv_glibc=""; fi; \
	rm -rf riscv-gnu-toolchain-$(1); git clone $$$$reference_riscv_gnu_toolchain https://github.com/riscv/riscv-gnu-toolchain riscv-gnu-toolchain-$(1); \
	cd riscv-gnu-toolchain-$(1); git checkout $(RISCV_GNU_TOOLCHAIN_REV); \
	git submodule update --init $$$$reference_riscv_binutils_gdb riscv-binutils-gdb; \
	git submodule update --init $$$$reference_riscv_dejagnu riscv-dejagnu; \
	git submodule update --init $$$$reference_riscv_gcc riscv-gcc; \
	git submodule update --init $$$$reference_riscv_glibc riscv-glibc; \
	mkdir build; cd build; ../configure --with-arch=$(2) --prefix=/opt/$(1); make

.PHONY: build-$(1)-tools
endef

$(eval $(call build_tools_template,riscv32i,RV32I))
$(eval $(call build_tools_template,riscv32ic,RV32IC))
$(eval $(call build_tools_template,riscv32im,RV32IM))
$(eval $(call build_tools_template,riscv32imc,RV32IMC))

build-tools:
	@echo "This will remove all existing data from /opt/riscv32i, /opt/riscv32ic, /opt/riscv32im, and /opt/riscv32imc."
	@read -p "Type YES to continue: " reply && [[ "$$reply" == [Yy][Ee][Ss] || "$$reply" == [Yy] ]]
	sudo bash -c "set -ex; rm -rf /opt/riscv32{i,ic,im,imc}; mkdir -p /opt/riscv32{i,ic,im,imc}; chown $${USER}. /opt/riscv32{i,ic,im,imc}"
	$(MAKE) build-riscv32i-tools-bh
	$(MAKE) build-riscv32ic-tools-bh
	$(MAKE) build-riscv32im-tools-bh
	$(MAKE) build-riscv32imc-tools-bh

toc:
	gawk '/^-+$$/ { y=tolower(x); gsub("[^a-z0-9]+", "-", y); gsub("-$$", "", y); printf("- [%s](#%s)\n", x, y); } { x=$$0; }' README.md

clean:
	rm -rf riscv-gnu-toolchain-riscv32i riscv-gnu-toolchain-riscv32ic \
		riscv-gnu-toolchain-riscv32im riscv-gnu-toolchain-riscv32imc
	rm -vrf $(FIRMWARE_OBJS) $(TEST_OBJS) check.smt2 check.vcd synth.v synth.log \
		firmware/firmware.elf firmware/firmware.bin firmware/firmware.hex firmware/firmware.map \
		testbench.vvp testbench_sp.vvp testbench_synth.vvp testbench.vcd testbench.trace

.PHONY: test view test_sp test_axi test_synth download-tools build-tools toc clean

