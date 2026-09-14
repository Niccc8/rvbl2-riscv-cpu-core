`timescale 1ns/1ps
// ============================================================================
// tb_dmem.v
//
// NOTE ON A RACE FOUND AND FIXED WHILE WRITING THIS TESTBENCH:
// An earlier version of this file changed we_i/oe_i in the exact same
// simulation timestep as the `@(posedge clk)` edge the DUT's own
// `always @(posedge clk_i)` block samples on (e.g. `@(posedge clk); we=0;`).
// Because both the testbench's resumption after the edge and the DUT's
// clocked block are scheduled for the *same* event, their relative
// evaluation order is a genuine Verilog race, not guaranteed by the
// language. In this simulator it caused an intermittent silently-skipped
// write (confirmed by isolated reproduction). Fixed by always inserting a
// small delay (#1) after any edge before changing a signal that mattered
// for sampling at that edge - exactly the "sample on the opposite edge or
// after a small delay" discipline the architecture spec calls for (§18.5).
// ============================================================================
module tb_dmem;
    reg         clk, rst;
    reg  [31:0] addr, wdata;
    reg         we, oe;
    reg  [3:0]  bw;
    wire [31:0] rdata;
    integer pass, fail;

    // The macro realization is fixed at 4 x 512 words; the behavioral one is
    // free, so a small array is used there to keep the out-of-range checks
    // below reachable inside the 8kB window.
`ifdef DMEM_USE_SRAM_MACRO
    localparam WORDS = 2048;
`else
    localparam WORDS = 32;
`endif
    dmem #(.DMEM_WORDS(WORDS)) dut (
        .clk_i(clk), .rst_i(rst), .address_i(addr), .we_i(we), .oe_i(oe),
        .bw_i(bw), .data_i(wdata), .data_o(rdata)
    );

    always #5 clk = ~clk;

    task check(input [31:0] exp, input [200:0] name);
        begin
            if (rdata === exp) pass = pass + 1;
            else begin fail=fail+1; $display("FAIL %0s: got=%h exp=%h", name, rdata, exp); end
        end
    endtask

    // Perform one write, holding we/bw/addr/data stable across the capturing
    // edge and only changing them safely afterward.
    task do_write(input [31:0] a, input [31:0] d, input [3:0] mask);
        begin
            @(posedge clk); #1;   // land on a safe point, past any previous edge's race window
            addr = a; wdata = d; bw = mask; we = 1; oe = 0;
            @(posedge clk); #1;   // edge that performs the write has now safely passed
            we = 0;
        end
    endtask

    // Perform one registered read; `rdata` is valid once the task returns.
    task do_read(input [31:0] a);
        begin
            @(posedge clk); #1;
            addr = a; oe = 1; we = 0;
            @(posedge clk);       // the memory registers the read at this edge
            // Sample late in the cycle, which is where the core's register file
            // actually samples load data. The behavioral array presents the
            // word immediately at this edge; an OpenRAM macro presents it part
            // way through the following cycle (its model drives dout to x at
            // the edge, then assigns the real word after an internal
            // negedge-plus-delay path). Both are valid by the next edge, so
            // sampling just before it is the point that holds for either.
            #9;
            oe = 0;
        end
    endtask

    initial begin
        clk=0; rst=0; we=0; oe=0; bw=0; addr=0; wdata=0;
        pass=0; fail=0;
        @(posedge clk); #1;

        // full-word write then registered read-back
        do_write(32'h1001_0000, 32'hCAFE_BABE, 4'b1111);
        do_read(32'h1001_0000);
        check(32'hCAFE_BABE, "full-word write then registered read-back");

        // single-byte-lane write must preserve the other 3 bytes
        do_write(32'h1001_0000, 32'h00AA_0000, 4'b0100);
        do_read(32'h1001_0000);
        check(32'hCAAA_BABE, "single-byte-lane write preserves other 3 bytes");

        // write-then-read-back after several idle cycles (true storage, §9.13)
        do_write(32'h1001_0004, 32'h1111_2222, 4'b1111);
        repeat (5) @(posedge clk);
        do_read(32'h1001_0004);
        check(32'h1111_2222, "write survives several idle cycles (true storage)");

        // full byte-lane sweep at a fresh word
        do_write(32'h1001_0008, 32'hFFFF_FFFF, 4'b1111);
        do_write(32'h1001_0008, 32'h0000_00AA, 4'b0001); // lane0
        do_read(32'h1001_0008); check(32'hFFFF_FFAA, "lane0-only write");

        do_write(32'h1001_0008, 32'h0000_BB00, 4'b0010); // lane1
        do_read(32'h1001_0008); check(32'hFFFF_BBAA, "lane1-only write");

        do_write(32'h1001_0008, 32'h00CC_0000, 4'b0100); // lane2
        do_read(32'h1001_0008); check(32'hFFCC_BBAA, "lane2-only write");

        do_write(32'h1001_0008, 32'hDD00_0000, 4'b1000); // lane3
        do_read(32'h1001_0008); check(32'hDDCC_BBAA, "lane3-only write");

        // simultaneous we_i/oe_i (shouldn't happen given FSM scoping, but
        // confirm deterministic write-wins behavior if it ever did, §9.13)
        @(posedge clk); #1;
        addr = 32'h1001_000C; wdata = 32'h5555_5555; bw = 4'b1111; we = 1; oe = 1;
        @(posedge clk); #1; we = 0; oe = 0;
        do_read(32'h1001_000C);
        check(32'h5555_5555, "simultaneous we&oe -> write-wins, deterministic");

        // non-adjacent addresses must store independently
        do_write(32'h1001_0010, 32'hAAAA_BBBB, 4'b1111);
        do_write(32'h1001_0014, 32'hCCCC_DDDD, 4'b1111);
        do_read(32'h1001_0010);
        check(32'hAAAA_BBBB, "non-adjacent address A independent");
        do_read(32'h1001_0014);
        check(32'hCCCC_DDDD, "non-adjacent address B independent");

`ifndef DMEM_USE_SRAM_MACRO
        // Read of a never-written word must be 0. This is a property of the
        // behavioral array's simulation zero-fill only - an OpenRAM macro
        // powers up with undefined contents, exactly like real silicon, so the
        // check does not apply to that realization.
        do_read(32'h1001_0020);
        check(32'h0000_0000, "read of never-written word -> 0");
`endif

        // half-word mask write (lanes 0+1, what SH at offset 0 produces)
        do_write(32'h1001_0018, 32'hFFFF_FFFF, 4'b1111);
        do_write(32'h1001_0018, 32'h0000_5678, 4'b0011);
        do_read(32'h1001_0018);
        check(32'hFFFF_5678, "half-word write lanes 0+1");

        // half-word mask write (lanes 2+3, what SH at offset 2 produces)
        do_write(32'h1001_001C, 32'h0000_0000, 4'b1111);
        do_write(32'h1001_001C, 32'h9ABC_0000, 4'b1100);
        do_read(32'h1001_001C);
        check(32'h9ABC_0000, "half-word write lanes 2+3");

        // last word address in the small test DMEM
        do_write(32'h1001_0000 + (WORDS-1)*4, 32'hDEAD_BEEF, 4'b1111);
        do_read(32'h1001_0000 + (WORDS-1)*4);
        check(32'hDEAD_BEEF, "last word address boundary");

`ifndef DMEM_USE_SRAM_MACRO
        // Addresses inside the architectural 8kB window (Block Guide Table 13)
        // but beyond the instantiated array must read back 0 and write nothing,
        // rather than aliasing into a real word. With WORDS=32 the array covers
        // only 0x10010000-0x1001007F, so 0x10010080 onward is out of range.
        // The macro realization always fills the whole window, so there is no
        // in-window out-of-array address to test there.
        do_write(32'h1001_0000, 32'hA5A5_A5A5, 4'b1111);
        do_write(32'h1001_0080, 32'hDEAD_BEEF, 4'b1111); // one word past the array
        do_read(32'h1001_0000);
        check(32'hA5A5_A5A5, "out-of-range write must not alias into word 0");
        do_read(32'h1001_0080);
        check(32'h0000_0000, "out-of-range read returns 0, not an aliased word");
        do_read(32'h1001_1FFC);                          // top of the 8kB window
        check(32'h0000_0000, "read at top of window, beyond array -> 0");
`endif

        $display("==== tb_dmem: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_DMEM: ALL TESTS PASSED");
        else $display("TB_DMEM: FAILURES PRESENT");
        $finish;
    end
endmodule
