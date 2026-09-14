`timescale 1ns/1ps
// ============================================================================
// tb_core.v - core-level integration test (§16.1/§16.2 tb_core equivalent).
// Instantiates riscv_core + address_decoder + imem + dmem (i.e. everything
// except the outermost `top` wrapper) and runs a small hand-written program
// exercising one representative instruction from every major class:
// ALU-reg, ALU-imm, shifts, SLT/SLTU, LUI, MUL/MULH, CRCB, SW/LW, SB/LBU,
// untaken branch, taken branch, JAL (with skip), AUIPC, ECALL.
//
// Verification is via hierarchical references directly into the register
// file and DMEM array - the same "no observable I/O" introspection approach
// required at the SoC level (§14.1), exercised here one level down.
// ============================================================================
`include "tb/tb_dmem_probe.vh"
module tb_core;
    reg clk, rst;

    // IMEM sized to the exact tb_core_prog image (a $readmemh size mismatch is
    // reported as a warning, so it stays visible if the program changes);
    // DMEM at the full architectural 8kB (Block Guide Table 6/13).
    top #(.IMEM_WORDS(34), .DMEM_WORDS(2048),
          .IMEM_INIT_FILE("tests/progs/tb_core_prog.hex")) dut (
        .clk_i(clk), .rst_i(rst)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer timeout_cycles;

    task check_reg(input [4:0] idx, input [31:0] exp, input [200:0] name);
        reg [31:0] got;
        begin
            got = dut.u_core.u_rf.regs[idx];
            if (got === exp) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL %0s: x%0d got=%h exp=%h", name, idx, got, exp);
            end
        end
    endtask

    initial begin
        clk = 0; rst = 1;
        pass = 0; fail = 0;
        @(posedge clk); @(posedge clk); #1; rst = 0;

        // Run until the program's ECALL fires sys_event_o, or bail out
        // after a generous cycle budget (never hang indefinitely).
        timeout_cycles = 0;
        while (dut.sys_event_o !== 1'b1 && timeout_cycles < 500) begin
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

        // ---- Check every register the program set, per its comments ----
        check_reg(20, 32'h1001_0000, "x20 DMEM base (LUI)");
        check_reg(1,  32'd5,          "x1 ADDI");
        check_reg(2,  32'd10,         "x2 ADDI");
        check_reg(3,  32'd15,         "x3 ADD");
        check_reg(4,  32'd5,          "x4 SUB");
        check_reg(5,  32'd0,          "x5 AND");
        check_reg(6,  32'd15,         "x6 OR");
        check_reg(7,  32'd15,         "x7 XOR");
        check_reg(8,  32'd20,         "x8 SLLI");
        check_reg(9,  32'd5,          "x9 SRLI");
        check_reg(10, 32'd1,          "x10 SLT");
        check_reg(11, 32'd1,          "x11 SLTU");
        check_reg(12, 32'hFFFF_FFFF,  "x12 ADDI -1");
        check_reg(13, 32'hFFFF_FFFF,  "x13 SRA(-1 >>> 5 = -1)");
        check_reg(14, 32'h1234_5000,  "x14 LUI");
        check_reg(16, 32'd50,         "x16 MUL 5*10");
        check_reg(17, 32'd0,          "x17 MULH 5*10 (upper=0)");
        check_reg(18, 32'h0000_50A5,  "x18 CRCB(seed=0,byte=5) golden-model cross-check");
        check_reg(21, 32'd15,         "x21 LW readback");
        check_reg(22, 32'd5,          "x22 LBU readback");
        check_reg(23, 32'd1,          "x23 untaken branch falls through to next instr");
        check_reg(24, 32'd2,          "x24 taken branch skip verified");
        check_reg(25, 32'h0040_0078, "x25 JAL link address (pc+4 of the jal instruction)");
        check_reg(26, 32'd0,          "x26 must be skipped by JAL (never executed)");
        check_reg(27, 32'd42,         "x27 proves JAL landed at jtarget");
        check_reg(28, 32'h0040_0080, "x28 AUIPC = its own address");

        // DMEM contents written by SW/SB
        if (`DMEM_WORD(dut.u_dmem, 0) === 32'd15) pass=pass+1;
        else begin fail=fail+1; $display("FAIL: DMEM[0x10010000] expected 15, got %0d", `DMEM_WORD(dut.u_dmem, 0)); end

        if (`DMEM_WORD(dut.u_dmem, 1)[7:0] === 8'd5) pass=pass+1;
        else begin fail=fail+1; $display("FAIL: DMEM[0x10010004] byte0 expected 5, got %0d", `DMEM_WORD(dut.u_dmem, 1)[7:0]); end

        $display("==== tb_core: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_CORE: ALL TESTS PASSED");
        else $display("TB_CORE: FAILURES PRESENT");
        $finish;
    end
endmodule
