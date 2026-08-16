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

.PHONY: all lint lint-iverilog lint-verilator lint-yosys synth sim check clean dirs \
        ucode ucode-check model-check harte harte-all

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
# Vivado synthesis. Slow, so it is not part of `check`.
# ---------------------------------------------------------------------------
synth: dirs
	@echo "== vivado $(XTOP) on $(XPART) =="
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(BUILD) && vivado -mode batch -nojournal -nolog \
	    -source ../scripts/synth.tcl -tclargs $(XPART) $(XTOP) $(CURDIR)

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
# Simulation. Each testbench is sim/tb/<name>_tb.sv and runs to completion,
# printing "PASS" or "FAIL"; a FAIL anywhere fails the target.
# ---------------------------------------------------------------------------
# harte_tb needs a +vec argument, so it is not part of the plain sim sweep.
TBS    := $(filter-out sim/tb/harte_tb.sv,$(wildcard sim/tb/*_tb.sv))
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

check: ucode-check lint sim
	@echo "check: ok"

clean:
	rm -rf $(BUILD)
