`timescale 1ns/1ps
module tb_immediate_generator;
    reg  [31:0] ir;
    wire [31:0] imm;
    integer pass, fail;

    immediate_generator dut (.ir(ir), .imm(imm));

    // Vector count comes from the same generator run that wrote the vector
    // files, so the three can never drift out of step.
    `include "tests/golden/imm_vectors_count.vh"

    reg [31:0] vec_ir  [0:NVEC-1];
    reg [31:0] vec_exp [0:NVEC-1];
    integer idx;

    initial begin
        pass = 0; fail = 0;
        $readmemh("tests/golden/imm_vectors_split_ir.hex", vec_ir);
        $readmemh("tests/golden/imm_vectors_split_exp.hex", vec_exp);
        for (idx = 0; idx < NVEC; idx = idx + 1) begin
            ir = vec_ir[idx];
            #1;
            if (imm === vec_exp[idx]) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL idx=%0d ir=%h -> got=%h exp=%h", idx, ir, imm, vec_exp[idx]);
            end
        end

        // R-type / SYSTEM / FENCE: don't-care value, just confirm it doesn't hang/x
        ir = 32'h0000_0033; #1; // ADD x0,x0,x0
        if (imm !== 32'bx) pass = pass + 1; else begin fail=fail+1; $display("FAIL: R-type imm is x"); end

        $display("==== tb_immediate_generator: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_IMMEDIATE_GENERATOR: ALL TESTS PASSED");
        else $display("TB_IMMEDIATE_GENERATOR: FAILURES PRESENT");
        $finish;
    end
endmodule
