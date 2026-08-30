# RD68011 coding standard

The RTL must elaborate under **iverilog 12.0, Verilator 5.032, yosys 0.52, Vivado 2025.2,
Quartus Prime Lite 25.1 and Questa Altera Starter Edition 2025.2**. That intersection, not
the SystemVerilog LRM, is the language this project is written in.

`make lint` runs the first three, which is why they are the ones the design is written
against day to day. The other three need a vendor installation, so each has its own
target: `make synth` for Vivado, `make lint-quartus` for Quartus, `make lint-questa` for
Questa. None of the three is in `make check`, which has to work on a machine with neither
vendor installed.

Everything below marked *(measured)* was established by trying it on this machine, not
assumed.

## The subset

**yosys is the constraint.** It is markedly stricter than the other three, so it decides
what the RTL may use.

### Forbidden — yosys rejects it *(measured)*

| Construct | What happens |
|---|---|
| `import pkg::*;` in a module header | `ERROR: syntax error, unexpected TOK_ID` |
| `import pkg::*;` in the module body | `ERROR: syntax error, unexpected TOK_PACKAGESEP` |
| `import pkg::name;` | same |

There is no working form of `import`. **Refer to package members with their full scope
every time**: `rd68011_pkg::FC_SUPER_P`, `rd68011_pkg::bus_state_e`. It is verbose; it is
also unambiguous about where a constant came from, which for a design transcribed out of a
manual is worth something.

### Allowed — every tool accepts it *(measured)*

- `package` / `endpackage` with `localparam`, `typedef enum`, `typedef struct packed`
- enum and packed-struct **variables** inside modules, including struct field assignment
  (`r.a <= 4'd1`) and enum comparison
- `always_ff` / `always_comb`, `unique case`, `logic`, `'0` fill
- **Dual-edge design**: a `posedge clk` block and a `negedge clk` block in the same module.
  yosys infers `$_DFF_PN0_` and `$_DFF_NN0_` correctly. This matters — the whole bus-state
  scheme depends on it.
- Asynchronous active-low reset in the sensitivity list
- A **posedge flop and a negedge flop combined with XOR** to make an output that
  changes on both edges (`rd68011_dedge_ff`). Only one side can change at any
  instant, so the result is glitch-free, and every tool infers it correctly.

### Forbidden — project rules rather than tool limits

| Rule | Why |
|---|---|
| No `initial` blocks in `rtl/` | ASIC has no power-on state |
| No initialisers on register declarations | same |
| No `assert property` / SVA in `rtl/` | iverilog and yosys do not support it |
| No interfaces, classes, queues, dynamic arrays, `unions` | not portable |
| No `$random`, `$display` in `rtl/` | not synthesisable |
| No non-constant loop bounds | not synthesisable |
| No user types on module **ports** | keeps yosys and cross-tool elaboration happy; use plain `logic [N:0]` and convert inside |
| No inline `lint_off` pragmas | waivers go in `rtl/rd68011.vlt` with a reason |
| **No function that reads module state, called from a continuous assignment** | see below -- the tools disagree about when it is re-evaluated |

Testbenches under `sim/` are not bound by these: they only ever run under iverilog or
Verilator, and may use `initial`, `$display`, tasks, `realtime` and the rest.

## Reset

Every register is reset. There is no exception and no "don't care" register.

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    q <= '0;          // explicit value for every register in the block
  end else begin
    q <= d;
  end
end
```

`rst_n` is **not** an MC68010 pin. It is the hardware/simulation initialisation input that
gives every flop a defined value; the architectural reset behaviour (RESET+HALT asserted
together, vector fetch from 0 and 4) is a separate sequence driven by `reset_n_i` and
`halt_n_i`. Do not conflate them.

## Naming

| Suffix | Meaning |
|---|---|
| `_n` | active low **at the pin** — `as_n_o == 0` means AS asserted |
| `_i` | input pin |
| `_o` | output pin |
| `_oe` | output enable, **active high = core is driving** |
| `_q` | registered version of a combinational signal, where both exist |
| `_e` | enum type name (`bus_state_e`) |
| `_t` | struct type name |

Modules are `rd68011_<unit>` in `rtl/rd68011_<unit>.sv`, one module per file.
Package members are `UPPER_SNAKE` for constants and `UPPER` for enum values.

## Comments

Cite the source. A line of RTL that implements something from the manual says which page
it came from:

```systemverilog
// UM 3.7: six clocks low, four high. Specification 41 measures the transition
// from CLK low, so this lives in the negative-edge domain.
```

`UM` is `MC68000UM_split`, `PRM` is `M68000PRM_split`. Specification numbers refer to
`ac-electrical-specifications.csv`. This is not decoration: when a behaviour is later
questioned, the citation is what settles it.

## Lint waivers

Two exist, both in `rtl/rd68011.vlt`:

- `UNUSEDPARAM` on `rd68011_pkg.sv` — the package is a catalogue of architectural
  constants and no single module uses all of them.
- `UNUSEDSIGNAL` on the top level's `unused_inputs` sink, which names inputs the design
  does not consume yet so that the list shrinks visibly as the design fills in.

Two file-format gotchas, both hit in practice *(measured)*: `` `verilator_config `` must be
the first token in a `.vlt` file, and **no comment in it may start with the word
"verilator"** — Verilator parses those as directives and reports a syntax error. Waiver
globs are matched against the path as given on the command line, so `*rtl/foo.sv` matches
and `*/rtl/foo.sv` does not.

## The function-in-a-continuous-assignment trap *(measured)*

This one cost real debugging time and no lint run catches it.

```systemverilog
function automatic logic [31:0] src_mux(input logic [3:0] sel);
  case (sel) ... SRC_RDATA: src_mux = read_data; ... endcase   // reads module state
endfunction

assign a_bus = src_mux(f_asrc);      // WRONG
```

**iverilog re-evaluates the function only when its explicit arguments change.**
`read_data` is not an argument, so `a_bus` keeps a stale value when the read data
arrives -- silently, with no warning. Verilator and yosys infer the real
dependency and behave as intended, so lint is clean under all three tools and
only simulation shows the difference.

Write it as `always_comb` instead, whose sensitivity is inferred from everything
the statements read:

```systemverilog
always_comb begin
  case (f_asrc) ... SRC_RDATA: a_bus = read_data; ... endcase
end
```

Three places in this design hit it: the source multiplexers in
`rd68011_seq.sv`, `after_cycle` in `rd68011_biu.sv`, and `pick_reg` -- the
register-selection function called from `assign wreg_index = ...`. All are now
plain `always_comb`. A function whose result depends only on its arguments is
still fine anywhere.

`pick_reg` is worth a note, because it was latent rather than failing: its
result depended on `ir` and on the addressing-mode fields as well as on its
argument, so it went stale only when the opcode changed while `wsel` did not --
which never happened until MOVEM, whose loop writes a different register on
every pass without the microword changing. The rule is not "convert functions
that are currently wrong"; it is "do not call a function that reads module
state from a continuous assignment at all", because whether the bug is visible
depends on which combinations the design happens to exercise.

## Known tool quirks *(measured)*

| Tool | Quirk | Workaround |
|---|---|---|
| iverilog | `always_comb` that reads nothing warns "process has no sensitivities" | drive constants with `assign` |
| iverilog | declarations inside an unnamed `begin`/`end` are a syntax error | declare at module scope |
| Verilator | `-Wall` flags every unused package parameter | the `.vlt` waiver above |
| yosys | no `import` in any form | fully-scoped references |
| Vivado | needs the package file read before its users | `synth.tcl` sorts `rd68011_pkg.sv` first |
| Vivado | a signal used before its declaration is only `[Synth 8-6901]`, an *info* | `synth.tcl` and `impl.tcl` promote it to an error; Questa rejects the same thing natively, and it is how the one instance in this design was found |
| Quartus | on MAX 10, an inferred ROM stays in logic with no warning unless the image carries its contents | `set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"`; the microcode store was 23,696 logic elements and 0 memory bits without it and 62 with |
| Vivado | the ROM mapping in its own synthesis report is **preliminary**, and timing optimisation may reverse it afterwards with no message. Building the core with `LOOP_BUF_WORDS=16` was enough: the report still said Block RAM, the netlist had none, and the microcode store came back as 1900 extra LUTs | say which memory and stop it being a choice: `(* rom_style = "block" *)` on the store's output register. `make impl LOOPBUF=16` measures both ways |
| Quartus | `ramstyle` is recognised on an inferred ROM; `rom_style` is not (`Warning (10335)`) | carry both attributes -- each tool honours its own, ignores the other, and this one warns about it once |
| Quartus | `small` is a reserved word in its SystemVerilog | do not name a module or signal that |
| iverilog | assigning a ternary of two enum values to an enum variable is "This assignment requires an explicit cast" | use `if`/`else` inside the case item |
| iverilog | `unique`/`unique0` on a case are parsed but ignored, with a "sorry" note per occurrence | harmless; keep them for the other five |
| iverilog | adjacent string literals do not concatenate (`"a" "b"` is a syntax error) | write one string |
| Quartus | a package-scoped constant inside a module instantiation's **port expression** is not resolved: it becomes an implicit one-bit net named after the constant, `Warning (10236)`, and the netlist quietly stops matching the source | hoist the expression into a named signal and connect that; see below |
| Quartus | an ordered `casez` -- first match wins -- is built as a priority chain and not flattened. 1401 patterns became 498 logic levels and 4.67 MHz where Vivado and yosys flatten the same source | emit disjoint patterns instead; `tools/ucode/assemble.py` resolves the order once, in Python, and proves the two tables equivalent over all 65536 opcodes |
| Questa | a variable read above its own declaration is `(vlog-2730) Undefined variable`, then `(vlog-2388) already declared in this scope` at the declaration | declare before first use; iverilog and Verilator invent an implicit net instead |
| all of them | a testbench that samples `retire` just after the rising edge misses the end of a bus-cycle microword, because the bus unit's output stage is negedge-clocked and the acknowledge only settles in the second half of the clock | sample instruction boundaries on the *falling* edge, as `rd68011_core_harness.svh` does |

Add to this table whenever a tool surprises you. It is cheaper than rediscovering it.

### The Quartus one, in full *(measured)*

It is the only quirk in the table whose failure mode is a **wrong netlist rather than an
error**, so it gets the reproduction written out. Seven lines, on Quartus Prime Lite
25.1, `10M50DAF484C7G`:

```systemverilog
package p; localparam int K = 3; endpackage
module sub (input logic [3:0] a, output logic [3:0] y); assign y = a; endmodule
module minitop (input logic [7:0] w, output logic [3:0] y1, output logic [3:0] y2);
  logic [3:0] hoisted;
  assign hoisted = w[p::K +: 4];
  sub u1 (.a (w[p::K +: 4]), .y (y1));   // Warning (10236): implicit net for "K"
  sub u2 (.a (hoisted),      .y (y2));   // clean
endmodule
```

`quartus_map` returns 0 either way. `quartus_syn`, the newer engine that might handle it,
refuses to run: "The Quartus Prime Pro Edition Design Software must be installed."

It cost this design nine sites in `rtl/rd68011_seq.sv` -- the multiplier's two `f_alu`
comparisons, the divider's and shifter's `` `UF(uw, …) `` field selects, and `SR_X` on the
shifter's and ALU's `x_in`. All of them are now `assign`ed to a named signal above the
instance. That is why `make lint-quartus` greps for `Implicit Net warning` and fails on
it: the exit code would not have caught any of them.

