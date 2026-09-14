`timescale 1ns/1ps
// ============================================================================
// tb_gatelevel.v - gate-level equivalence check (§17 stage 16).
//
// Runs the RTL riscv_core and the Yosys-synthesized riscv_core in the same
// simulation, each against its own identical behavioral memory subsystem, and
// compares the core's complete external interface every cycle:
//
//     address_o, we_o, oe_o, bw_o, store_data_o, sys_event_o
//
// That interface is the whole of what the core presents to the rest of the
// SoC, so bit-identical behaviour on it over a full program is a strong
// functional equivalence result - and unlike a register-file comparison it
// works even though synthesis has flattened the netlist's internal names away.
// Both DMEM arrays are compared at the end as an independent architectural
// state check.
//
// The synthesized netlist must first be prepared by
// scripts/gen_gl_netlist.py, which prefixes its module names with gl_ so the
// two copies of the design can coexist. scripts/run_gl_equiv.sh does both
// steps. The netlist's own imem is a stub (the ROM is realised as logic from
// its $readmemh contents at synthesis time), so both sides here are driven by
// the behavioral imem, which is what makes this a check of the core rather
// than of the ROM.
// ============================================================================
`include "tb/tb_dmem_probe.vh"
module tb_gatelevel;
    reg clk = 0, rst = 1;

    parameter         IMEM_WORDS = 34;
    parameter         DMEM_WORDS = 2048;
    parameter integer CYCLES     = 900;
    parameter         PROG       = "tests/progs/tb_core_prog.hex";

    // ---------------- RTL side ----------------
    wire [31:0] r_addr, r_sdata, r_rdata;
    wire        r_we, r_oe, r_ev;
    wire [3:0]  r_bw;
    wire [31:0] r_imem_rd, r_dmem_rd;
    wire        r_imem_oe, r_dmem_oe, r_dmem_we;
    wire [3:0]  r_dmem_bw;

    riscv_core r_core (
        .clk_i(clk), .rst_i(rst), .mem_rdata_i(r_rdata),
        .address_o(r_addr), .we_o(r_we), .oe_o(r_oe), .bw_o(r_bw),
        .store_data_o(r_sdata), .sys_event_o(r_ev)
    );
    address_decoder r_dec (
        .address_i(r_addr), .we_i(r_we), .oe_i(r_oe), .bw_i(r_bw),
        .imem_rdata(r_imem_rd), .dmem_rdata(r_dmem_rd),
        .imem_oe_o(r_imem_oe), .dmem_we_o(r_dmem_we), .dmem_oe_o(r_dmem_oe),
        .dmem_bw_o(r_dmem_bw), .data_o(r_rdata)
    );
    imem #(.IMEM_WORDS(IMEM_WORDS), .INIT_FILE(PROG)) r_imem (
        .address_i(r_addr), .oe_i(r_imem_oe), .data_o(r_imem_rd)
    );
    dmem #(.DMEM_WORDS(DMEM_WORDS)) r_dmem (
        .clk_i(clk), .rst_i(rst), .address_i(r_addr), .we_i(r_dmem_we),
        .oe_i(r_dmem_oe), .bw_i(r_dmem_bw), .data_i(r_sdata), .data_o(r_dmem_rd)
    );

    // ---------------- Gate-level side ----------------
    wire [31:0] g_addr, g_sdata, g_rdata;
    wire        g_we, g_oe, g_ev;
    wire [3:0]  g_bw;
    wire [31:0] g_imem_rd, g_dmem_rd;
    wire        g_imem_oe, g_dmem_oe, g_dmem_we;
    wire [3:0]  g_dmem_bw;

    gl_riscv_core g_core (
        .clk_i(clk), .rst_i(rst), .mem_rdata_i(g_rdata),
        .address_o(g_addr), .we_o(g_we), .oe_o(g_oe), .bw_o(g_bw),
        .store_data_o(g_sdata), .sys_event_o(g_ev)
    );
    address_decoder g_dec (
        .address_i(g_addr), .we_i(g_we), .oe_i(g_oe), .bw_i(g_bw),
        .imem_rdata(g_imem_rd), .dmem_rdata(g_dmem_rd),
        .imem_oe_o(g_imem_oe), .dmem_we_o(g_dmem_we), .dmem_oe_o(g_dmem_oe),
        .dmem_bw_o(g_dmem_bw), .data_o(g_rdata)
    );
    imem #(.IMEM_WORDS(IMEM_WORDS), .INIT_FILE(PROG)) g_imem (
        .address_i(g_addr), .oe_i(g_imem_oe), .data_o(g_imem_rd)
    );
    dmem #(.DMEM_WORDS(DMEM_WORDS)) g_dmem (
        .clk_i(clk), .rst_i(rst), .address_i(g_addr), .we_i(g_dmem_we),
        .oe_i(g_dmem_oe), .bw_i(g_dmem_bw), .data_i(g_sdata), .data_o(g_dmem_rd)
    );

    always #5 clk = ~clk;

    integer pass, fail, c, i;

    initial begin
        pass = 0; fail = 0;
        @(posedge clk); @(posedge clk); #1; rst = 0;

        for (c = 0; c < CYCLES; c = c + 1) begin
            @(posedge clk); #2; // settle past the edge before sampling
            if (r_addr  === g_addr  && r_we    === g_we  && r_oe === g_oe &&
                r_bw    === g_bw    && r_sdata === g_sdata && r_ev === g_ev)
                pass = pass + 1;
            else begin
                fail = fail + 1;
                if (fail <= 5)
                    $display("FAIL cycle %0d: addr %h/%h we %b/%b oe %b/%b bw %h/%h sdata %h/%h ev %b/%b",
                             c, r_addr, g_addr, r_we, g_we, r_oe, g_oe,
                             r_bw, g_bw, r_sdata, g_sdata, r_ev, g_ev);
            end
        end

        // Architectural state: both DMEM arrays must agree word for word.
        // Bank 0 covers every word these programs touch (see tb_dmem_probe.vh).
        for (i = 0; i < 512; i = i + 1) begin
            if (`DMEM_WORD(r_dmem, i) !== `DMEM_WORD(g_dmem, i)) begin
                fail = fail + 1;
                $display("FAIL: DMEM word %0d differs: RTL %h vs GL %h",
                         i, `DMEM_WORD(r_dmem, i), `DMEM_WORD(g_dmem, i));
            end
        end
        pass = pass + 1;

        $display("==== tb_gatelevel: %0d passed, %0d failed (%0d cycles compared) ====",
                 pass, fail, CYCLES);
        if (fail == 0) $display("TB_GATELEVEL: ALL TESTS PASSED");
        else $display("TB_GATELEVEL: FAILURES PRESENT");
        $finish;
    end
endmodule
