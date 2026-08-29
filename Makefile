# RD68011 - SystemVerilog MC68010
#
#   make ucode   regenerate rtl/gen/ from tools/ucode/, and build/ucode.lst
#   make lint    elaborate the RTL under iverilog, Verilator and yosys
#   make synth   Vivado synthesis + timing report (slow)
#   make sim     directed testbenches under iverilog
#   make check   everything except synth
#   make model-check   the prefetch model against the reference vectors (slow)
#
# See CLAUDE.md for the project rules and doc/coding-standard.md for the
# SystemVerilog subset all of these tools have to agree on.

TOP      := rd68011_top
# The synthesis and area numbers that mean anything during bring-up come from
# the unit under construction, not from the pin-level top, whose tied-off
# sequencer interface lets the tools optimise most of the design away.
XTOP     ?= rd68011_top

# Packages first: every tool needs them read before their users. The generated
# files under rtl/gen/ come from tools/ucode/ and are checked in, so a build
# does not need Python -- `make ucode` regenerates them.
RTL_PKG  := rtl/rd68011_pkg.sv rtl/gen/rd68011_ucode_pkg.sv
RTL_GEN  := $(filter-out rtl/gen/rd68011_ucode_pkg.sv,$(wildcard rtl/gen/*.sv))
RTL_SRC  := $(filter-out rtl/rd68011_pkg.sv,$(wildcard rtl/*.sv))
RTL      := $(RTL_PKG) $(RTL_GEN) $(RTL_SRC)
VLT_CFG  := rtl/rd68011.vlt

BUILD    := build
SCRATCH  ?= $(BUILD)

IVFLAGS  := -g2012 -Wall -Wno-timescale
VLFLAGS  := --lint-only -Wall
YOSYS    := yosys

# Vivado: a part with room for the core plus a testbench harness.
XPART    ?= xc7a100tcsg324-1

# Quartus: the largest MAX 10, which is the largest part the Lite edition
# supports that this core fits in. `make quartus` reports against it.
AFAMILY  ?= MAX 10
APART    ?= 10M50DAF484C7G
# How many cores the fitter may take. Quartus warns when this is not said, and
# the default is all of them.
AJOBS    ?= 8
# The Fmax `make quartus` must still reach. A floor measured here, not a target:
# doc/implementation.md has the number and what moved it. It was 4.26 MHz until
# the decode table stopped being a priority chain, and 18.50 until the microcode
# store became a memory and the address unit stopped reading the ALU's opcode --
# doc/size-and-speed.md, where 18.48 on one of the candidates is what the floor
# caught.
AFMAX    ?= 19.50

.PHONY: suska-ssw suska-fault suska-rte all lint lint-iverilog lint-verilator lint-yosys synth sim check clean dirs \
        lint-questa lint-quartus quartus \
        ucode ucode-check model-check harte harte-all \
        audit impl programs suska cosim \
        timing timing-events timing-check timing-duty timing-setup \
        xsim-smoke xsim-timing xsim-setup

all: lint

dirs:
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# Microcode. Regenerates rtl/gen/ from tools/ucode/ and writes build/ucode.lst,
# which is the microcode listing worth reading alongside the RTL.
# ---------------------------------------------------------------------------
ucode: dirs
	@python3 tools/ucode/assemble.py

ucode-check: dirs
	@python3 tools/ucode/assemble.py --check

# ---------------------------------------------------------------------------
# The prefetch model, checked against the SingleStepTests reference vectors.
# Not part of `check`: it reads 69 MB of vectors and takes a minute.
# ---------------------------------------------------------------------------
model-check:
	@python3 tools/harte/model_check.py

# ---------------------------------------------------------------------------
# Lint / elaboration
# ---------------------------------------------------------------------------
lint: lint-iverilog lint-verilator lint-yosys
	@echo "lint: all tools clean"

# ---------------------------------------------------------------------------
# The reset audit -- CLAUDE.md's hard rule, checked rather than assumed.
#
# ASIC is a target, so there is no power-on register state. The source side of
# this is quick; the netlist side synthesises the whole design to gate-level
# flops and reads back their types, because a flop without a reset is a
# different cell there and cannot hide.
# ---------------------------------------------------------------------------
audit:
	@echo "== reset audit =="
	@YOSYS=$(YOSYS) python3 tools/reset_audit.py $(RTL)

lint-iverilog: dirs
	@echo "== iverilog =="
	@iverilog $(IVFLAGS) -o $(BUILD)/$(TOP).vvp -s $(TOP) $(RTL)

lint-verilator:
	@echo "== verilator =="
	@verilator $(VLFLAGS) --top-module $(TOP) $(VLT_CFG) $(RTL)

# yosys is the strictest of the three on SystemVerilog, so it is the one that
# defines the subset. Full synth, not just read_verilog, so that anything
# unsynthesisable is caught here rather than in Vivado.
lint-yosys: dirs
	@echo "== yosys =="
	@$(YOSYS) -q -p "read_verilog -sv $(RTL); \
	                 hierarchy -check -top $(TOP); \
	                 synth -top $(TOP); \
	                 write_verilog -noattr $(BUILD)/$(TOP)_yosys.v"
	@$(YOSYS) -q -p "read_verilog -sv $(RTL); \
	                 hierarchy -check -top $(XTOP); \
	                 synth -top $(XTOP); \
	                 stat"

# ---------------------------------------------------------------------------
# Two more front-ends, from the Altera installation.
#
# Neither is part of `lint` or `check`, for the reason `synth` is not: they need
# a vendor installation that a machine checking this project out will not
# necessarily have. What they add is independence -- Questa and Quartus share no
# parser with iverilog, Verilator, yosys or Vivado, and between them they found
# both of the defects doc/coding-standard.md now records.
#
# Point QUESTA_ROOTDIR or QUARTUS_ROOTDIR at another installation to use it.
#
# Questa compiles and elaborates only. vsim wants a node-locked licence file
# that this machine does not have, so nothing here simulates under it.
# ---------------------------------------------------------------------------
QUESTA_ROOTDIR  ?= /opt/Altera/questa_fse
QUARTUS_ROOTDIR ?= /opt/Altera/quartus

QUESTA  = QUESTA_ROOTDIR=$(QUESTA_ROOTDIR) $(CURDIR)/scripts/questa.sh
QUARTUS = QUARTUS_ROOTDIR=$(QUARTUS_ROOTDIR) $(CURDIR)/scripts/altera.sh

QUESTADIR  := $(BUILD)/questa
QUARTUSDIR := $(BUILD)/quartus

lint-questa: dirs
	@echo "== questa =="
	@rm -rf $(QUESTADIR) && mkdir -p $(QUESTADIR)
	@cd $(QUESTADIR) && $(QUESTA) vlib work > vlib.log 2>&1
	@cd $(QUESTADIR) && $(QUESTA) vlog -sv -lint -work work \
	    $(addprefix $(CURDIR)/,$(RTL)) > vlog.log 2>&1 || \
	    { grep -E '^\*\* (Error|Warning)' vlog.log; \
	      echo "lint-questa: vlog failed, see $(QUESTADIR)/vlog.log"; exit 1; }
	@grep -qE '^\*\* (Error|Warning)' $(QUESTADIR)/vlog.log && \
	    { grep -E '^\*\* (Error|Warning)' $(QUESTADIR)/vlog.log; \
	      echo "lint-questa: not clean"; exit 1; } || true
	@cd $(QUESTADIR) && $(QUESTA) vopt -work work $(TOP) -o $(TOP)_opt \
	    > vopt.log 2>&1 || \
	    { grep -E '^\*\* (Error|Warning)' vopt.log; \
	      echo "lint-questa: vopt failed, see $(QUESTADIR)/vopt.log"; exit 1; }
	@echo "lint-questa: compiled and elaborated clean"

# Analysis and synthesis only -- the front-end, not the fit.
#
# quartus_map returns 0 on the one thing that matters most here, so the grep is
# the gate and not the exit code: a package-scoped constant inside an
# instantiation's port expression becomes an implicit one-bit net and a
# Warning (10236), which is a netlist that quietly stops matching the source.
# doc/coding-standard.md has the reproduction.
lint-quartus: dirs
	@echo "== quartus $(APART) =="
	@rm -rf $(QUARTUSDIR) && mkdir -p $(QUARTUSDIR)
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(QUARTUSDIR) && $(QUARTUS) quartus_sh -t $(CURDIR)/scripts/quartus.tcl \
	    "$(AFAMILY)" $(APART) $(XTOP) $(CURDIR) map $(AJOBS) > map.log 2>&1 || \
	    { grep -E '^(RD68011|Error)' map.log; \
	      echo "lint-quartus: failed, see $(QUARTUSDIR)/map.log"; exit 1; }
	@grep -E '^Error' $(QUARTUSDIR)/map.log && \
	    { echo "lint-quartus: errors above"; exit 1; } || true
	@grep -E 'Implicit Net warning' $(QUARTUSDIR)/map.log && \
	    { echo "lint-quartus: an implicit net is a mis-parse, not a style point"; \
	      exit 1; } || true
	@grep -E '^RD68011' $(QUARTUSDIR)/map.log

# The fit, for a second post-route frequency on an architecture that shares
# nothing with the Artix-7. Slow -- tens of minutes -- so it is not in `check`,
# exactly as `impl` is not.
quartus: dirs
	@echo "== quartus place and route: $(XTOP) on $(APART) =="
	@rm -rf $(QUARTUSDIR) && mkdir -p $(QUARTUSDIR)
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(QUARTUSDIR) && $(QUARTUS) quartus_sh -t $(CURDIR)/scripts/quartus.tcl \
	    "$(AFAMILY)" $(APART) $(XTOP) $(CURDIR) fit $(AJOBS) > fit.log 2>&1 || \
	    { grep -E '^(RD68011|Error)' fit.log; \
	      echo "quartus: failed, see $(QUARTUSDIR)/fit.log"; exit 1; }
	@grep -E 'Implicit Net warning' $(QUARTUSDIR)/fit.log && \
	    { echo "quartus: an implicit net is a mis-parse, not a style point"; \
	      exit 1; } || true
	@cd $(QUARTUSDIR) && $(QUARTUS) quartus_sta -t $(CURDIR)/scripts/quartus_sta.tcl \
	    > sta.log 2>&1 || \
	    { grep -E '^(RD68011|Error)' sta.log; \
	      echo "quartus: timing analysis failed, see $(QUARTUSDIR)/sta.log"; exit 1; }
	@grep -E '^RD68011' $(QUARTUSDIR)/fit.log $(QUARTUSDIR)/sta.log | sed 's|^.*RD68011|RD68011|'
	@python3 tools/quartus_report.py $(QUARTUSDIR)/rd68011.fit.rpt \
	    $(QUARTUSDIR)/fmax.rpt $(AFMAX)

# ---------------------------------------------------------------------------
# Vivado synthesis. Slow, so it is not part of `check`.
#
# Vivado is not on a login shell's PATH; scripts/vivado.sh sources its settings
# script when it needs to, so this works from a plain shell. Point
# VIVADO_SETTINGS at another installation to use that one.
# ---------------------------------------------------------------------------
VIVADO_SETTINGS ?= /opt/Xilinx/2025.2/Vivado/settings64.sh

synth: dirs
	@echo "== vivado $(XTOP) on $(XPART) =="
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(BUILD) && VIVADO_SETTINGS=$(VIVADO_SETTINGS) \
	    $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source ../scripts/synth.tcl -tclargs $(XPART) $(XTOP) $(CURDIR)

# Place and route, for the number that means something: two thirds of the
# critical path is routing, and before placement that part is an estimate.
# Slower than synthesis, and not part of `check`.
impl: dirs
	@echo "== vivado place and route: $(XTOP) on $(XPART) =="
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(BUILD) && VIVADO_SETTINGS=$(VIVADO_SETTINGS) \
	    $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source ../scripts/impl.tcl -tclargs $(XPART) $(XTOP) $(CURDIR)

# What actually limits the frequency. `make impl` reports the worst path static
# timing analysis can find, which for this design is one the microcode cannot
# take; this reports what is left when the unreachable routes are excluded, and
# groups the rest into families. Runs on the checkpoint `make impl` left behind,
# so it costs a minute. doc/critical-path.md is written from it.
paths: dirs
	@echo "== vivado: what limits $(XTOP) =="
	@cd $(BUILD) && VIVADO_SETTINGS=$(VIVADO_SETTINGS) \
	    $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source ../scripts/paths.tcl -tclargs $(CURDIR) > paths.log 2>&1 || \
	    { grep -E '^(RD68011-PATHS|ERROR)' paths.log; \
	      echo "paths: vivado failed, see $(BUILD)/paths.log"; exit 1; }
	@grep -E '^RD68011-PATHS' $(BUILD)/paths.log
	@python3 tools/timing/paths.py $(BUILD)/paths_activatable.rpt

# ---------------------------------------------------------------------------
# Reference vectors. `make harte OP=NOP` runs one opcode file; N limits how
# many of its ~2500 tests are run, which is what you want while developing.
# ---------------------------------------------------------------------------
OP ?= NOP
N  ?= 200

VECDIR := $(BUILD)/vectors

# A sweep across every opcode file the ISA covers so far, for a regression
# rather than a single-opcode debug loop.
HARTE_OPS ?= NOP MOVE.q MOVE.b MOVE.w MOVE.l MOVEA.w MOVEA.l Bcc \
             TST.b TST.w TST.l CLR.b CLR.w CLR.l NEG.b NEG.w NEG.l \
             NEGX.b NEGX.w NEGX.l NOT.b NOT.w NOT.l \
             ADD.b ADD.w ADD.l SUB.b SUB.w SUB.l \
             AND.b AND.w AND.l OR.b OR.w OR.l EOR.b EOR.w EOR.l \
             CMP.b CMP.w CMP.l ADDA.w ADDA.l SUBA.w SUBA.l CMPA.w CMPA.l \
             EXT.w EXT.l SWAP LEA PEA Scc TAS \
             BTST BCHG BCLR BSET \
             ASL.b ASL.w ASL.l ASR.b ASR.w ASR.l \
             LSL.b LSL.w LSL.l LSR.b LSR.w LSR.l \
             ROL.b ROL.w ROL.l ROR.b ROR.w ROR.l \
             ROXL.b ROXL.w ROXL.l ROXR.b ROXR.w ROXR.l \
             BSR DBcc JMP JSR RTS RTR LINK UNLINK \
             MOVEfromSR MOVEtoSR MOVEtoCCR \
             ANDItoCCR ANDItoSR ORItoCCR ORItoSR EORItoCCR EORItoSR \
             MOVEfromUSP MOVEtoUSP RESET STOP CHK TRAPV RTE \
             MULU MULS DIVU DIVS ABCD SBCD NBCD \
             ADDX.b ADDX.w ADDX.l SUBX.b SUBX.w SUBX.l \
             EXG MOVEP.w MOVEP.l MOVEM.w MOVEM.l

harte-all: dirs
	@fail=0; for op in $(HARTE_OPS); do \
	  out=$$($(MAKE) --no-print-directory harte OP=$$op N=$(N) 2>&1 | \
	         grep -E 'passed|skipped:|address errors'); \
	  printf '%-10s %s\n' "$$op" "$$out"; \
	  case "$$out" in *" 0 failed"*) ;; *) fail=1;; esac; \
	done; exit $$fail

harte: dirs
	@mkdir -p $(VECDIR)
	@test -f $(VECDIR)/$(OP).$(N).hex || \
	    python3 tools/harte/export.py $(OP) $(N) > $(VECDIR)/$(OP).$(N).hex
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/harte_tb.vvp -s harte_tb \
	    $(RTL) $(MODELS) sim/tb/harte_tb.sv 2>&1 | grep -v 'sorry:' || true
	@vvp $(BUILD)/harte_tb.vvp +vec=$(VECDIR)/$(OP).$(N).hex

# ---------------------------------------------------------------------------
# Test programs: real code, built with the m68k toolchain and run on the core.
#
# Each is a flat image -- the vector table at zero and everything after it,
# which is what an MC68010 sees after reset -- and each is self-checking: it
# writes a mark to a fixed address when it passes and the number of the check
# that failed when it does not. sim/tb/core_program_tb.sv has the contract.
# ---------------------------------------------------------------------------
PROGDIR  := $(BUILD)/programs
PROGSRC  := $(wildcard sim/programs/p*.S) $(wildcard sim/programs/p*.c)
PROGS    := $(basename $(notdir $(PROGSRC)))
MCFLAGS  := -m68010 -Wall -Wextra -Os -fomit-frame-pointer -nostdlib \
            -ffreestanding -fno-builtin -Isim/programs
# No libgcc: there is no 68010 multilib, so the only one available is built
# for a 68020 and contains instructions this part does not have. The handful
# of helpers a C program needs are in sim/programs/libmc68010.S instead.

$(PROGDIR)/%.hex: sim/programs/%.S sim/programs/rd68011.inc sim/programs/link.ld
	@mkdir -p $(PROGDIR)
	@m68k-linux-gnu-gcc $(MCFLAGS) -c -x assembler-with-cpp -o $(PROGDIR)/$*.o $<
	@m68k-linux-gnu-ld -T sim/programs/link.ld -o $(PROGDIR)/$*.elf \
	    $(PROGDIR)/$*.o 2>&1 | grep -v 'RWX permissions' || true
	@m68k-linux-gnu-objcopy -O binary $(PROGDIR)/$*.elf $(PROGDIR)/$*.bin
	@python3 tools/bin2hex.py $(PROGDIR)/$*.bin > $@

$(PROGDIR)/%.hex: sim/programs/%.c sim/programs/crt0.S sim/programs/libmc68010.S \
                  sim/programs/link.ld
	@mkdir -p $(PROGDIR)
	@m68k-linux-gnu-gcc $(MCFLAGS) -c -x assembler-with-cpp \
	    -o $(PROGDIR)/crt0.o sim/programs/crt0.S
	@m68k-linux-gnu-gcc $(MCFLAGS) -c -x assembler-with-cpp \
	    -o $(PROGDIR)/libmc68010.o sim/programs/libmc68010.S
	@m68k-linux-gnu-gcc $(MCFLAGS) -c -o $(PROGDIR)/$*.o $<
	@m68k-linux-gnu-ld -T sim/programs/link.ld -o $(PROGDIR)/$*.elf \
	    $(PROGDIR)/crt0.o $(PROGDIR)/$*.o $(PROGDIR)/libmc68010.o 2>&1 | \
	    grep -v 'RWX permissions' || true
	@m68k-linux-gnu-objcopy -O binary $(PROGDIR)/$*.elf $(PROGDIR)/$*.bin
	@python3 tools/bin2hex.py $(PROGDIR)/$*.bin > $@

PROGHEX := $(addprefix $(PROGDIR)/,$(addsuffix .hex,$(PROGS)))

# Memory latency for the program runs. Zero is what everything ran at until a
# report from a real machine pointed out that a saturated bus can hold a cycle
# off for a dozen clocks or more. `make programs WAITS=13` is the check.
WAITS ?= 0

programs: dirs $(PROGHEX)
	@echo "== test programs (waits=$(WAITS)) =="
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/program_tb.vvp \
	    -s core_program_tb $(RTL) $(MODELS) sim/tb/core_program_tb.sv 2>&1 | \
	    grep -v 'sorry:' || true
	@fail=0; for p in $(PROGHEX); do \
	  a=sim/programs/$$(basename $$p .hex).args; \
	  extra=$$(test -f $$a && cat $$a || true); \
	  out=$$(vvp $(BUILD)/program_tb.vvp +prog=$$p +timeout=2000000 \
	         +waits=$(WAITS) $$extra 2>&1 | \
	         grep -v 'sorry:'); \
	  echo "$$out"; \
	  case "$$out" in *"PASS"*) ;; *) fail=1;; esac; \
	done; exit $$fail

# ---------------------------------------------------------------------------
# Cross-check against the Suska WF68K10, under ghdl.
#
# CLAUDE.md is explicit about what Inputs/Suska_Configware/ is for: it may be
# run to validate testbenches, and it may never be read to work out how to
# write our RTL. This is the running. Nothing in rtl/ or in the testbenches was
# written from its source; its entity declaration is what an instantiation
# needs and is all that was looked at.
#
# What it is good for, and what it is not, is in doc/suska-crosscheck.md. Not
# part of `check`: it is a diagnostic, and its answer is a paragraph rather than
# a pass or a fail.
# ---------------------------------------------------------------------------
SUSKADIR  := $(BUILD)/suska
SUSKASRC  := Inputs/Suska_Configware/68K10
GHDLFLAGS := --std=08 -fsynopsys -fexplicit -frelaxed --work=wf68k10 --workdir=.
SUSKAUNIT := wf68k10_pkg wf68k10_address_registers wf68k10_alu \
             wf68k10_bus_interface wf68k10_control wf68k10_data_registers \
             wf68k10_exception_handler wf68k10_opcode_decoder wf68k10_top

# One program, built once, for both the transaction cross-check and the
# AC-timing measurement. Neither should get its own copy: the whole value of
# running two processors is that they ran the same thing.
$(SUSKADIR)/bus_probe.hex: sim/suska/bus_probe.S sim/suska/probe.ld | dirs
	@mkdir -p $(SUSKADIR)
	@m68k-linux-gnu-gcc -m68010 -c -x assembler-with-cpp \
	    -o $(SUSKADIR)/bus_probe.o sim/suska/bus_probe.S
	@m68k-linux-gnu-ld -T sim/suska/probe.ld -o $(SUSKADIR)/bus_probe.elf \
	    $(SUSKADIR)/bus_probe.o 2>&1 | grep -v 'RWX permissions' || true
	@m68k-linux-gnu-objcopy -O binary $(SUSKADIR)/bus_probe.elf \
	    $(SUSKADIR)/bus_probe.bin
	@python3 tools/bin2hex.py $(SUSKADIR)/bus_probe.bin > $@

# The special status word of a faulted bus cycle, on both processors.
#
# sim/programs/p06_ssw.S is self-checking and runs on RD68011 through
# `make programs`; this runs the identical image on the Suska core and reads
# its answers out of memory. Two implementations disagreed about the first of
# its cases, so the point is to have the answer from something other than the
# one being questioned. doc/ssw.md has what the manual says and what each
# produced.
suska-ssw: dirs $(PROGDIR)/p06_ssw.hex
	@echo "== special status word: RD68011 =="
	@vvp $(BUILD)/program_tb.vvp +prog=$(PROGDIR)/p06_ssw.hex \
	    +timeout=2000000 +berr=4194304 2>&1 | grep -vi 'sorry:'
	@echo "== special status word: Suska WF68K10 =="
	@mkdir -p $(SUSKADIR)
	@cp $(PROGDIR)/p06_ssw.hex $(SUSKADIR)/
	@cd $(SUSKADIR) && for u in $(SUSKAUNIT); do \
	    ghdl -a $(GHDLFLAGS) $(CURDIR)/$(SUSKASRC)/$$u.vhd 2>&1 | \
	    grep -ci error >/dev/null || true; done
	@cd $(SUSKADIR) && ghdl -a $(GHDLFLAGS) \
	    $(CURDIR)/sim/suska/wf68k10_ssw_tb.vhd 2>&1 | grep -i '^.*error' || true
	@cd $(SUSKADIR) && ghdl -e $(GHDLFLAGS) wf68k10_ssw_tb 2>/dev/null; \
	    ghdl -r $(GHDLFLAGS) wf68k10_ssw_tb --stop-time=20ms 2>&1 | \
	    grep -o 'SSW suska: .*'

# Instruction continuation on the Suska core: does RTE come back from a format
# $$8 frame? sim/programs/p03_fault.S completes a faulted access in software and
# returns through RTE, which is UM 6.3.9.2's alternative to rerunning the cycle
# and the MC68010's reason for existing. It passes on RD68011 via `make
# programs`. doc/ssw.md records what each core does.
$(SUSKADIR)/rte_probe.hex: sim/suska/rte_probe.S sim/programs/rd68011.inc \
                           sim/programs/link.ld | dirs
	@mkdir -p $(SUSKADIR)
	@m68k-linux-gnu-gcc $(MCFLAGS) -c -x assembler-with-cpp \
	    -o $(SUSKADIR)/rte_probe.o $<
	@m68k-linux-gnu-ld -T sim/programs/link.ld -o $(SUSKADIR)/rte_probe.elf \
	    $(SUSKADIR)/rte_probe.o 2>&1 | grep -v 'RWX permissions' || true
	@m68k-linux-gnu-objcopy -O binary $(SUSKADIR)/rte_probe.elf \
	    $(SUSKADIR)/rte_probe.bin
	@python3 tools/bin2hex.py $(SUSKADIR)/rte_probe.bin > $@

# Which half of instruction continuation is missing. p03_fault asks two
# questions at once -- does RTE accept a format $8 frame, and does it honour
# the rerun flag -- and a core that fails the second looks exactly like a core
# that fails the first, because the fault window never goes away and the rerun
# loops. This arms the fault one at a time so the two can be told apart.
# Inputs/suska-rte-fix.md is what it was written to establish.
suska-rte: dirs $(SUSKADIR)/rte_probe.hex
	@echo "== which half of instruction continuation: Suska WF68K10 =="
	@cd $(SUSKADIR) && for u in $(SUSKAUNIT); do \
	    ghdl -a $(GHDLFLAGS) $(CURDIR)/$(SUSKASRC)/$$u.vhd >/dev/null 2>&1 || true; done
	@cd $(SUSKADIR) && ghdl -a $(GHDLFLAGS) \
	    $(CURDIR)/sim/suska/wf68k10_rte_probe_tb.vhd 2>&1 | grep -i '^.*error' || true
	@cd $(SUSKADIR) && ghdl -e $(GHDLFLAGS) wf68k10_rte_probe_tb 2>/dev/null; \
	    ghdl -r $(GHDLFLAGS) wf68k10_rte_probe_tb --stop-time=40ms 2>&1 | \
	    grep -o 'PROBE suska: .*'

suska-fault: dirs $(PROGDIR)/p03_fault.hex
	@echo "== instruction continuation: RD68011 =="
	@vvp $(BUILD)/program_tb.vvp +prog=$(PROGDIR)/p03_fault.hex \
	    +timeout=2000000 +berr=4096 2>&1 | grep -vi 'sorry:'
	@echo "== instruction continuation: Suska WF68K10 =="
	@mkdir -p $(SUSKADIR)
	@cp $(PROGDIR)/p03_fault.hex $(SUSKADIR)/
	@cd $(SUSKADIR) && for u in $(SUSKAUNIT); do \
	    ghdl -a $(GHDLFLAGS) $(CURDIR)/$(SUSKASRC)/$$u.vhd >/dev/null 2>&1 || true; done
	@cd $(SUSKADIR) && ghdl -a $(GHDLFLAGS) \
	    $(CURDIR)/sim/suska/wf68k10_p03_tb.vhd 2>&1 | grep -i '^.*error' || true
	@cd $(SUSKADIR) && ghdl -e $(GHDLFLAGS) wf68k10_p03_tb 2>/dev/null; \
	    ghdl -r $(GHDLFLAGS) wf68k10_p03_tb --stop-time=40ms 2>&1 | \
	    grep -o 'P03 suska: .*'

suska: dirs $(SUSKADIR)/bus_probe.hex
	@echo "== suska cross-check =="
	@cd $(SUSKADIR) && for u in $(SUSKAUNIT); do \
	    ghdl -a $(GHDLFLAGS) $(CURDIR)/$(SUSKASRC)/$$u.vhd 2>&1 | \
	    grep -i error || true; done
	@cd $(SUSKADIR) && ghdl -a $(GHDLFLAGS) $(CURDIR)/sim/suska/wf68k10_tb.vhd \
	    2>&1 | grep -i error || true
	@cd $(SUSKADIR) && ghdl -e $(GHDLFLAGS) wf68k10_tb 2>/dev/null; \
	    ghdl -r $(GHDLFLAGS) wf68k10_tb --stop-time=2ms 2>&1 | \
	    grep -o 'CYCLE .*' > suska.txt
	@iverilog $(IVFLAGS) -I sim/tb -o $(SUSKADIR)/rd68011_bus_tb.vvp \
	    -s rd68011_bus_tb $(RTL) $(MODELS) sim/suska/rd68011_bus_tb.sv 2>&1 | \
	    grep -v 'sorry:' || true
	@cd $(SUSKADIR) && vvp rd68011_bus_tb.vvp +image=bus_probe.hex \
	    +timeout=2000000 +cycles=400 2>&1 | grep -o 'CYCLE .*' > ours.txt
	@python3 tools/suska/compare.py $(SUSKADIR)/ours.txt $(SUSKADIR)/suska.txt

# ---------------------------------------------------------------------------
# Co-simulation against Musashi.
#
# Musashi is an instruction-set simulator: no bus cycles, no prefetch pipe, no
# cycle counts, so it says nothing about the half of this project that is bus
# behaviour. What it is, is an independent implementation of the other half,
# written by somebody else from the same manuals -- so running a real program
# through both and comparing every register after every instruction asks a
# question no single-instruction vector can.
#
# Its own m68kconf.h is not used: Inputs/ is immutable, and three switches have
# to move. tools/cosim/m68kconf.h is the copy with those three changed, forced
# ahead of the original with -include, because Musashi includes its own with
# quotes and that searches its own directory first.
#
# Programs with an .args file are left out: those need faults injected from
# outside the processor, which an ISS with no bus has no way to reproduce.
# ---------------------------------------------------------------------------
COSIMDIR  := $(BUILD)/cosim
MUSASHI   := Inputs/ref/Musashi
COSIMPROG := $(foreach p,$(PROGS),\
               $(if $(wildcard sim/programs/$(p).args),,$(p)))

$(COSIMDIR)/musashi_trace: tools/cosim/musashi_trace.c tools/cosim/m68kconf.h
	@mkdir -p $(COSIMDIR)
	@gcc -O1 -w -o $(COSIMDIR)/m68kmake $(MUSASHI)/m68kmake.c
	@cd $(COSIMDIR) && ./m68kmake . $(CURDIR)/$(MUSASHI)/m68k_in.c >/dev/null
	@gcc -O2 -w -include $(CURDIR)/tools/cosim/m68kconf.h \
	    -I $(MUSASHI) -I $(COSIMDIR) -o $@ \
	    tools/cosim/musashi_trace.c $(MUSASHI)/m68kcpu.c \
	    $(MUSASHI)/m68kdasm.c $(MUSASHI)/softfloat/softfloat.c \
	    $(COSIMDIR)/m68kops.c -lm

cosim: programs $(COSIMDIR)/musashi_trace
	@echo "== musashi co-simulation =="
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/program_tb.vvp \
	    -s core_program_tb $(RTL) $(MODELS) sim/tb/core_program_tb.sv 2>&1 | \
	    grep -v 'sorry:' || true
	@fail=0; for p in $(COSIMPROG); do \
	  vvp $(BUILD)/program_tb.vvp +prog=$(PROGDIR)/$$p.hex +waits=$(WAITS) \
	      +timeout=6000000 +trace=$(COSIMDIR)/$$p.rtl >/dev/null 2>&1; \
	  $(COSIMDIR)/musashi_trace $(PROGDIR)/$$p.hex 4000000 \
	      > $(COSIMDIR)/$$p.ref; \
	  printf '%-12s ' "$$p"; \
	  python3 tools/cosim/compare.py $(COSIMDIR)/$$p.rtl \
	      $(COSIMDIR)/$$p.ref || fail=1; \
	done; exit $$fail

# ---------------------------------------------------------------------------
# Simulation. Each testbench is sim/tb/<name>_tb.sv and runs to completion,
# printing "PASS" or "FAIL"; a FAIL anywhere fails the target.
# ---------------------------------------------------------------------------
# harte_tb needs a +vec argument, so it is not part of the plain sim sweep.
TBS    := $(filter-out sim/tb/harte_tb.sv sim/tb/core_program_tb.sv,\
                       $(wildcard sim/tb/*_tb.sv))
MODELS := $(wildcard sim/models/*.sv)

sim: dirs
	@echo "== iverilog testbenches =="
	@set -e; fail=0; \
	for tb in $(TBS); do \
	  name=$$(basename $$tb .sv); \
	  iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/$$name.vvp -s $$name $(RTL) $(MODELS) $$tb; \
	  out=$$(vvp $(BUILD)/$$name.vvp); \
	  echo "$$out"; \
	  case "$$out" in *FAIL*) fail=1;; esac; \
	  case "$$out" in *PASS*) ;; *) echo "$$name: no PASS reported"; fail=1;; esac; \
	done; \
	exit $$fail

# ---------------------------------------------------------------------------
# AC-timing conformance.
#
# Every other bus testbench here asks whether the design does what UM section 5
# *draws* -- AS at the rising edge entering S2, and so on. These ask whether it
# does what section 10 *requires*, which is a looser and quite different
# question, and one the S0-S7 ruler cannot express because the limits are in
# nanoseconds against clock edges rather than in bus states.
#
# One measurement run per speed grade, because the design places its events in
# half-clocks and so every spacing scales with the period: an 8 MHz recording is
# evidence about 8 MHz and nothing else. doc/ac-timing.md has the results.
# ---------------------------------------------------------------------------
TIMDIR     := $(BUILD)/timing
TIMPERIODS := 125 100 80 60 50
TIMMODELS  := sim/models/rd68011_pads.sv sim/models/rd68011_slave_ac.sv
TIMINC     := -I sim/tb -I sim/tb/timing
TIMCYCLES  ?= 30
PADSKEW    ?= 0

timing-events: dirs $(SUSKADIR)/bus_probe.hex
	@echo "== AC timing: measuring =="
	@mkdir -p $(TIMDIR)
	@cp $(SUSKADIR)/bus_probe.hex $(TIMDIR)/
	@iverilog $(IVFLAGS) $(TIMINC) -o $(TIMDIR)/ac.vvp -s rd68011_ac_tb \
	    $(RTL) $(TIMMODELS) sim/tb/timing/rd68011_ac_tb.sv 2>&1 | \
	    grep -v 'sorry:' || true
	@cd $(TIMDIR) && for p in $(TIMPERIODS); do \
	    vvp ac.vvp +image=bus_probe.hex +period=$$p \
	        +cycles=$(TIMCYCLES) > ours-$$p.events 2>&1; done
	@echo "   $(words $(TIMPERIODS)) logs in $(TIMDIR)"

timing-check: timing-events
	@echo "== AC timing: one delay per pin (the conservative reading) =="
	@python3 tools/timing/analyse.py --brief --pad-skew $(PADSKEW) \
	    $(TIMDIR)/ours-*.events
	@echo
	@echo "== AC timing: transition delays independent (the loosest reading) =="
	@python3 tools/timing/analyse.py --brief $(TIMDIR)/ours-*.events

# Specifications 1 and 2/3 together permit a duty cycle of 44 to 56 per cent at
# 8 MHz. One bus state sits in each half period here, so a skewed clock moves
# half of them -- and it costs margin at both ends, on specification 11 when the
# high half is long and on specification 14 when it is short. No other testbench
# can express this, because they all index by half-clock tick and a tick is not
# a fixed length when the clock is asymmetric.
timing-duty: timing-events
	@echo "== AC timing: the duty cycle across its legal range at 8 MHz =="
	@cd $(TIMDIR) && for hi in 55 62.5 70; do \
	    vvp ac.vvp +image=bus_probe.hex +period=125 +clk_hi=$$hi \
	        +cycles=$(TIMCYCLES) > duty-$$hi.events 2>&1; done
	@for hi in 55 62.5 70; do \
	    echo "-- clk_hi=$$hi"; \
	    python3 tools/timing/analyse.py --brief --pad-skew $(PADSKEW) \
	        $(TIMDIR)/duty-$$hi.events | tail -1; \
	    python3 tools/timing/analyse.py --pad-skew $(PADSKEW) \
	        $(TIMDIR)/duty-$$hi.events | grep 'address may lag'; done

# The class-3 limits -- 27, 28, 29, 47 -- are demands on the memory system, so
# `make timing` measures them and cannot judge them: what the slave happened to
# do says nothing about what the processor requires. This finds out what it
# requires, by moving one input later on each run until the behaviour changes.
# Black-box throughout, so the identical measurement runs against the other core.
timing-setup: dirs $(SUSKADIR)/bus_probe.hex
	@echo "== AC timing: where the processor samples its inputs =="
	@mkdir -p $(TIMDIR)
	@cp $(SUSKADIR)/bus_probe.hex $(TIMDIR)/
	@iverilog $(IVFLAGS) $(TIMINC) -o $(TIMDIR)/setup.vvp -s rd68011_setup_tb \
	    $(RTL) $(TIMMODELS) sim/tb/timing/rd68011_setup_tb.sv 2>&1 | \
	    grep -v 'sorry:' || true
	@cd $(TIMDIR) && for p in $(TIMPERIODS); do \
	    vvp setup.vvp +image=bus_probe.hex +period=$$p \
	        +timeout=20000000 2>&1 | \
	        grep -E '^(#|MEASURE|PASS|FAIL)' > ours-$$p.setup; done
	@python3 tools/timing/setup_report.py \
	    $(addprefix $(TIMDIR)/ours-,$(addsuffix .setup,$(TIMPERIODS)))

timing: timing-check timing-duty timing-setup

# --- Vivado xsim ------------------------------------------------------------
#
# The gate everything above the line depends on: our SystemVerilog and the
# Suska VHDL elaborated together, so one testbench can drive either processor.
# Kept out of `check` because it needs a Vivado installation.
#
# The xvhdl output is reduced to error counts and message codes on purpose.
# CLAUDE.md permits Inputs/Suska_Configware/ to be run and not to be read;
# a compiler's diagnostics quote the source it is compiling, so they are counted
# rather than printed or kept.
XSIMDIR := $(BUILD)/xsim
XVHDL    = $(CURDIR)/scripts/xilinx.sh xvhdl
XVLOG    = $(CURDIR)/scripts/xilinx.sh xvlog
XELAB    = $(CURDIR)/scripts/xilinx.sh xelab
XSIM     = $(CURDIR)/scripts/xilinx.sh xsim

$(XSIMDIR)/.libs: $(RTL) sim/tb/timing/wf68k10_pins.vhd | dirs
	@mkdir -p $(XSIMDIR)
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(XSIMDIR)/rtl.f
	@cd $(XSIMDIR) && for u in $(SUSKAUNIT); do \
	    n=$$($(XVHDL) -2008 -work wf68k10 $(CURDIR)/$(SUSKASRC)/$$u.vhd 2>&1 | \
	         grep -c '^ERROR' || true); \
	    if [ "$$n" != "0" ]; then echo "xvhdl: $$u: $$n error(s)"; exit 1; fi; \
	  done
	@cd $(XSIMDIR) && $(XVHDL) -2008 -work xil_defaultlib -L wf68k10 \
	    $(CURDIR)/sim/tb/timing/wf68k10_pins.vhd 2>&1 | grep '^ERROR' && exit 1 || true
	@cd $(XSIMDIR) && $(XVLOG) -sv -f rtl.f 2>&1 | grep '^ERROR' && exit 1 || true
	@touch $@

xsim-smoke: $(XSIMDIR)/.libs
	@echo "== xsim: does SystemVerilog bind to VHDL for these two designs? =="
	@cd $(XSIMDIR) && $(XVLOG) -sv $(CURDIR)/sim/tb/timing/xsim_smoke_tb.sv \
	    2>&1 | grep '^ERROR' && exit 1 || true
	@cd $(XSIMDIR) && $(XELAB) -timescale 1ns/1ps -mt off -L wf68k10 \
	    -L xil_defaultlib xsim_smoke_tb -s smoke_snap 2>&1 | \
	    grep -E '^ERROR' && exit 1 || true
	@cd $(XSIMDIR) && $(XSIM) smoke_snap -R 2>&1 | grep -E 'SMOKE|PASS|FAIL'

xsim-timing: $(XSIMDIR)/.libs $(SUSKADIR)/bus_probe.hex timing-events
	@echo "== AC timing: the Suska core, on the same instrument =="
	@cp $(SUSKADIR)/bus_probe.hex $(XSIMDIR)/
	@cd $(XSIMDIR) && $(XVLOG) -sv $(CURDIR)/sim/models/rd68011_pads.sv \
	    $(CURDIR)/sim/models/rd68011_slave_ac.sv \
	    -i $(CURDIR)/sim/tb/timing \
	    $(CURDIR)/sim/tb/timing/wf68k10_ac_tb.sv 2>&1 | \
	    grep '^ERROR' && exit 1 || true
	@cd $(XSIMDIR) && $(XELAB) -timescale 1ns/1ps -mt off -L wf68k10 \
	    -L xil_defaultlib wf68k10_ac_tb -s suska_ac 2>&1 | \
	    grep -E '^ERROR' && exit 1 || true
	@cd $(XSIMDIR) && for p in $(TIMPERIODS); do \
	    $(XSIM) suska_ac -R -testplusarg "image=bus_probe.hex" \
	        -testplusarg "period=$$p" -testplusarg "cycles=20" 2>&1 | \
	    grep -E '^(# design|EV|BUS|CLK|GLITCH)' > suska-$$p.events; done
	@echo
	@# Reports rather than fails. That the other core cannot meet
	@# specification 14 at 8 MHz is a finding about it, not a fault in this
	@# design, and `make timing-check` is where our own verdict is a gate.
	@python3 tools/timing/analyse.py --brief --pad-skew $(PADSKEW) \
	    $(TIMDIR)/ours-*.events $(XSIMDIR)/suska-*.events || true

# The same input-sampling measurement, against the other core. This is the
# comparison doc/suska-crosscheck.md had concluded was impossible: the S0-S7
# ruler cannot be shared, but "how many nanoseconds after AS does it look at
# DTACK" can be asked of anything.
xsim-setup: $(XSIMDIR)/.libs $(SUSKADIR)/bus_probe.hex timing-setup
	@echo "== AC timing: where the Suska core samples its inputs =="
	@cp $(SUSKADIR)/bus_probe.hex $(XSIMDIR)/
	@cd $(XSIMDIR) && $(XVLOG) -sv $(CURDIR)/sim/models/rd68011_pads.sv \
	    $(CURDIR)/sim/models/rd68011_slave_ac.sv \
	    -i $(CURDIR)/sim/tb/timing \
	    $(CURDIR)/sim/tb/timing/wf68k10_setup_tb.sv 2>&1 | \
	    grep '^ERROR' && exit 1 || true
	@cd $(XSIMDIR) && $(XELAB) -timescale 1ns/1ps -mt off -L wf68k10 \
	    -L xil_defaultlib wf68k10_setup_tb -s suska_setup 2>&1 | \
	    grep -E '^ERROR' && exit 1 || true
	@cd $(XSIMDIR) && $(XSIM) suska_setup -R \
	    -testplusarg "image=bus_probe.hex" -testplusarg "period=125" \
	    -testplusarg "timeout=20000000" 2>&1 | \
	    grep -E '^(# design|# golden|MEASURE|PASS|FAIL)' > suska.setup
	@python3 tools/timing/setup_report.py $(TIMDIR)/ours-125.setup \
	    $(XSIMDIR)/suska.setup || true

check: ucode-check lint audit sim programs timing-check timing-setup
	@echo "check: ok"

clean:
	rm -rf $(BUILD)
