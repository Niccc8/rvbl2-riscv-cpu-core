// ============================================================================
// tb_mock_imem.v - proves blocks/imem_mock.v is a real drop-in, not just a
// file that compiles.
//
// blocks/imem_mock.v is what gets pasted for the OpenLane / P&R run, so it is
// the version of the design that actually gets taped out. It would be easy for
// it to rot: it is not exercised by the main suite (it cannot be - it declares
// the same module name as imem.v, so the two can never be elaborated
// together), and a mock that quietly stopped driving the core would not be
// noticed until a synthesis run produced something meaningless.
//
// So this builds the whole core against the mock and runs their program:
//
//     addi x5, x0, 10   /   addi x6, x0, 5   /   add x7, x5, x6
//
// and checks the result their README states: x7 = 15.
//
// Build:
//   iverilog -g2005 -s tb_mock_imem -o mock.vvp \
//       $(ls blocks/*.v | grep -v '/imem\.v$') blocks/imem_mock.v ci_top.v \
//       scripts/tb_mock_imem.v
// ============================================================================
`timescale 1ns/1ps
module tb_mock_imem;

    reg clk = 1'b0;
    reg rst = 1'b1;
    integer pass = 0, fail = 0;

    always #5 clk = ~clk;

    // `top` is ci_top.v - the flat mirror of what the canvas generates.
    top dut (.clk_i(clk), .rst_i(rst));

    task check(input [31:0] got, input [31:0] exp, input [8*48-1:0] name);
        begin
            if (got === exp) begin
                pass = pass + 1;
            end else begin
                fail = fail + 1;
                $display("[FAIL] %0s: got %08h, expected %08h", name, got, exp);
            end
        end
    endtask

    initial begin
        // Hold reset long enough for the state register and the GPRs to settle.
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Three instructions at 4 cycles each; run well past that so the core
        // is provably retiring the default NOPs rather than having stalled.
        repeat (200) @(posedge clk);

        check(dut.u_rf.regs[5], 32'd10, "x5 = 10");
        check(dut.u_rf.regs[6], 32'd5,  "x6 = 5");
        check(dut.u_rf.regs[7], 32'd15, "x7 = x5 + x6");

        // The core must still be fetching, not parked or wedged: the PC has to
        // have advanced past the three real instructions into NOP territory.
        if (dut.u_pc.pc > 32'h0040_0008) pass = pass + 1;
        else begin
            fail = fail + 1;
            $display("[FAIL] core did not advance past the mock program (pc=%08h)",
                     dut.u_pc.pc);
        end

        $display("==== tb_mock_imem: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_MOCK_IMEM: ALL TESTS PASSED");
        else           $display("TB_MOCK_IMEM: FAILURES PRESENT");
        $finish;
    end
endmodule
