`timescale 1ns/1ps
module tb_alu;
    reg  [31:0] a, b;
    reg  [3:0]  op;
    wire [31:0] result;
    integer pass, fail;

    alu dut (.a(a), .b(b), .alu_op(op), .result(result));

    task check(input [31:0] exp, input [200:0] name);
        begin
            if (result === exp) begin
                pass = pass + 1;
            end else begin
                fail = fail + 1;
                $display("FAIL %0s: a=%h b=%h op=%h -> got=%h exp=%h", name, a, b, op, result, exp);
            end
        end
    endtask

    initial begin
        pass = 0; fail = 0;

        // PASS_B / LUI use
        a=32'h1111_1111; b=32'h789A_BCDE; op=4'h0; #1; check(b, "PASS_B");

        // ADD
        a=32'd10; b=32'd20; op=4'h1; #1; check(32'd30, "ADD basic");
        a=32'hFFFF_FFFF; b=32'd1; op=4'h1; #1; check(32'd0, "ADD overflow wrap");

        // SUB
        a=32'd5; b=32'd8; op=4'h2; #1; check(-32'd3, "SUB negative result");
        a=32'h8000_0000; b=32'h1; op=4'h2; #1; check(32'h7FFF_FFFF, "SUB INT_MIN-1 wrap");

        // AND/OR/XOR
        a=32'hFF00_FF00; b=32'h0FF0_0FF0; op=4'h3; #1; check(32'h0F00_0F00, "AND");
        a=32'hFF00_FF00; b=32'h00FF_00FF; op=4'h4; #1; check(32'hFFFF_FFFF, "OR");
        a=32'hAAAA_AAAA; b=32'hFFFF_FFFF; op=4'h5; #1; check(32'h5555_5555, "XOR");

        // SLL / SRL / SRA (shift masked to b[4:0])
        a=32'h0000_0001; b=32'd31; op=4'h6; #1; check(32'h8000_0000, "SLL by 31");
        a=32'h0000_0001; b=32'd32; op=4'h6; #1; check(32'h0000_0001, "SLL masked shamt(32->0)");
        a=32'h8000_0000; b=32'd4;  op=4'h7; #1; check(32'h0800_0000, "SRL logical, MSB=1");
        a=32'h8000_0000; b=32'd4;  op=4'h8; #1; check(32'hF800_0000, "SRA arithmetic, sign-extends");
        a=32'h7FFF_FFFF; b=32'd31; op=4'h8; #1; check(32'h0000_0000, "SRA positive shifts to 0");
        a=32'hFFFF_FFFF; b=32'd31; op=4'h8; #1; check(32'hFFFF_FFFF, "SRA -1 stays -1");

        // SLT / SLTU corners
        a=32'h8000_0000; b=32'h7FFF_FFFF; op=4'h9; #1; check(32'd1, "SLT: INT_MIN < INT_MAX (signed)");
        a=32'h8000_0000; b=32'h7FFF_FFFF; op=4'hA; #1; check(32'd0, "SLTU: INT_MIN(unsigned big) < INT_MAX? no");
        a=32'd0; b=32'd0; op=4'h9; #1; check(32'd0, "SLT equal -> 0");
        a=32'hFFFF_FFFF; b=32'd0; op=4'h9; #1; check(32'd1, "SLT: -1 < 0 signed");
        a=32'hFFFF_FFFF; b=32'd0; op=4'hA; #1; check(32'd0, "SLTU: 0xFFFFFFFF < 0 unsigned? no");

        // default branch (safety)
        a=32'hDEAD_BEEF; b=32'hCAFE_BABE; op=4'hF; #1; check(32'd0, "reserved opcode -> defined 0, no latch");

        // ---- Additional corner cases ----
        a=32'd0; b=32'd0; op=4'h1; #1; check(32'd0, "ADD 0+0");
        a=32'hFFFF_FFFF; b=32'hFFFF_FFFF; op=4'h1; #1; check(32'hFFFF_FFFE, "ADD -1+-1 wraps");
        a=32'd5; b=32'd5; op=4'h2; #1; check(32'd0, "SUB equal -> 0");
        a=32'd1; b=32'd0; op=4'h6; #1; check(32'd1, "SLL by 0 -> unchanged");
        a=32'h8000_0000; b=32'd0; op=4'h7; #1; check(32'h8000_0000, "SRL by 0 -> unchanged");
        a=32'h8000_0000; b=32'd0; op=4'h8; #1; check(32'h8000_0000, "SRA by 0 -> unchanged");
        a=32'd5; b=32'd5; op=4'h9; #1; check(32'd0, "SLT equal -> 0");
        a=32'd5; b=32'd5; op=4'hA; #1; check(32'd0, "SLTU equal -> 0");

        // ---- Randomized sweep, all 11 ALU ops ----
        begin : random_sweep
            integer i;
            for (i = 0; i < 100; i = i + 1) begin
                a = $random; b = $random;
                op=4'h0; #1; check(b, "PASS_B random");
                op=4'h1; #1; check(a + b, "ADD random");
                op=4'h2; #1; check(a - b, "SUB random");
                op=4'h3; #1; check(a & b, "AND random");
                op=4'h4; #1; check(a | b, "OR random");
                op=4'h5; #1; check(a ^ b, "XOR random");
                op=4'h6; #1; check(a << b[4:0], "SLL random");
                op=4'h7; #1; check(a >> b[4:0], "SRL random");
                op=4'h8; #1; check($signed(a) >>> b[4:0], "SRA random");
                op=4'h9; #1; check(($signed(a) < $signed(b)) ? 32'd1 : 32'd0, "SLT random");
                op=4'hA; #1; check((a < b) ? 32'd1 : 32'd0, "SLTU random");
            end
        end

        $display("==== tb_alu: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_ALU: ALL TESTS PASSED");
        else $display("TB_ALU: FAILURES PRESENT");
        $finish;
    end
endmodule
