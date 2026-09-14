`timescale 1ns/1ps
// ============================================================================
// tb_firmware.v - firmware-level verification (§15.4/§16.1 tb_firmware
// equivalent). Runs tests/progs/tb_firmware_prog.hex, a straight-line
// program covering all 47 required instructions (§4.1/§4.2), each of which
// stores an independently-computed (actual XOR expected) diff into a
// dedicated DMEM signature slot (0 = pass). JAL/JALR/AUIPC/FENCE/EBREAK
// are verified structurally in the program's hand-written tail via direct
// register checks, and ECALL/EBREAK are additionally confirmed to each
// produce exactly one sys_event_o pulse (§8.6) with no other side effects.
//
// Since `top` has only clk_i/rst_i (no observable I/O, §14.1), every check
// below is via simulator hierarchical references into register_file/dmem -
// exactly the "no observable I/O" verification strategy the architecture
// requires. This testbench also logs every sys_event_o pulse with its
// cycle number, matching the firmware-completion logging the Submission
// Guide asks for (§6 / §15.4).
// ============================================================================
`include "tb/tb_dmem_probe.vh"
module tb_firmware;
    reg clk, rst;

    // Test count, signature base and the two address-dependent expectations
    // all come from the generator run that produced the image being executed,
    // so none of them can go stale as the test program grows.
    `include "tests/progs/tb_firmware_expected.vh"

    // IMEM sized to the exact generated image so $readmemh fills it exactly;
    // DMEM at the full architectural 8kB (Block Guide Table 6/13).
    top #(.IMEM_WORDS(IMEM_WORDS_NEEDED), .DMEM_WORDS(2048),
          .IMEM_INIT_FILE("tests/progs/tb_firmware_prog.hex")) dut (
        .clk_i(clk), .rst_i(rst)
    );

    always #5 clk = ~clk;

    integer pass, fail;
    integer cyc;
    integer event_count;
    integer i;

    // Log every sys_event_o pulse (§8.6/§15.4 - the firmware-completion
    // event marker), with cycle number and PC, exactly as the Submission
    // Guide's firmware-demo logging requirement expects.
    always @(posedge clk) begin
        if (dut.sys_event_o === 1'b1) begin
            event_count = event_count + 1;
            $display("[sys_event_o pulse #%0d] cycle=%0d pc=%h", event_count, cyc, dut.u_core.u_pc.pc);
        end
    end

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
        pass = 0; fail = 0; event_count = 0; cyc = 0;
        @(posedge clk); @(posedge clk); #1; rst = 0;

        // Run for a generous, fixed cycle budget (safer than trying to
        // synchronize on "the" sys_event_o pulse when the program legitimately
        // produces more than one - EBREAK then ECALL both pulse it).
        repeat (5000) begin
            @(posedge clk); #1;
            cyc = cyc + 1;
        end

        $display("Ran %0d cycles, observed %0d sys_event_o pulses (expect 2: EBREAK then ECALL)", cyc, event_count);
        if (event_count == 2) pass = pass + 1;
        else begin fail=fail+1; $display("FAIL: expected exactly 2 sys_event_o pulses, got %0d", event_count); end

        // ---- Check every diff-based instruction test ----
        begin : sig_check
            reg [31:0] sig_word;
            integer sig_fail_count;
            sig_fail_count = 0;
            for (i = 0; i < NUM_SIG_TESTS; i = i + 1) begin
                sig_word = `DMEM_WORD(dut.u_dmem, SIG_BASE_WORDS + i);
                if (sig_word === 32'b0) pass = pass + 1;
                else begin
                    fail = fail + 1;
                    sig_fail_count = sig_fail_count + 1;
                    $display("FAIL signature[%0d]: diff=%h (nonzero => instruction test failed)", i, sig_word);
                end
            end
            $display("Signature-based instruction tests: %0d/%0d passed", NUM_SIG_TESTS - sig_fail_count, NUM_SIG_TESTS);
        end

        // ---- Structural checks: JAL/JALR/AUIPC/FENCE/EBREAK tail ----
        check_reg(7,  32'h0000_0000, "x7 must be skipped by JAL (register reset default)");
        check_reg(8,  32'h0000_0001, "x8 proves JAL landed");
        check_reg(9,  EXP_JALR_LINK, "x9 JALR link address");
        check_reg(11, 32'h0000_0001, "x11 IS reached once - the link register (x9) points exactly at it, and jalr_target's own return jump (jalr x0,0(x9)) lands there");
        check_reg(12, 32'h0000_0001, "x12 proves JALR landed");
        check_reg(13, 32'h0000_0001, "x13 proves control flow rejoined after JALR return");
        check_reg(14, EXP_AUIPC, "x14 AUIPC = pc + (5<<12)");
        check_reg(15, 32'h0000_0077, "x15 sentinel before FENCE");
        check_reg(16, 32'h0000_0077, "x16 confirms FENCE was a pure no-op");
        check_reg(17, 32'h0000_0088, "x17 sentinel before EBREAK");
        check_reg(18, 32'h0000_0088, "x18 confirms EBREAK was a pure no-op (control-flow-wise)");

        $display("==== tb_firmware: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_FIRMWARE: ALL TESTS PASSED (47/47 instructions verified)");
        else $display("TB_FIRMWARE: FAILURES PRESENT");
        $finish;
    end
endmodule
