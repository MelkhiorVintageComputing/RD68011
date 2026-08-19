# WF68K10: RTE from a format $8 frame always takes a format error

Files touched: `wf68k10_exception_handler.vhd`, `wf68k10_top.vhd`.
Baseline: the WF68K10 with `suska-ssw-fix.patch` applied (the special-status-word
fix reported separately). This patch applies on top of that one.
Tested with ghdl `--std=08 -fsynopsys -fexplicit -frelaxed`, `WF68K10_TOP` with
`VERSION => x"20210815"`, `NO_PIPELINE=false`, `NO_LOOP=false`,
`NO_INDEXSCALING=true`.


## Symptom

Take a bus error, then `RTE` from the format $8 frame the handler was entered
with. Instead of returning, the processor takes a **format error** — exception
vector 14, vector offset $038.

The frame itself is fine: format word `8008`, the right fault address, and with
`suska-ssw-fix.patch` applied the right special status word. Nothing the handler
does provokes it; an `RTE` straight back from an untouched frame does it too.

The practical effect is that *no* bus-error or address-error handler can ever
return on this core. Both of the MC68010's documented recovery paths — rerun the
cycle (UM 6.3.9.1) and complete the access in software (UM 6.3.9.2) — end in
`RTE` from a format $8 frame.


## Cause

`EX_STATE = EXAMINE_VERSION` reads the core's own version stamp back out of the
frame and compares it against the `VERSION` generic, and takes a format error on
a mismatch (`wf68k10_exception_handler.vhd`, process `PENDING`):

```vhdl
when EXAMINE_VERSION =>
    ...
    elsif DATA_RDY = '1' then
        if DATA_IN /= VERSION then
            NEXT_EX_STATE <= IDLE; -- Format error.
```

**The stamp is written at one frame offset and read back from another.**

* `wf68k10_top.vhd`, the `DATA_EXH` multiplexer, puts `VERSION` on the stack at
  `STACK_POS = 14`. With the 29-word format $8 frame stacked as one word at
  offset $38 followed by long words on the 4-byte grid, `STACK_POS = n` is frame
  offset `2n - 4`, so `STACK_POS = 14` is **offset $18** and the long covers
  $18..$1B.

* `wf68k10_exception_handler.vhd`, the `ADR_OFFSET` multiplexer, reads a long for
  `EXAMINE_VERSION` at **offset $1A**, covering $1A..$1D.

They overlap by one word, so the comparison is between `VERSION` and
`VERSION(15 downto 0) & <the word at $1C>`. It can never match.

Instrumenting the baseline core with a `report` in `EXAMINE_VERSION` shows it
directly — the frame at $18 holds `2021 0815`, the read at $1A returns
`0815 0000`:

```
DBG VALIDATE_FRAME  DATA_IN=00008008  next=examine_version
DBG EXAMINE_VERSION DATA_IN=08150000  VERSION=20210815      <- mismatch
```

and a dump of the frame the baseline core builds (frame base $7FBE) confirms the
write position:

```
 +00 2700   status register
 +02 0000 \
 +04 0828 /  program counter
 +06 8008   format $8, vector offset $008
 +08 1105   special status word
 +0A 0000 \
 +0C 2000 /  fault address $00002000
 +0E 0000   unused, reserved
 +10 0000   data output buffer
 +12 2000   unused, reserved
 +14 4279   data input buffer
 +16 6600   unused, reserved
 +18 2021 <- VERSION(31 downto 16), on top of the instruction input buffer
 +1A 0815 <- VERSION(15 downto 0)
 +1C 0000    ... and this is where EXAMINE_VERSION's long read ends
```

So: **the format nibble is not the problem and RR is not the problem.**
`VALIDATE_FRAME` accepts `x"8"` quite happily and routes to `EXAMINE_VERSION`;
the frame is rejected one state later by a self-consistency check that can never
succeed.


## The fix

Two lines. The stamp moves to frame offset $1C and the read follows it there.

```
-                VERSION when STACK_POS = 14 else            
+                VERSION when STACK_POS = 16 else -- Offset $1C ...
```
```
-                  x"0000001A" when NEXT_EX_STATE = EXAMINE_VERSION else
+                  x"0000001C" when NEXT_EX_STATE = EXAMINE_VERSION else -- ...
```

Moving the *stamp* rather than only the *read* matters, because offset $18 is not
a free word. UM figure 6-8 defines it as the **instruction input buffer**, and
UM 6.3.9.2 lists the instruction input buffer image as one of the four fields a
handler writes when it completes a faulted access in software. A handler doing
exactly what the manual describes would overwrite half the version stamp and get
a format error out of `RTE`. Reading the stamp at $18 would have fixed today's
symptom and left that trap in place.

Offset $1C is inside the frame's "internal information, 16 words" ($1A..$39),
which is implementation-defined, so nothing documented is displaced. `STACK_POS =
16` previously fell through to the `(others => '0')` default, and `STACK_POS =
14` now falls through to it, so the instruction input buffer image is written as
zero — inert, and no longer load-bearing. The comparison stays a full 32-bit
compare against the `VERSION` generic, so the check keeps doing what it was for:
rejecting a frame built by a differently-parameterised WF68K10.

One consequence worth knowing: `READ_BOTTOM` reads a long at $1E, which now
overlaps the low half of the stamp. That is harmless — `READ_BOTTOM` discards
`DATA_IN` and only looks at `DATA_VALID`, i.e. it is a bus-error probe, not a
read.

Two alternatives were considered and rejected:

* **Read at $18.** One line, but leaves the stamp on the instruction input
  buffer image as above.
* **Put the stamp at $1A**, where figure 6-8 draws the version number on the real
  part. The stacking grid only produces long writes at frame offsets $00, $04 …
  $34 plus a word at $38, so $1A is not reachable without either splitting the
  stamp across two writes or narrowing it to the low half of the $18 long. The
  latter would undo the deliberate widening of `VERSION` to 32 bits recorded in
  the file's own change log.


## What this does *not* fix: RR is not implemented

With the patch, `RTE` returns from a format $8 frame. It does not honour the
rerun flag.

Walking `EXAMINE_VERSION` onwards, the states are `READ_BOTTOM` ($1E, discarded),
`RESTORE_PC` ($02), `RESTORE_STATUS` ($00), then `SP += $3A` and refill the pipe.
Nothing ever reads the special status word at $08, the data output buffer at $10
or the data input buffer at $14. RR, IF and DF are not decoded on the way back
in, and the frame's internal-information words carry no saved instruction state
to restore (WF68K10 writes them as zeros and debug stamps). The core simply
resumes at the stacked PC, which for a bus or address error is the PC of the
faulted instruction — `PC_INC` is not asserted for `EX_BERR`/`EX_AERR` — so the
whole instruction re-executes.

For a single-access instruction against memory that has since been made
available, re-executing the instruction is indistinguishable from the MC68010's
processor rerun, so the ordinary demand-paging path (RR left clear) works. It is
not the same thing in general: the MC68010 reruns the faulted *bus cycle* and
continues the suspended instruction, so effects already committed — address
register post-increment/pre-decrement, the transfers a MOVEM has already done,
the read half of a read-modify-write — are not repeated. Re-execution repeats
them. And UM 6.3.9.2's software-completion path does not work at all: the
processor redoes the access the handler said it had already performed.

Making that work is a microarchitectural feature, not a patch. It would need the
core to save enough instruction state into the internal-information words to
resume mid-instruction, and on `RTE` to decode RR/IF/DF/HB/BY and take the
operand from the data input buffer or instruction input buffer image instead of
from the bus.

This is why `p03_fault` still does not pass (below): its fault window is
permanent by design, so a rerun of the faulted address faults again, for ever.


## Reproducing and verifying

Build the baseline (pristine sources plus the SSW fix), then apply this patch:

```sh
mkdir -p /tmp/suska-rte-src && cp Inputs/Suska_Configware/68K10/*.vhd /tmp/suska-rte-src/
cd /tmp/suska-rte-src
patch -p1 < .../Inputs/suska-ssw-fix.patch
patch -p1 < .../build/suska-rte/suska-rte-fix.patch
```

Analyse and run, for a testbench `TB` and its image in the working directory:

```sh
G="--std=08 -fsynopsys -fexplicit -frelaxed --work=wf68k10 --workdir=."
for u in wf68k10_pkg wf68k10_address_registers wf68k10_alu wf68k10_bus_interface \
         wf68k10_control wf68k10_data_registers wf68k10_exception_handler \
         wf68k10_opcode_decoder wf68k10_top; do ghdl -a $G /tmp/suska-rte-src/$u.vhd; done
ghdl -a $G <TB>.vhd && ghdl -e $G <TB> && ghdl -r $G <TB> --stop-time=70ms
```

### `rte_probe` — the discriminator

`p03_fault` cannot tell "the frame was rejected" from "the frame was accepted and
RR was ignored": both end the run. `rte_probe.S` and `wf68k10_rte_probe_tb.vhd`
in this directory separate them. The testbench arms **one** fault at a time — a
CPU write to $2200 arms it, the next access to $2000 gets BERR and disarms it —
so a rerun of the faulted access succeeds and the return path can be measured on
its own.

* check 1 — a faulted read, RR left clear, must come back with the memory value
* check 2 — a faulted write, RR left clear, must land in memory
* check 3 — RR set and `$C0DE` placed in the data input buffer image; records
  what the instruction actually received and never fails, because it exists to
  report

```
### baseline (SSW fix only)
PROBE suska: result 00008038  (600d600d is a pass; ...)      <- format error, vector 14
PROBE suska: progress 00000001
PROBE suska: check 3 saw 0000   (c0de = RR honoured, 1234 = the cycle was rerun)

### with suska-rte-fix.patch
PROBE suska: result 600d600d  (600d600d is a pass; ...)      <- checks 1 and 2 pass
PROBE suska: progress 00000003
PROBE suska: check 3 saw 1234   (c0de = RR honoured, 1234 = the cycle was rerun)
```

Checks 1 and 2 pass: `RTE` accepts the format $8 frame, restores SR and PC and
carries on. Check 3 saw `1234`, the value in memory, not the `$C0DE` the handler
supplied: the cycle was rerun, RR was ignored.

The frame the patched core builds, same dump as above (base $7FBE, taken on
check 3, so RR is set in the special status word and the handler has filled in
the data input buffer image):

```
 +08 9105   special status word, RR set by the handler
 +14 c0de   data input buffer image, supplied by the handler
 +18 0000 <- instruction input buffer image, no longer the version stamp
 +1A 0000
 +1C 2021 \
 +1E 0815 /  the version stamp, inside the internal information
```

### `p03_fault` — still fails, and now for the right reason

```
### baseline (SSW fix only)
P03 suska: result 00008038      progress 00000001      <- format error, vector 14
### with suska-rte-fix.patch
P03 suska: the program never finished
P03 suska: progress 00000001
```

Check 1 is a read of an address that always faults, handled by setting RR and
supplying the data. With the patch the `RTE` returns, the core reruns the access
because it does not implement RR, the access faults again, and the program loops.
The format error is gone; the missing feature is not. For reference the same
program passes all six checks on a core that does implement instruction
continuation:

```
== instruction continuation: RD68011 ==
  build/programs/p03_fault.hex: 6 checks in 10227 clocks
PASS
```

### `p06_ssw` — unchanged, still passing

Run `sim/suska/wf68k10_ssw_tb.vhd` against `p06_ssw.hex`. Byte-for-byte identical
before and after this patch, so the special-status-word fix is not regressed:

```
SSW suska: result 600d600d  (600d600d is a pass; ...)
SSW suska: faults taken 0008
SSW suska: ssw[0] = 0005    ssw[4] = 2106
SSW suska: ssw[1] = 1105    ssw[5] = 0001
SSW suska: ssw[2] = 0605    ssw[6] = 2102
SSW suska: ssw[3] = 0205    ssw[7] = 1f05
```

### Bus trace — identical

The 400-cycle trace, `sim/suska/wf68k10_tb.vhd` with `bus_probe.hex`,
`--stop-time=2ms`:

```
401 lines before, 401 lines after, diff empty
```

Captured here as `bus-trace-before.txt` and `bus-trace-after.txt`. This is
expected: the patch changes one word of a format $8 frame's payload and one read
address inside `RTE`, and `bus_probe` provokes neither.


## Files in this directory

| File | What |
|---|---|
| `suska-rte-fix.patch` | the fix, `patch -p1` against the SSW-patched `68K10/` |
| `rte_probe.S` | the discriminator program (diagnostic; not part of the RD68011 suite) |
| `rte_probe.hex` | ... built for the testbench |
| `wf68k10_rte_probe_tb.vhd` | its testbench, derived from `sim/suska/wf68k10_p03_tb.vhd` with a one-shot fault window |
| `bus-trace-before.txt`, `bus-trace-after.txt` | the 400-cycle regression trace |
