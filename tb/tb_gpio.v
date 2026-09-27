`timescale 1ns/1ps
// ============================================================================
// tb_gpio.v - unit tests for gpio.v (spec §10.1, U1-U4).
//
//   U1 reset values, read-back, reserved bits, read-only DATAIN, offset 0xC,
//      full decode (no aliasing into other slots or offsets), read chain
//   U2 byte lanes: a register bit is written only when its byte lane is
//      enabled; misaligned stores (bw = 0000) write nothing
//   U3 direction: gpio_oe/gpio_o follow DATADIR/DATAOUT from the write edge,
//      and a pin never drives while its DATADIR bit is 0
//   U4 DATAIN: 2-cycle synchroniser latency, output-mode pins read 0
//
// Two instances: the 8-pin configuration the SoC uses, and a 32-pin one that
// exercises byte lanes 1-3.
// ============================================================================
module tb_gpio;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  [31:0] addr = 0, wdata = 0, chain_in = 0;
    reg  [3:0]  bw = 0;
    reg         we8 = 0, we32 = 0;
    reg  [7:0]  pins8_i = 0;
    reg  [31:0] pins32_i = 0;
    wire [31:0] rd8, rd32;
    wire [7:0]  o8, oe8;
    wire [31:0] o32, oe32;

    gpio #(.SLOT(4'd0), .N_PINS(8)) dut (
        .clk_i(clk), .rst_i(rst), .bus_addr_i(addr), .bus_wdata_i(wdata),
        .bus_we_i(we8), .bus_bw_i(bw), .bus_rdata_i(chain_in), .bus_rdata_o(rd8),
        .gpio_o(o8), .gpio_oe(oe8), .gpio_i(pins8_i)
    );

    gpio #(.SLOT(4'd0), .N_PINS(32)) dut32 (
        .clk_i(clk), .rst_i(rst), .bus_addr_i(addr), .bus_wdata_i(wdata),
        .bus_we_i(we32), .bus_bw_i(bw), .bus_rdata_i(32'b0), .bus_rdata_o(rd32),
        .gpio_o(o32), .gpio_oe(oe32), .gpio_i(pins32_i)
    );

    localparam [31:0] BASE = 32'hF000_0000;
    localparam [31:0] DATAOUT = BASE + 32'h0, DATAIN = BASE + 32'h4, DATADIR = BASE + 32'h8;

    integer pass = 0, fail = 0, i;
    reg [31:0] v;

    task check(input [31:0] got, input [31:0] exp, input [8*72-1:0] name);
        begin
            if (got === exp) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL %0s: got %h expected %h", name, got, exp);
            end
        end
    endtask

    // One-cycle write strobe, as the core's we_o gives.
    task wr8(input [31:0] a, input [31:0] d, input [3:0] b);
        begin
            @(negedge clk); addr = a; wdata = d; bw = b; we8 = 1;
            @(negedge clk); we8 = 0; bw = 0;
        end
    endtask
    task wr32(input [31:0] a, input [31:0] d, input [3:0] b);
        begin
            @(negedge clk); addr = a; wdata = d; bw = b; we32 = 1;
            @(negedge clk); we32 = 0; bw = 0;
        end
    endtask
    // Reads are combinational and side-effect free.
    task rd(input [31:0] a, output [31:0] d);
        begin addr = a; #1; d = rd8; end
    endtask

    initial begin
        repeat (3) @(posedge clk); #1 rst = 0;

        // ---------------- U1: reset values and read-back ---------------------
        rd(DATAOUT, v); check(v, 0, "U1 DATAOUT resets to 0");
        rd(DATADIR, v); check(v, 0, "U1 DATADIR resets to 0 (all inputs)");
        check({o8, oe8}, 0, "U1 no pin driven out of reset");
        wr8(DATAOUT, 32'hFFFF_FFA5, 4'b1111); rd(DATAOUT, v); check(v, 32'h0000_00A5, "U1 DATAOUT read-back, reserved bits read 0");
        wr8(DATADIR, 32'h1234_563C, 4'b1111); rd(DATADIR, v); check(v, 32'h0000_003C, "U1 DATADIR read-back, reserved bits read 0");
        wr8(DATAIN, 32'hFFFF_FFFF, 4'b1111);
        rd(DATAOUT, v); check(v, 32'hA5, "U1 write to read-only DATAIN leaves DATAOUT");
        rd(DATADIR, v); check(v, 32'h3C, "U1 write to read-only DATAIN leaves DATADIR");
        rd(BASE + 32'hC, v); check(v, 0, "U1 offset 0xC reads 0");
        wr8(BASE + 32'hC, 32'hFFFF_FFFF, 4'b1111);
        rd(DATAOUT, v); check(v, 32'hA5, "U1 write to offset 0xC changes nothing");

        // Full decode: none of these may reach a register.
        wr8(32'hF000_0010, 32'hFF, 4'b1111);    // addr[23:4] != 0
        wr8(32'hF010_0000, 32'hFF, 4'b1111);    // deep inside the slot
        wr8(32'hF100_0000, 32'hFF, 4'b1111);    // UART's slot
        wr8(32'hE000_0000, 32'hFF, 4'b1111);    // outside the region
        wr8(32'h0000_0000, 32'hFF, 4'b1111);
        rd(DATAOUT, v); check(v, 32'hA5, "U1 no aliasing: foreign addresses never write DATAOUT");
        rd(32'hF000_0010, v); check(v, 0, "U1 no aliasing: 0xF0000010 reads 0");
        rd(32'hF100_0000, v); check(v, 0, "U1 no aliasing: UART slot reads 0 from gpio");

        // Read chain: pass-through when not addressed, OR-in when addressed.
        chain_in = 32'h1234_0000;
        rd(32'hF100_0004, v); check(v, 32'h1234_0000, "U1 chain passes through when not addressed");
        rd(DATAOUT, v);       check(v, 32'h1234_00A5, "U1 chain ORs the register in when addressed");
        chain_in = 0;

        // ---------------- U2: byte lanes -------------------------------------
        wr8(DATAOUT, 32'h0000_5A00, 4'b0010); rd(DATAOUT, v); check(v, 32'hA5, "U2 sb to +1 (lane 1) leaves an 8-pin register");
        wr8(DATAOUT, 32'h5A00_0000, 4'b1000); rd(DATAOUT, v); check(v, 32'hA5, "U2 sb to +3 (lane 3) leaves it");
        wr8(DATAOUT, 32'h5A5A_0000, 4'b1100); rd(DATAOUT, v); check(v, 32'hA5, "U2 sh to +2 leaves it");
        wr8(DATAOUT, 32'hFFFF_FFFF, 4'b0000); rd(DATAOUT, v); check(v, 32'hA5, "U2 misaligned store (bw=0000) writes nothing");
        wr8(DATAOUT, 32'h0000_005A, 4'b0001); rd(DATAOUT, v); check(v, 32'h5A, "U2 sb to +0 (lane 0) writes");
        wr8(DATAOUT, 32'h0000_00C3, 4'b0011); rd(DATAOUT, v); check(v, 32'hC3, "U2 sh to +0 writes");

        wr32(DATAOUT, 32'h0000_0000, 4'b1111);
        wr32(DATAOUT, 32'hAABB_CCDD, 4'b0101);
        addr = DATAOUT; #1; check(rd32, 32'h00BB_00DD, "U2 32-pin: only lanes 0 and 2 written");
        wr32(DATAOUT, 32'h1122_3344, 4'b1010);
        addr = DATAOUT; #1; check(rd32, 32'h11BB_33DD, "U2 32-pin: then only lanes 1 and 3");

        // ---------------- U3: direction and drive ----------------------------
        wr8(DATADIR, 0, 4'b1111); wr8(DATAOUT, 32'hFF, 4'b1111);
        check({24'b0, oe8}, 0, "U3 DATAOUT=0xFF with DATADIR=0: no pin enabled");
        check({24'b0, o8}, 32'hFF, "U3 gpio_o still carries DATAOUT");
        for (i = 0; i < 8; i = i + 1) begin
            wr8(DATADIR, 32'h1 << i, 4'b0001);
            check({24'b0, oe8}, 32'h1 << i, "U3 exactly the written pin is enabled");
        end
        // Switching mid-drive: oe changes on the write edge itself, never early.
        @(negedge clk); addr = DATADIR; wdata = 32'h00; bw = 4'b0001; we8 = 1;
        #1 check({24'b0, oe8}, 32'h80, "U3 enable unchanged before the write edge");
        @(posedge clk); #1 check({24'b0, oe8}, 0, "U3 enable released on the write edge");
        @(negedge clk); we8 = 0; bw = 0;

        // ---------------- U4: DATAIN synchroniser and gating ------------------
        wr8(DATADIR, 32'h0F, 4'b1111);           // pins 3:0 outputs, 7:4 inputs
        @(negedge clk); pins8_i = 8'hFF;
        rd(DATAIN, v); check(v, 32'h00, "U4 new input level not visible at once");
        @(posedge clk); #1 rd(DATAIN, v); check(v, 32'h00, "U4 still not visible after 1 clock");
        @(posedge clk); #1 rd(DATAIN, v); check(v, 32'hF0, "U4 visible after 2 clocks; output pins read 0");
        @(negedge clk); pins8_i = 8'h5A; repeat (2) @(posedge clk); #1
        rd(DATAIN, v); check(v, 32'h50, "U4 inputs follow the pins, outputs stay 0");
        wr8(DATADIR, 32'h00, 4'b1111); repeat (2) @(posedge clk); #1
        rd(DATAIN, v); check(v, 32'h5A, "U4 all pins readable once all are inputs");

        // Reset mid-operation returns every register to its reset value.
        wr8(DATADIR, 32'hFF, 4'b1111);
        @(negedge clk) rst = 1; @(negedge clk) rst = 0;
        rd(DATADIR, v); check(v, 0, "U4 reset clears DATADIR");
        rd(DATAOUT, v); check(v, 0, "U4 reset clears DATAOUT");
        check({24'b0, oe8}, 0, "U4 reset releases every pin");

        $display("==== tb_gpio: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_GPIO: ALL TESTS PASSED");
        else           $display("TB_GPIO: FAILURES PRESENT");
        $finish;
    end
endmodule
