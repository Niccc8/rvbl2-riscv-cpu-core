`timescale 1ns/1ps
module tb_address_decoder;
    reg  [31:0] addr;
    reg         we, oe;
    reg  [3:0]  bw;
    reg  [31:0] imem_rd, dmem_rd;
    wire        imem_oe, dmem_we, dmem_oe;
    wire [3:0]  dmem_bw;
    wire [31:0] data_o;
    integer pass, fail;

    address_decoder dut (
        .address_i(addr), .we_i(we), .oe_i(oe), .bw_i(bw),
        .imem_rdata(imem_rd), .dmem_rdata(dmem_rd),
        .imem_oe_o(imem_oe), .dmem_we_o(dmem_we), .dmem_oe_o(dmem_oe), .dmem_bw_o(dmem_bw),
        .data_o(data_o)
    );

    task check(input exp_imem_oe, input exp_dmem_we, input exp_dmem_oe, input [3:0] exp_bw,
               input [31:0] exp_data, input [200:0] name);
        begin
            if (imem_oe===exp_imem_oe && dmem_we===exp_dmem_we && dmem_oe===exp_dmem_oe &&
                dmem_bw===exp_bw && data_o===exp_data)
                pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL %0s: imem_oe=%b(exp %b) dmem_we=%b(exp %b) dmem_oe=%b(exp %b) bw=%b(exp %b) data=%h(exp %h)",
                    name, imem_oe, exp_imem_oe, dmem_we, exp_dmem_we, dmem_oe, exp_dmem_oe,
                    dmem_bw, exp_bw, data_o, exp_data);
            end
        end
    endtask

    initial begin
        pass = 0; fail = 0;
        imem_rd = 32'hAAAA_AAAA; dmem_rd = 32'hBBBB_BBBB;

        // IMEM window boundaries: base=0x00400000, last=0x007FFFFF
        we=0; oe=1; bw=4'b0000;
        addr = 32'h0040_0000; #1; check(1,0,0,4'b0000, 32'hAAAA_AAAA, "IMEM base");
        addr = 32'h007F_FFFF; #1; check(1,0,0,4'b0000, 32'hAAAA_AAAA, "IMEM last byte");
        addr = 32'h0040_0000 - 1; #1; check(0,0,0,4'b0000, 32'b0, "just below IMEM base -> unmapped");
        addr = 32'h007F_FFFF + 1; #1; check(0,0,0,4'b0000, 32'b0, "just above IMEM last -> unmapped");

        // DMEM window boundaries: base=0x10010000, last=0x10011FFF
        we=0; oe=1; bw=4'b0000;
        addr = 32'h1001_0000; #1; check(0,0,1,4'b0000, 32'hBBBB_BBBB, "DMEM base");
        addr = 32'h1001_1FFF; #1; check(0,0,1,4'b0000, 32'hBBBB_BBBB, "DMEM last byte");
        addr = 32'h1001_0000 - 1; #1; check(0,0,0,4'b0000, 32'b0, "just below DMEM base -> unmapped");
        addr = 32'h1001_1FFF + 1; #1; check(0,0,0,4'b0000, 32'b0, "just above DMEM last -> unmapped");

        // we_i must never reach imem_oe_o's counterpart (IMEM has no write
        // port at all); check DMEM write routing when in-range
        we=1; oe=0; bw=4'b1111;
        addr = 32'h1001_0010; #1; check(0,1,0,4'b1111, 32'hBBBB_BBBB, "DMEM write in-range: we/bw routed through");

        // *** Critical aliasing-prevention check (§9.14 v4 / risk R20) ***
        // A store whose address falls OUTSIDE both windows must produce
        // ZERO dmem_we/dmem_bw - not just an unread result. A decoder that
        // forgot the explicit "& dmem_sel" qualifier would still assert
        // dmem_we_o here, silently corrupting DMEM at whatever address its
        // own internal low-bit decode derives from this out-of-range value.
        we=1; oe=0; bw=4'b1111;
        addr = 32'hDEAD_0000; #1;
        check(0,0,0,4'b0000, 32'b0, "OUT-OF-RANGE STORE must assert zero dmem_we/bw (no aliasing)");

        addr = 32'h0000_0000; #1; // address 0 (typical stray/uninitialized pointer)
        check(0,0,0,4'b0000, 32'b0, "OUT-OF-RANGE STORE at address 0 -> zero dmem_we/bw");

        // an out-of-range READ (oe only) must also assert nothing and read 0
        we=0; oe=1; bw=4'b0000;
        addr = 32'hFFFF_FFFF; #1;
        check(0,0,0,4'b0000, 32'b0, "out-of-range read -> data_o=0, no memory oe asserted");

        $display("==== tb_address_decoder: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_ADDRESS_DECODER: ALL TESTS PASSED");
        else $display("TB_ADDRESS_DECODER: FAILURES PRESENT");
        $finish;
    end
endmodule
