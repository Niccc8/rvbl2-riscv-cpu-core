`timescale 1ns/1ps
// tb_address_decoder.v - window boundaries, strobe qualification and
// aliasing prevention for IMEM, DMEM and (Stage 3) the peripheral region
// 0xF0000000-0xFFFFFFFF.
module tb_address_decoder;
    reg  [31:0] addr;
    reg         we, oe;
    reg  [3:0]  bw;
    reg  [31:0] imem_rd, dmem_rd, periph_rd;
    wire        imem_oe, dmem_we, dmem_oe, periph_we;
    wire [3:0]  dmem_bw, periph_bw;
    wire [31:0] periph_chain, data_o;
    integer pass, fail, i;
    reg [31:0] r;

    address_decoder dut (
        .address_i(addr), .we_i(we), .oe_i(oe), .bw_i(bw),
        .imem_rdata(imem_rd), .dmem_rdata(dmem_rd), .periph_rdata_i(periph_rd),
        .imem_oe_o(imem_oe), .dmem_we_o(dmem_we), .dmem_oe_o(dmem_oe), .dmem_bw_o(dmem_bw),
        .periph_we_o(periph_we), .periph_bw_o(periph_bw), .periph_chain_o(periph_chain),
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

    task check_periph(input exp_we, input [3:0] exp_bw, input [200:0] name);
        begin
            if (periph_we===exp_we && periph_bw===exp_bw && periph_chain===32'b0)
                pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL %0s: periph_we=%b(exp %b) periph_bw=%b(exp %b) chain=%h(exp 0)",
                    name, periph_we, exp_we, periph_bw, exp_bw, periph_chain);
            end
        end
    endtask

    initial begin
        pass = 0; fail = 0;
        imem_rd = 32'hAAAA_AAAA; dmem_rd = 32'hBBBB_BBBB; periph_rd = 32'hCCCC_CCCC;

        // ---------------- Phase 2 checks, unchanged in intent ----------------
        // IMEM window boundaries: base=0x00400000, last=0x007FFFFF
        we=0; oe=1; bw=4'b0000;
        addr = 32'h0040_0000; #1; check(1,0,0,4'b0000, 32'hAAAA_AAAA, "IMEM base");
        addr = 32'h007F_FFFF; #1; check(1,0,0,4'b0000, 32'hAAAA_AAAA, "IMEM last byte");
        addr = 32'h0040_0000 - 1; #1; check(0,0,0,4'b0000, 32'b0, "just below IMEM base -> unmapped");
        addr = 32'h007F_FFFF + 1; #1; check(0,0,0,4'b0000, 32'b0, "just above IMEM last -> unmapped");

        // DMEM window boundaries: base=0x10010000, last=0x10011FFF
        addr = 32'h1001_0000; #1; check(0,0,1,4'b0000, 32'hBBBB_BBBB, "DMEM base");
        addr = 32'h1001_1FFF; #1; check(0,0,1,4'b0000, 32'hBBBB_BBBB, "DMEM last byte");
        addr = 32'h1001_0000 - 1; #1; check(0,0,0,4'b0000, 32'b0, "just below DMEM base -> unmapped");
        addr = 32'h1001_1FFF + 1; #1; check(0,0,0,4'b0000, 32'b0, "just above DMEM last -> unmapped");

        // DMEM write routing in range
        we=1; oe=0; bw=4'b1111;
        addr = 32'h1001_0010; #1; check(0,1,0,4'b1111, 32'hBBBB_BBBB, "DMEM write in-range: we/bw routed through");
        check_periph(0, 4'b0000, "DMEM write must not strobe the peripherals");

        // Aliasing prevention: an out-of-range store asserts no strobe at all.
        addr = 32'hDEAD_0000; #1;
        check(0,0,0,4'b0000, 32'b0, "OUT-OF-RANGE STORE must assert zero dmem_we/bw (no aliasing)");
        check_periph(0, 4'b0000, "OUT-OF-RANGE STORE must assert zero periph_we/bw");
        addr = 32'h0000_0000; #1;
        check(0,0,0,4'b0000, 32'b0, "OUT-OF-RANGE STORE at address 0 -> zero dmem_we/bw");

        // An unmapped read asserts nothing and reads 0. (Phase 2 used
        // 0xFFFFFFFF here; that address is now in the peripheral region.)
        we=0; oe=1; bw=4'b0000;
        addr = 32'hE000_0000; #1;
        check(0,0,0,4'b0000, 32'b0, "unmapped read -> data_o=0, no memory oe asserted");

        // ---------------- Stage 3: peripheral region -------------------------
        addr = 32'hEFFF_FFFF; #1; check(0,0,0,4'b0000, 32'b0, "just below peripheral region -> unmapped");
        addr = 32'hF000_0000; #1; check(0,0,0,4'b0000, 32'hCCCC_CCCC, "GPIO base -> peripheral chain data");
        addr = 32'hF100_0008; #1; check(0,0,0,4'b0000, 32'hCCCC_CCCC, "UART CONTROL -> peripheral chain data");
        addr = 32'hFFFF_FFFF; #1; check(0,0,0,4'b0000, 32'hCCCC_CCCC, "region top -> peripheral chain data");

        we=1; oe=0; bw=4'b0001;
        addr = 32'hF100_0008; #1;
        check(0,0,0,4'b0000, 32'hCCCC_CCCC, "peripheral store must not strobe DMEM");
        check_periph(1, 4'b0001, "peripheral store: we/bw routed through");
        addr = 32'hEFFF_FFFC; bw=4'b1111; #1;
        check_periph(0, 4'b0000, "store just below the region: no peripheral strobe");

        // Random sweep: outside 0xF..., the peripheral strobes are never set
        // and the peripheral data never leaks onto data_o.
        we=1; oe=1; bw=4'b1111;
        for (i = 0; i < 2000; i = i + 1) begin
            r = $random;
            addr = (r[31:28] == 4'hF) ? {4'hE, r[27:0]} : r;   // anywhere but 0xF...
            #1;
            if (periph_we===1'b0 && periph_bw===4'b0000 && data_o!==32'hCCCC_CCCC) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL sweep addr=%h periph_we=%b periph_bw=%b data=%h", addr, periph_we, periph_bw, data_o);
            end
        end

        $display("==== tb_address_decoder: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_ADDRESS_DECODER: ALL TESTS PASSED");
        else $display("TB_ADDRESS_DECODER: FAILURES PRESENT");
        $finish;
    end
endmodule
