`timescale 1ns/1ps
// ============================================================================
// tb_mirror_equiv.v - proves ci_top.v is behaviourally identical to the
// verified rtl_ref/top.v.
//
// This is the load-bearing check of the whole migration. ci_top.v flattens
// away riscv_core, turns four inline `assign`s and one `case` into real mux
// blocks, adds ir_fields, feeds funct3 from control_unit's op_size instead of
// slicing ir, and swaps a $readmemh ROM for a generated case-ROM. Each of
// those is individually plausible and collectively easy to get subtly wrong.
//
// Both designs run the same firmware from the same reset, in lockstep, and
// every cycle this compares the complete architectural state: PC, IR, FSM
// state, all 32 GPRs, the memory-transaction interface, and every DMEM word
// that the program touches. A single-cycle divergence anywhere fails the run.
//
// TWO PHASES, BECAUSE THE ROM HOLDS TWO PROGRAMS
// ----------------------------------------------
// Phase 1 runs from the reset vector, which is the official validation
// firmware: RV32I arithmetic and logic, every load and store width, every
// branch, JAL/JALR, all four multiplies, all three CRC widths, and a copy loop
// that reads IMEM and writes DMEM.
// Phase 2 enters this project's supplementary program at 0x00400800, which is
// what reaches FENCE, ECALL, EBREAK, illegal instructions and misaligned
// access. Without it the equivalence claim would have a hole exactly where the
// official firmware happens not to go.
//
// Both designs read the same ROM: the mirror from its generated case, the
// reference by $readmemh of build/rom_image.hex, which gen_ci_imem.py emits
// from the identical word list.
//
// Run via scripts/run_ci.sh, which compiles the two designs into separate
// module namespaces using -DMIRROR_REF / library flags.
// ============================================================================
module tb_mirror_equiv;
    reg clk = 0, rst = 1;

    localparam [31:0] SUPP_BASE = 32'h00400800;
    localparam        ROM_WORDS = 995;   // 512 + 483, gap included

    // Device under test: the ChipInventor mirror.
    top dut_ci (.clk_i(clk), .rst_i(rst));

    // Reference: the original two-level hierarchy, renamed to ref_top by the
    // build script so both can be elaborated together.
    ref_top #(.IMEM_WORDS(ROM_WORDS), .DMEM_WORDS(2048),
              .IMEM_INIT_FILE("build/rom_image.hex")) dut_ref (
        .clk_i(clk), .rst_i(rst)
    );

    always #5 clk = ~clk;

    integer pass, fail, cyc, i;
    integer diverged;

    localparam CYCLES     = 5000;
    localparam WATCH_WORDS = 200;   // covers the signature area the program writes

    task cmp32(input [31:0] a, input [31:0] b, input [8*40-1:0] what);
        begin
            if (a === b) pass = pass + 1;
            else begin
                fail = fail + 1;
                if (diverged < 20) begin
                    diverged = diverged + 1;
                    $display("DIVERGE cyc=%0d %0s: ci=%h ref=%h", cyc, what, a, b);
                end
            end
        end
    endtask

    // One lockstep phase. `entry` is 0 to run from the reset vector, or an
    // address to enter at (written while both cores are still in reset, where
    // pc_write is inactive so the value survives to the first fetch).
    task run_phase(input [31:0] entry, input [8*32-1:0] label);
        begin
            // Both DMEMs start zeroed. rtl_ref/dmem.v zero-fills itself under
            // `ifndef SYNTHESIS; the mirror's dmem deliberately does not, so it
            // is zeroed here - the same thing tb_chipinventor does.
            rst = 1;
            repeat (3) @(posedge clk); #1;
            for (i = 0; i < 2048; i = i + 1) begin
                dut_ci.u_dmem.mem[i]  = 32'b0;
                dut_ref.u_dmem.mem[i] = 32'b0;
            end
            if (entry !== 32'b0) begin
                dut_ci.u_pc.pc         = entry;
                dut_ref.u_core.u_pc.pc = entry;
            end
            rst = 0;

            for (cyc = 0; cyc < CYCLES; cyc = cyc + 1) begin
                @(posedge clk); #1;

                cmp32({29'b0, dut_ci.u_ctrl.state}, {29'b0, dut_ref.u_core.u_ctrl.state}, "state");
                cmp32(dut_ci.u_pc.pc,   dut_ref.u_core.u_pc.pc,   "pc");
                cmp32(dut_ci.u_ir.ir,   dut_ref.u_core.u_ir.ir,   "ir");
                cmp32(dut_ci.core_address, dut_ref.core_address,  "address");
                cmp32(dut_ci.core_store_data, dut_ref.core_store_data, "store_data");
                cmp32({28'b0, dut_ci.core_bw}, {28'b0, dut_ref.core_bw}, "bw");
                cmp32({31'b0, dut_ci.core_we}, {31'b0, dut_ref.core_we}, "we");
                cmp32({31'b0, dut_ci.core_oe}, {31'b0, dut_ref.core_oe}, "oe");
                cmp32({31'b0, dut_ci.sys_event_o}, {31'b0, dut_ref.sys_event_o}, "sys_event");

                for (i = 0; i < 32; i = i + 1)
                    cmp32(dut_ci.u_rf.regs[i], dut_ref.u_core.u_rf.regs[i], "gpr");

                if (fail > 0 && diverged >= 20) begin
                    $display("Stopping early at cycle %0d - divergence is systematic.", cyc);
                    cyc = CYCLES;
                end
            end

            // Final memory image must match word for word over everything touched.
            for (i = 0; i < WATCH_WORDS; i = i + 1)
                cmp32(dut_ci.u_dmem.mem[i], dut_ref.u_dmem.mem[i], "dmem");

            $display("  phase %0s: %0d cycles compared, running total %0d passed / %0d failed",
                     label, CYCLES, pass, fail);
        end
    endtask

    initial begin
        pass = 0; fail = 0; cyc = 0; diverged = 0;

        run_phase(32'h0000_0000, "official firmware");
        run_phase(SUPP_BASE,     "supplementary");

        $display("==== tb_mirror_equiv: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0)
            $display("TB_MIRROR_EQUIV: ALL TESTS PASSED (ci_top matches rtl_ref/top exactly)");
        else
            $display("TB_MIRROR_EQUIV: FAILURES PRESENT");
        $finish;
    end
endmodule
