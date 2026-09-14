`timescale 1ns/1ps
module tb_crc_unit;
    reg  [31:0] rs1, rs2;
    reg  [2:0]  f3;
    wire [31:0] result;
    integer pass, fail;

    crc_unit dut (.rs1_data(rs1), .rs2_data(rs2), .funct3(f3), .result(result));

    integer fd, code, exp_f3;
    reg [31:0] exp_seed, exp_data, exp_result;

    initial begin
        pass = 0; fail = 0;

        fd = $fopen("tests/golden/crc_vectors.txt", "r");
        if (fd == 0) begin
            $display("FATAL: could not open tests/golden/crc_vectors.txt");
            $finish;
        end
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%d %h %h %h\n", exp_f3, exp_seed, exp_data, exp_result);
            if (code == 4) begin
                f3  = exp_f3[2:0];
                // rs1 = data, rs2 = running CRC. The vector file records
                // (seed, data) -> result; only which port carries which
                // moved, so the vectors themselves are unchanged.
                rs1 = exp_data;
                rs2 = exp_seed;
                #1;
                if (result === exp_result) pass = pass + 1;
                else begin
                    fail = fail + 1;
                    $display("FAIL f3=%0d seed=%h data=%h -> got=%h exp=%h",
                              exp_f3, exp_seed, exp_data, result, exp_result);
                end
            end
        end
        $fclose(fd);

        // Explicit standard check-value test, chained CRCB across "123456789",
        // reproduced directly in the testbench (not just via the vector file)
        // as the hard pass/fail gate the spec calls for (§13.5).
        begin : check_value_test
            reg [15:0] seed;
            reg [7:0]  msg [0:8];
            integer k;
            msg[0]=8'h31; msg[1]=8'h32; msg[2]=8'h33; msg[3]=8'h34; msg[4]=8'h35;
            msg[5]=8'h36; msg[6]=8'h37; msg[7]=8'h38; msg[8]=8'h39; // "123456789"
            seed = 16'hFFFF;
            f3 = 3'b000; // CRCB
            for (k = 0; k < 9; k = k + 1) begin
                rs1 = {24'b0, msg[k]};   // data
                rs2 = {16'b0, seed};     // running CRC
                #1;
                seed = result[15:0];
            end
            if (seed === 16'h29B1) begin
                pass = pass + 1;
                $display("CHECK-VALUE GATE: chained CRCB('123456789') = 0x%h (expected 0x29B1) -- PASS", seed);
            end else begin
                fail = fail + 1;
                $display("CHECK-VALUE GATE FAILED: got 0x%h, expected 0x29B1", seed);
            end
        end

        // Competition anchor: the exact three chains _rvbl2_crc_test runs, each
        // of which the official validation firmware compares against 0x1E82.
        // This is the check that pins the rs1/rs2 operand roles - the algorithm
        // was always right, the operand order was not, and only a test written
        // against the firmware's own expected value catches that.
        begin : firmware_anchor
            reg [15:0] c;
            reg [7:0]  b [0:7];
            reg [15:0] h [0:3];
            reg [31:0] w [0:1];
            integer k;
            b[0]=8'h12; b[1]=8'h34; b[2]=8'h56; b[3]=8'h78;
            b[4]=8'h90; b[5]=8'hAB; b[6]=8'hCD; b[7]=8'hEF;
            h[0]=16'h1234; h[1]=16'h5678; h[2]=16'h90AB; h[3]=16'hCDEF;
            w[0]=32'h12345678; w[1]=32'h90ABCDEF;

            c = 16'hFFFF; f3 = 3'b000;
            for (k = 0; k < 8; k = k + 1) begin
                rs1 = {24'b0, b[k]}; rs2 = {16'b0, c}; #1; c = result[15:0];
            end
            if (c === 16'h1E82) pass = pass + 1;
            else begin fail = fail + 1;
                $display("FIRMWARE ANCHOR FAILED: 8x CRCB = 0x%h, firmware expects 0x1E82", c); end

            c = 16'hFFFF; f3 = 3'b001;
            for (k = 0; k < 4; k = k + 1) begin
                rs1 = {16'b0, h[k]}; rs2 = {16'b0, c}; #1; c = result[15:0];
            end
            if (c === 16'h1E82) pass = pass + 1;
            else begin fail = fail + 1;
                $display("FIRMWARE ANCHOR FAILED: 4x CRCH = 0x%h, firmware expects 0x1E82", c); end

            c = 16'hFFFF; f3 = 3'b010;
            for (k = 0; k < 2; k = k + 1) begin
                rs1 = w[k]; rs2 = {16'b0, c}; #1; c = result[15:0];
            end
            if (c === 16'h1E82) pass = pass + 1;
            else begin fail = fail + 1;
                $display("FIRMWARE ANCHOR FAILED: 2x CRCW = 0x%h, firmware expects 0x1E82", c); end
        end

        $display("==== tb_crc_unit: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_CRC_UNIT: ALL TESTS PASSED");
        else $display("TB_CRC_UNIT: FAILURES PRESENT");
        $finish;
    end
endmodule
