`timescale 1ns/1ps
module tb_lsu;
    reg  [31:0] addr, rs2, mem_rd;
    reg  [2:0]  op_size;
    reg         is_store;
    wire [31:0] core_data_i, store_data_o;
    wire [3:0]  bw;
    integer pass, fail;

    lsu dut (
        .alu_result(addr), .rs2_data(rs2), .op_size(op_size), .is_valid_store(is_store),
        .mem_data_o(mem_rd), .core_data_i(core_data_i), .byte_write_o(bw), .store_data_o(store_data_o)
    );

    task check_load(input [31:0] exp, input [200:0] name);
        begin
            if (core_data_i === exp) pass = pass + 1;
            else begin fail=fail+1; $display("FAIL(load) %0s: got=%h exp=%h", name, core_data_i, exp); end
        end
    endtask
    task check_store(input [3:0] exp_bw, input [31:0] exp_data, input [200:0] name);
        begin
            if (bw === exp_bw && store_data_o === exp_data) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL(store) %0s: got bw=%b data=%h exp bw=%b data=%h",
                          name, bw, store_data_o, exp_bw, exp_data);
            end
        end
    endtask

    initial begin
        pass = 0; fail = 0;
        is_store = 0;

        // ---- Block Guide's own worked LOAD examples (§3.3.1), DMEM word
        // at 0x10010000 == 0xF4F3F2F1 (byte0=F1,byte1=F2,byte2=F3,byte3=F4) ----
        mem_rd = 32'hF4F3_F2F1;

        addr = 32'h1001_0000; op_size = 3'b100; #1; check_load(32'h0000_00F1, "LBU @0"); // lbu
        addr = 32'h1001_0000; op_size = 3'b000; #1; check_load(32'hFFFF_FFF1, "LB  @0"); // lb
        addr = 32'h1001_0000; op_size = 3'b101; #1; check_load(32'h0000_F2F1, "LHU @0"); // lhu
        addr = 32'h1001_0000; op_size = 3'b001; #1; check_load(32'hFFFF_F2F1, "LH  @0"); // lh
        addr = 32'h1001_0000; op_size = 3'b010; #1; check_load(32'hF4F3_F2F1, "LW  @0"); // lw
        addr = 32'h1001_0002; op_size = 3'b100; #1; check_load(32'h0000_00F3, "LBU @2"); // lbu
        addr = 32'h1001_0002; op_size = 3'b000; #1; check_load(32'hFFFF_FFF3, "LB  @2"); // lb

        // remaining byte offsets, unsigned + signed
        addr = 32'h1001_0001; op_size = 3'b100; #1; check_load(32'h0000_00F2, "LBU @1");
        addr = 32'h1001_0003; op_size = 3'b100; #1; check_load(32'h0000_00F4, "LBU @3");
        addr = 32'h1001_0003; op_size = 3'b000; #1; check_load(32'hFFFF_FFF4, "LB  @3 (F4 sign=1)");
        addr = 32'h1001_0002; op_size = 3'b101; #1; check_load(32'h0000_F4F3, "LHU @2");
        addr = 32'h1001_0002; op_size = 3'b001; #1; check_load(32'hFFFF_F4F3, "LH  @2 (F4 sign=1)");

        // misaligned half/word -> deterministic 0, not x / not partial garbage
        addr = 32'h1001_0001; op_size = 3'b001; #1; check_load(32'b0, "LH misaligned(offset1) -> 0");
        addr = 32'h1001_0003; op_size = 3'b001; #1; check_load(32'b0, "LH misaligned(offset3) -> 0");
        addr = 32'h1001_0001; op_size = 3'b010; #1; check_load(32'b0, "LW misaligned(offset1) -> 0");
        addr = 32'h1001_0002; op_size = 3'b010; #1; check_load(32'b0, "LW misaligned(offset2) -> 0");

        // ---- Block Guide's own worked STORE example (§3.3.2): storing
        // 0x12 to 0x10010002 -> byte lane 2, bw=0100, positioned 0x00120000 ----
        is_store = 1;
        addr = 32'h1001_0002; op_size = 3'b000; rs2 = 32'h0000_0012;
        #1; check_store(4'b0100, 32'h0012_0000, "SB @2 (Block Guide worked example)");

        // full byte alignment sweep
        rs2 = 32'h0000_00AB;
        addr = 32'h1001_0000; op_size = 3'b000; #1; check_store(4'b0001, 32'h0000_00AB, "SB @0");
        addr = 32'h1001_0001; op_size = 3'b000; #1; check_store(4'b0010, 32'h0000_AB00, "SB @1");
        addr = 32'h1001_0003; op_size = 3'b000; #1; check_store(4'b1000, 32'hAB00_0000, "SB @3");

        // half alignment sweep
        rs2 = 32'h0000_ABCD;
        addr = 32'h1001_0000; op_size = 3'b001; #1; check_store(4'b0011, 32'h0000_ABCD, "SH @0");
        addr = 32'h1001_0002; op_size = 3'b001; #1; check_store(4'b1100, 32'hABCD_0000, "SH @2");
        addr = 32'h1001_0001; op_size = 3'b001; #1; check_store(4'b0000, 32'b0, "SH misaligned(offset1) -> no write");

        // word
        rs2 = 32'hCAFE_BABE;
        addr = 32'h1001_0000; op_size = 3'b010; #1; check_store(4'b1111, 32'hCAFE_BABE, "SW @0");
        addr = 32'h1001_0001; op_size = 3'b010; #1; check_store(4'b0000, 32'b0, "SW misaligned -> no write");

        // is_valid_store gating: even a byte-aligned access must produce
        // bw=0000 when is_valid_store is deasserted (e.g. current instr is
        // a load, illegal, or anything else)
        is_store = 0;
        addr = 32'h1001_0000; op_size = 3'b000; rs2=32'hFF; #1;
        check_store(4'b0000, 32'b0, "is_valid_store=0 forces bw=0000 regardless of address");

        $display("==== tb_lsu: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_LSU: ALL TESTS PASSED");
        else $display("TB_LSU: FAILURES PRESENT");
        $finish;
    end
endmodule
