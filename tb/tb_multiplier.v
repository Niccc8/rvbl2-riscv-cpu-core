`timescale 1ns/1ps
module tb_multiplier;
    reg  [31:0] rs1, rs2;
    reg  [2:0]  f3;
    wire [31:0] result;
    integer pass, fail;

    multiplier dut (.rs1_data(rs1), .rs2_data(rs2), .funct3(f3), .result(result));

    // ---- Independent 64-bit software reference model (not derived from
    // the RTL's internal a_signed/b_signed/sel_upper expressions) ----
    reg signed [63:0] a_s, b_s;
    reg        [63:0] a_u, b_u;
    reg        [63:0] prod_ss, prod_uu, prod_su;
    reg        [31:0] expected;

    task compute_expected(input [31:0] r1, input [31:0] r2, input [2:0] fn3);
        begin
            a_s = $signed(r1); b_s = $signed(r2);
            a_u = {32'b0, r1}; b_u = {32'b0, r2};
            prod_ss = a_s * b_s;
            prod_uu = a_u * b_u;
            prod_su = a_s * b_u; // MULHSU: rs1 signed * rs2 unsigned
            case (fn3)
                3'b000: expected = prod_ss[31:0];
                3'b001: expected = prod_ss[63:32];
                3'b010: expected = prod_su[63:32];
                3'b011: expected = prod_uu[63:32];
                default: expected = 32'b0;
            endcase
        end
    endtask

    task check(input [200:0] name);
        begin
            compute_expected(rs1, rs2, f3);
            #1;
            if (result === expected) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL %0s: rs1=%h rs2=%h f3=%b -> got=%h exp=%h",
                          name, rs1, rs2, f3, result, expected);
            end
        end
    endtask

    integer i;
    reg [31:0] corner [0:6];
    integer c1, c2;

    initial begin
        pass = 0; fail = 0;
        corner[0] = 32'h0000_0000;
        corner[1] = 32'h0000_0001;
        corner[2] = 32'hFFFF_FFFF; // -1
        corner[3] = 32'h8000_0000; // INT_MIN
        corner[4] = 32'h7FFF_FFFF; // INT_MAX
        corner[5] = 32'h0000_0002;
        corner[6] = 32'hFFFF_FFFE; // -2

        // Directed corner-value sweep, all 4 ops, all corner x corner pairs
        for (c1 = 0; c1 < 7; c1 = c1 + 1) begin
            for (c2 = 0; c2 < 7; c2 = c2 + 1) begin
                rs1 = corner[c1]; rs2 = corner[c2];
                f3 = 3'b000; check("MUL corner");
                f3 = 3'b001; check("MULH corner");
                f3 = 3'b010; check("MULHSU corner");
                f3 = 3'b011; check("MULHU corner");
            end
        end

        // INT_MIN * -1 (classic signed-overflow corner, must wrap, not trap)
        rs1 = 32'h8000_0000; rs2 = 32'hFFFF_FFFF;
        f3 = 3'b000; check("MUL INT_MIN*-1 (wraps)");
        f3 = 3'b001; check("MULH INT_MIN*-1");

        // Randomized sweep, all 4 ops
        for (i = 0; i < 500; i = i + 1) begin
            rs1 = $random; rs2 = $random;
            f3 = 3'b000; check("MUL random");
            f3 = 3'b001; check("MULH random");
            f3 = 3'b010; check("MULHSU random");
            f3 = 3'b011; check("MULHU random");
        end

        $display("==== tb_multiplier functional: %0d passed, %0d failed ====", pass, fail);

        // -------------------------------------------------------------
        // Brute-force truth-table verification of the *design formulas*
        // themselves (a_signed, b_signed, sel_upper) against the intended
        // Table-10 truth table, independent of the RTL instance above -
        // this is the check the architecture spec explicitly calls for
        // before trusting any "reuse one control bit" shortcut (§9.9/§22 R19).
        // -------------------------------------------------------------
        begin : truth_table_check
            reg [2:0] fn3;
            reg exp_a_signed, exp_b_signed, exp_sel_upper;
            reg got_a_signed, got_b_signed, got_sel_upper;
            integer tt_pass, tt_fail;
            tt_pass = 0; tt_fail = 0;
            for (fn3 = 0; fn3 < 4; fn3 = fn3 + 1) begin
                case (fn3)
                    3'b000: begin exp_a_signed=1; exp_b_signed=1; exp_sel_upper=0; end // MUL
                    3'b001: begin exp_a_signed=1; exp_b_signed=1; exp_sel_upper=1; end // MULH
                    3'b010: begin exp_a_signed=1; exp_b_signed=0; exp_sel_upper=1; end // MULHSU
                    3'b011: begin exp_a_signed=0; exp_b_signed=0; exp_sel_upper=1; end // MULHU
                    default: begin exp_a_signed=1; exp_b_signed=1; exp_sel_upper=0; end
                endcase
                got_a_signed  = ~(fn3[1] & fn3[0]);
                got_b_signed  = ~fn3[1];
                got_sel_upper = fn3[1] | fn3[0];
                if (got_a_signed===exp_a_signed && got_b_signed===exp_b_signed && got_sel_upper===exp_sel_upper)
                    tt_pass = tt_pass + 1;
                else begin
                    tt_fail = tt_fail + 1;
                    $display("FAIL truth-table funct3=%b: a_signed=%b(exp %b) b_signed=%b(exp %b) sel_upper=%b(exp %b)",
                        fn3, got_a_signed, exp_a_signed, got_b_signed, exp_b_signed, got_sel_upper, exp_sel_upper);
                end
                // also specifically confirm the historically-wrong shortcut
                // (sel_upper = fn3[0] alone) WOULD have failed on MULHSU,
                // documenting why the OR-of-both-bits form is required.
                if (fn3 == 3'b010) begin
                    if ((fn3[0]) !== exp_sel_upper)
                        $display("NOTE: funct3[0] alone for MULHSU = %b, correct is %b -- confirms the OR-both-bits form is required, not funct3[0] alone", fn3[0], exp_sel_upper);
                end
            end
            $display("==== tb_multiplier truth-table: %0d passed, %0d failed ====", tt_pass, tt_fail);
            pass = pass + tt_pass;
            fail = fail + tt_fail;
        end

        if (fail == 0) $display("TB_MULTIPLIER: ALL TESTS PASSED");
        else $display("TB_MULTIPLIER: FAILURES PRESENT");
        $finish;
    end
endmodule
