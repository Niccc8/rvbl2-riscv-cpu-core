`timescale 1ns/1ps
module tb_branch_comparator;
    reg  [31:0] rs1, rs2;
    reg  [2:0]  f3;
    wire        taken;
    integer pass, fail;

    branch_comparator dut (.rs1_data(rs1), .rs2_data(rs2), .funct3(f3), .branch_taken(taken));

    task check(input exp, input [200:0] name);
        begin
            if (taken === exp) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL %0s: rs1=%h rs2=%h f3=%b -> got=%b exp=%b", name, rs1, rs2, f3, taken, exp);
            end
        end
    endtask

    initial begin
        pass = 0; fail = 0;

        rs1=32'd5; rs2=32'd5; f3=3'b000; #1; check(1'b1, "BEQ equal");
        rs1=32'd5; rs2=32'd6; f3=3'b000; #1; check(1'b0, "BEQ not-equal");
        rs1=32'd5; rs2=32'd6; f3=3'b001; #1; check(1'b1, "BNE differ");
        rs1=32'd5; rs2=32'd5; f3=3'b001; #1; check(1'b0, "BNE equal->not taken");

        // signed corner: 0x80000000 (most negative) vs 0x7FFFFFFF (most positive)
        rs1=32'h8000_0000; rs2=32'h7FFF_FFFF; f3=3'b100; #1; check(1'b1, "BLT signed: MIN<MAX");
        rs1=32'h7FFF_FFFF; rs2=32'h8000_0000; f3=3'b100; #1; check(1'b0, "BLT signed: MAX<MIN false");
        rs1=32'h8000_0000; rs2=32'h7FFF_FFFF; f3=3'b101; #1; check(1'b0, "BGE signed: MIN>=MAX false");
        rs1=32'h7FFF_FFFF; rs2=32'h8000_0000; f3=3'b101; #1; check(1'b1, "BGE signed: MAX>=MIN true");

        // unsigned corner: same bit patterns, opposite conclusion
        rs1=32'h8000_0000; rs2=32'h7FFF_FFFF; f3=3'b110; #1; check(1'b0, "BLTU: big unsigned < small? false");
        rs1=32'h7FFF_FFFF; rs2=32'h8000_0000; f3=3'b110; #1; check(1'b1, "BLTU: small < big unsigned? true");
        rs1=32'h8000_0000; rs2=32'h7FFF_FFFF; f3=3'b111; #1; check(1'b1, "BGEU: big>=small true");
        rs1=32'h7FFF_FFFF; rs2=32'h8000_0000; f3=3'b111; #1; check(1'b0, "BGEU: small>=big false");

        // reserved funct3 (010/011) must default safely to not-taken
        rs1=32'hFFFF_FFFF; rs2=32'h0000_0000; f3=3'b010; #1; check(1'b0, "reserved funct3 010 -> not taken");
        rs1=32'hFFFF_FFFF; rs2=32'h0000_0000; f3=3'b011; #1; check(1'b0, "reserved funct3 011 -> not taken");

        // equal-value tests: confirms < is strict (not <=) and >= includes equal
        rs1=32'd7; rs2=32'd7; f3=3'b100; #1; check(1'b0, "BLT equal -> not taken");
        rs1=32'd7; rs2=32'd7; f3=3'b101; #1; check(1'b1, "BGE equal -> taken");
        rs1=32'd7; rs2=32'd7; f3=3'b110; #1; check(1'b0, "BLTU equal -> not taken");
        rs1=32'd7; rs2=32'd7; f3=3'b111; #1; check(1'b1, "BGEU equal -> taken");
        // zero vs zero
        rs1=32'd0; rs2=32'd0; f3=3'b000; #1; check(1'b1, "BEQ 0==0");
        rs1=32'd0; rs2=32'd0; f3=3'b001; #1; check(1'b0, "BNE 0==0 -> not taken");
        rs1=32'd0; rs2=32'd0; f3=3'b100; #1; check(1'b0, "BLT 0<0 -> not taken");
        rs1=32'd0; rs2=32'd0; f3=3'b101; #1; check(1'b1, "BGE 0>=0");
        rs1=32'd0; rs2=32'd0; f3=3'b110; #1; check(1'b0, "BLTU 0<0u -> not taken");
        rs1=32'd0; rs2=32'd0; f3=3'b111; #1; check(1'b1, "BGEU 0>=0u");

        $display("==== tb_branch_comparator: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_BRANCH_COMPARATOR: ALL TESTS PASSED");
        else $display("TB_BRANCH_COMPARATOR: FAILURES PRESENT");
        $finish;
    end
endmodule
