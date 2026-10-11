// ============================================================================
// tb_top.v - the DE10-Lite top level (lanex_de10lite): the reset path. With the
// PLL stand-in (altpll_stub.v), the 50 MHz pin drives the core clock directly.
//   * at power-up the board leaves reset once the PLL is locked;
//   * a KEY0 glitch shorter than 20 ms does not reset the board;
//   * KEY0 held 20 ms resets it, and releasing KEY0 lets it run again;
//   * the board's outputs come up driven (no X) after reset.
// Self-checking: prints "TOP PASS" or "TOP FAIL <reason>".
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_top;
    reg        clk = 1'b0;
    always #16 clk = ~clk;                     // the core clock (31.25 MHz) through the stub
    reg  [1:0] key = 2'b11;                    // KEY1, KEY0: high = released
    reg  [9:0] sw = 10'd0;
    wire [9:0] ledr;
    wire [7:0] h0, h1, h2, h3, h4, h5;
    wire [35:0] gpio;
    pullup p0 (gpio[0]);                        // the FPGA's weak pull-ups (lanex.qsf)
    pullup p2 (gpio[2]);

    lanex_de10lite dut (.MAX10_CLK1_50(clk), .KEY(key), .SW(sw), .LEDR(ledr),
                        .HEX0(h0), .HEX1(h1), .HEX2(h2), .HEX3(h3), .HEX4(h4), .HEX5(h5), .GPIO(gpio));

    localparam integer MS = 31250;             // clocks per ms
    integer fails = 0;
    task automatic must(input cond, input [8*48-1:0] what);
        if (!cond) begin $display("TOP FAIL %0s", what); fails = fails + 1; end
    endtask

    initial begin
        repeat (100) @(posedge clk);
        must(dut.rst == 1'b0, "the board did not leave reset after power-up");
        repeat (2 * MS) @(posedge clk);
        must(^ledr !== 1'bx && ^{h5, h4, h3, h2, h1, h0} !== 1'bx, "outputs undriven after reset");
        // a 1 ms glitch on KEY0: no reset
        key[0] = 1'b0; repeat (MS) @(posedge clk); key[0] = 1'b1;
        repeat (100) @(posedge clk);
        must(dut.rst == 1'b0, "a 1 ms KEY0 glitch reset the board");
        // 15 ms: still no reset
        key[0] = 1'b0; repeat (15 * MS) @(posedge clk);
        must(dut.rst == 1'b0, "KEY0 reset the board within 15 ms");
        // held on to 25 ms: reset
        repeat (10 * MS) @(posedge clk);
        must(dut.rst == 1'b1, "KEY0 held 25 ms did not reset the board");
        key[0] = 1'b1; repeat (100) @(posedge clk);
        must(dut.rst == 1'b0, "the board stayed in reset after KEY0 was released");
        repeat (2 * MS) @(posedge clk);
        must(dut.u_board.mode == 2'd0 && dut.u_board.bphase == 2'd0, "no cold boot (lamp test) after KEY0");
        must(ledr == 10'h3FF, "the lamp test is not on after KEY0");
        if (fails == 0) $display("TOP PASS");
        $finish;
    end
endmodule

`default_nettype wire
