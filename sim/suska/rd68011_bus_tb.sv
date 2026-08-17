// The transaction list of this design, for comparison with Suska's.
//
// The other half of the cross-check sim/suska/wf68k10_tb.vhd starts: the same
// image, the same format, one line per bus cycle. doc/suska-crosscheck.md says
// what the comparison is and is not good for.

`timescale 1ns/1ps

module rd68011_bus_tb;

`include "rd68011_core_harness.svh"

  string image;
  int    limit;
  int    n;
  int    seen;

  initial begin
    errors = 0;
    if (!$value$plusargs("image=%s", image)) image = "bus_probe.hex";
    if (!$value$plusargs("cycles=%d", limit)) limit = 60;

    core_reset();
    mem.clear();
    $readmemh(image, mem.mem);
    core_start();

    // The harness records every cycle as it starts; all this has to do is wait
    // for enough of them and then print what was recorded.
    n = 0;
    while ((ntr < limit) && (n < 40000)) begin
      @(posedge clk);
      n = n + 1;
    end

    seen = (ntr < limit) ? ntr : limit;
    for (int i = 0; i < seen; i = i + 1) begin
      $display("CYCLE %06h %0d %b%b%b %b%b",
               {tr_addr[i], 1'b0}, tr_rw[i],
               tr_fc[i][2], tr_fc[i][1], tr_fc[i][0], 1'b0, 1'b0);
    end
    $display("CYCLE END");
    $display("PASS: rd68011_bus_tb");
    $finish;
  end

endmodule
