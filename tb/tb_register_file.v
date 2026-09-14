`timescale 1ns/1ps
module tb_register_file;
    reg         clk, rst;
    reg  [4:0]  rs1_addr, rs2_addr, rd_addr;
    reg  [31:0] rd_data;
    reg         reg_write;
    wire [31:0] rs1_data, rs2_data;
    integer pass, fail;

    register_file dut (
        .clk_i(clk), .rst_i(rst),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr),
        .rd_data(rd_data), .reg_write(reg_write),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    always #5 clk = ~clk;

    task check32(input [31:0] got, input [31:0] exp, input [200:0] name);
        begin
            if (got === exp) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL %0s: got=%h exp=%h", name, got, exp); end
        end
    endtask

    integer i;
    initial begin
        clk = 0; rst = 1; reg_write = 0; rd_addr=0; rd_data=0; rs1_addr=0; rs2_addr=0;
        pass = 0; fail = 0;
        @(posedge clk); @(posedge clk); // hold reset >= 2 cycles (§18.5 recommendation)
        rst = 0;

        // x0 must read 0 even if a write to x0 is attempted
        rd_addr = 5'd0; rd_data = 32'hDEAD_BEEF; reg_write = 1;
        @(posedge clk); #1;
        rs1_addr = 5'd0; #1; check32(rs1_data, 32'b0, "x0 write-guard: still reads 0");
        reg_write = 0;

        // write x5 = 0x12345678, then read it back via both ports
        rd_addr = 5'd5; rd_data = 32'h1234_5678; reg_write = 1;
        @(posedge clk); #1;
        reg_write = 0;
        rs1_addr = 5'd5; rs2_addr = 5'd5; #1;
        check32(rs1_data, 32'h1234_5678, "x5 round-trip rs1 port");
        check32(rs2_data, 32'h1234_5678, "x5 round-trip rs2 port");

        // every other register round-trips independently
        for (i = 1; i < 32; i = i + 1) begin
            rd_addr = i[4:0]; rd_data = {i[4:0], i[4:0], i[4:0], i[4:0], i[4:0], i[4:0], 2'b00};
            reg_write = 1;
            @(posedge clk); #1;
            reg_write = 0;
        end
        for (i = 1; i < 32; i = i + 1) begin
            rs1_addr = i[4:0]; #1;
            check32(rs1_data, {i[4:0], i[4:0], i[4:0], i[4:0], i[4:0], i[4:0], 2'b00},
                    "all-register sweep round-trip");
        end

        // reset clears everything back to 0
        rst = 1; @(posedge clk); #1; rst = 0;
        rs1_addr = 5'd5; #1; check32(rs1_data, 32'b0, "reset clears x5");

        // reg_write de-asserted must not write
        rd_addr = 5'd7; rd_data = 32'hFFFF_FFFF; reg_write = 0;
        @(posedge clk); #1;
        rs1_addr = 5'd7; #1; check32(rs1_data, 32'b0, "reg_write=0 -> no write occurs");

        $display("==== tb_register_file: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_REGISTER_FILE: ALL TESTS PASSED");
        else $display("TB_REGISTER_FILE: FAILURES PRESENT");
        $finish;
    end
endmodule
