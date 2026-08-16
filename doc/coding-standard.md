# RD68011 coding standard

The RTL must elaborate under **iverilog 12.0, Verilator 5.032, yosys 0.52 and Vivado
2025.2**. That intersection, not the SystemVerilog LRM, is the language this project is
written in. `make lint` runs the first three; `make synth` runs the fourth.

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

### Allowed — all four tools accept it *(measured)*

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
  instant, so the result is glitch-free, and all four tools infer it correctly.

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
| iverilog | assigning a ternary of two enum values to an enum variable is "This assignment requires an explicit cast" | use `if`/`else` inside the case item |
| iverilog | `unique`/`unique0` on a case are parsed but ignored, with a "sorry" note per occurrence | harmless; keep them for the other three tools |
| iverilog | adjacent string literals do not concatenate (`"a" "b"` is a syntax error) | write one string |
| all four | a testbench that samples `retire` just after the rising edge misses the end of a bus-cycle microword, because the bus unit's output stage is negedge-clocked and the acknowledge only settles in the second half of the clock | sample instruction boundaries on the *falling* edge, as `rd68011_core_harness.svh` does |

Add to this table whenever a tool surprises you. It is cheaper than rediscovering it.
