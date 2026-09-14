`timescale 1ns/1ps
// ============================================================================
// tb_soc.v - SoC-level test (§16.1 tb_soc). Full `top` (2-pin external
// interface only), real IMEM/DMEM timing throughout. Exercises:
//  - a dependent-register loop (sum 1..5), confirming the "hazard-free by
//    construction" property (§5.1) across many back-to-back instructions;
//  - FENCE and an illegal encoding as pure no-ops;
//  - JALR indirect call/return;
//  - a load whose address resolves into IMEM rather than DMEM - the
//    specific timing case §7.4 added the extra oe_o/AddrSrc-through-
//    WriteBack scoping for, since IMEM (combinational, no output register)
//    would otherwise return 0 instead of the real constant.
// ============================================================================
`include "tb/tb_dmem_probe.vh"
module tb_soc;
    reg clk, rst;

    // IMEM sized to the exact tb_soc_prog image (a $readmemh size mismatch is
    // reported as a warning, so it stays visible if the program changes);
    // DMEM at the full architectural 8kB (Block Guide Table 6/13).
    top #(.IMEM_WORDS(26), .DMEM_WORDS(2048),
          .IMEM_INIT_FILE("tests/progs/tb_soc_prog.hex")) dut (
        .clk_i(clk), .rst_i(rst)
    );

    always #5 clk = ~clk;

    integer pass, fail, timeout_cycles;

    task check_reg(input [4:0] idx, input [31:0] exp, input [200:0] name);
        reg [31:0] got;
        begin
            got = dut.u_core.u_rf.regs[idx];
            if (got === exp) pass = pass + 1;
            else begin fail=fail+1; $display("FAIL %0s: x%0d got=%h exp=%h", name, idx, got, exp); end
        end
    endtask

    initial begin
        clk = 0; rst = 1;
        pass = 0; fail = 0;
        @(posedge clk); @(posedge clk); #1; rst = 0;

        timeout_cycles = 0;
        while (dut.sys_event_o !== 1'b1 && timeout_cycles < 1000) begin
            @(posedge clk); #1;
            timeout_cycles = timeout_cycles + 1;
        end
        if (dut.sys_event_o !== 1'b1) begin
            fail = fail + 1;
            $display("FAIL: program never reached ECALL within %0d cycles", timeout_cycles);
        end else begin
            pass = pass + 1;
            $display("Program reached ECALL after %0d cycles", timeout_cycles);
        end

        check_reg(20, 32'h1001_0000, "x20 DMEM base");
        check_reg(1,  32'd15,        "x1 loop sum(1..5)=15 (back-to-back dependent ADDs)");
        check_reg(2,  32'd6,         "x2 loop counter final value");
        check_reg(4,  32'h0000_0055, "x4 sentinel before FENCE/illegal");
        check_reg(5,  32'h0000_0055, "x5 confirms FENCE+illegal did not corrupt state");
        check_reg(6,  32'h0040_003C, "x6 JALR link address");
        check_reg(7,  32'h0000_00AA, "x7 executed on return from callee");
        check_reg(8,  32'h0000_0033, "x8 proves indirect jump landed in callee");
        check_reg(9,  32'h0000_0099, "x9 proves control flow rejoined after call");
        check_reg(11, 32'h0040_0050, "x11 AUIPC = its own address");
        check_reg(12, 32'hCAFE_BABE, "x12 LOAD-FROM-IMEM constant (critical §7.4 timing case)");
        check_reg(13, 32'd1,        "x13 reached after IMEM load, control flow still sane");

        // Loop result must also have made it to DMEM correctly
        if (`DMEM_WORD(dut.u_dmem, 0) === 32'd15) pass=pass+1;
        else begin fail=fail+1; $display("FAIL: DMEM[0x10010000] expected 15 (loop result), got %0d", `DMEM_WORD(dut.u_dmem, 0)); end

        $display("==== tb_soc: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_SOC: ALL TESTS PASSED");
        else $display("TB_SOC: FAILURES PRESENT");
        $finish;
    end
endmodule
