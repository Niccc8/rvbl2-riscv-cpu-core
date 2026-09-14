`timescale 1ns/1ps
// ============================================================================
// tb_reset.v - SoC-level reset-during-execution stress (§15.3).
//
// The unit-level reset check in tb_control_unit confirms the combinational
// enables drop in the same cycle rst_i asserts. That check cannot see the
// thing that actually matters at system level: whether an in-flight DMEM
// write is genuinely aborted before it commits. This testbench asserts rst_i
// at every cycle offset across a running program - so reset lands in FETCH,
// DECODE, EXECUTE, MEMORY and WRITEBACK, and specifically inside a store's
// MEMORY cycle - and after each injection confirms:
//
//   * no DMEM word changed across the reset edge (the write was aborted),
//   * PC is back at the reset vector 0x00400000 (Block Guide Table 13),
//   * the FSM is in RESET,
//   * every GPR is cleared,
//
// then releases reset once more and confirms the program re-runs to the same
// result, i.e. reset leaves the core in a genuinely usable state rather than
// merely a quiet one.
// ============================================================================
`include "tb/tb_dmem_probe.vh"
module tb_reset;
    reg clk = 0, rst = 1;

    localparam INJECT_POINTS = 40;
    localparam DMEM_W        = 2048;
    localparam [2:0] S_RESET = 3'd0;

    top #(.IMEM_WORDS(34), .DMEM_WORDS(DMEM_W),
          .IMEM_INIT_FILE("tests/progs/tb_core_prog.hex")) dut (
        .clk_i(clk), .rst_i(rst)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer n, i, k;
    // Only the words tb_core_prog actually touches need snapshotting; the rest
    // of DMEM is never written, so a full 2048-word snapshot per injection
    // would cost simulation time without adding coverage.
    localparam WATCH_WORDS = 16;
    reg [31:0] snap [0:WATCH_WORDS-1];

    initial begin
        pass = 0; fail = 0;

        for (n = 1; n <= INJECT_POINTS; n = n + 1) begin
            // Clean start, then run n cycles so reset lands at a different
            // point in the instruction stream on every iteration.
            rst = 1; repeat (3) @(posedge clk); #1;
            rst = 0;
            repeat (n) @(posedge clk);
            #1;

            for (i = 0; i < WATCH_WORDS; i = i + 1) snap[i] = `DMEM_WORD(dut.u_dmem, i);

            rst = 1;            // assert mid-instruction
            @(posedge clk); #1; // the edge reset must abort

            for (i = 0; i < WATCH_WORDS; i = i + 1) begin
                if (`DMEM_WORD(dut.u_dmem, i) === snap[i]) pass = pass + 1;
                else begin
                    fail = fail + 1;
                    $display("FAIL n=%0d: DMEM[%0d] changed across reset edge: %h -> %h",
                             n, i, snap[i], `DMEM_WORD(dut.u_dmem, i));
                end
            end

            if (dut.u_core.u_pc.pc === 32'h0040_0000) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL n=%0d: PC after reset = %h, expected 00400000",
                         n, dut.u_core.u_pc.pc);
            end

            if (dut.u_core.u_ctrl.state === S_RESET) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL n=%0d: state after reset = %0d, expected RESET",
                         n, dut.u_core.u_ctrl.state);
            end

            for (i = 0; i < 32; i = i + 1) begin
                if (dut.u_core.u_rf.regs[i] === 32'd0) pass = pass + 1;
                else begin
                    fail = fail + 1;
                    $display("FAIL n=%0d: x%0d not cleared by reset: %h",
                             n, i, dut.u_core.u_rf.regs[i]);
                end
            end
        end

        // Recovery: the core must still run the program correctly afterwards.
        rst = 1; repeat (2) @(posedge clk); #1; rst = 0;
        k = 0;
        while (dut.sys_event_o !== 1'b1 && k < 500) begin
            @(posedge clk); #1;
            k = k + 1;
        end
        if (dut.sys_event_o !== 1'b1) begin
            fail = fail + 1;
            $display("FAIL: no clean recovery - program never reached ECALL after reset");
        end else pass = pass + 1;

        if (dut.u_core.u_rf.regs[3] === 32'd15) pass = pass + 1;
        else begin
            fail = fail + 1;
            $display("FAIL: post-reset re-run produced wrong result x3=%h",
                     dut.u_core.u_rf.regs[3]);
        end

        $display("==== tb_reset: %0d passed, %0d failed (%0d injection points) ====",
                 pass, fail, INJECT_POINTS);
        if (fail == 0) $display("TB_RESET: ALL TESTS PASSED");
        else $display("TB_RESET: FAILURES PRESENT");
        $finish;
    end
endmodule
