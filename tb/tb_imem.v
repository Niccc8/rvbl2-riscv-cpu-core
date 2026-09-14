`timescale 1ns/1ps
module tb_imem;
    reg  [31:0] addr;
    reg         oe;
    wire [31:0] data;
    integer pass, fail;

    localparam WORDS = 64;
    // INIT_FILE("") keeps this unit test independent of any firmware image;
    // the ROM contents it checks are written directly below.
    imem #(.IMEM_WORDS(WORDS), .INIT_FILE("")) dut (.address_i(addr), .oe_i(oe), .data_o(data));

    task check(input [31:0] exp, input [200:0] name);
        begin
            if (data === exp) pass = pass + 1;
            else begin fail=fail+1; $display("FAIL %0s: addr=%h got=%h exp=%h", name, addr, data, exp); end
        end
    endtask

    initial begin
        pass = 0; fail = 0;

        // preload a couple of known words directly via hierarchical access
        // (this is exactly the kind of internal-state introspection the
        // "no observable I/O" verification approach relies on, §14.1).
        // The #1 lands past time 0 so these writes cannot race the DUT's own
        // initial zero-fill, whose relative ordering Verilog does not define.
        #1;
        dut.rom[0] = 32'hAAAA_BBBB;
        dut.rom[1] = 32'h1111_2222;
        dut.rom[WORDS-1] = 32'hCAFE_F00D;

        oe = 1;
        addr = 32'h0040_0000; #1; check(32'hAAAA_BBBB, "word 0");
        addr = 32'h0040_0004; #1; check(32'h1111_2222, "word 1");
        addr = 32'h0040_0000 + (WORDS-1)*4; #1; check(32'hCAFE_F00D, "last implemented word");

        // oe_i=0 must read 0 (defined, not x)
        oe = 0; addr = 32'h0040_0000; #1; check(32'b0, "oe=0 -> 0");

        // beyond the implemented array but still inside the 4MB
        // architectural window must read back 0, NOT alias to a real word
        // (this is exactly the §9.12 v4 aliasing-prevention fix)
        oe = 1;
        addr = 32'h0040_0000 + WORDS*4; #1;
        check(32'b0, "just past IMEM_WORDS, still in window -> 0 (no aliasing)");

        addr = 32'h0040_0000 + WORDS*4 + 128; #1;
        check(32'b0, "further past IMEM_WORDS -> 0 (no aliasing)");

        // a genuinely out-of-range access wouldn't even reach oe_i=1 in a
        // real system (address_decoder gates that), but confirm imem alone
        // does not misbehave if given oe=1 at a huge offset
        addr = 32'h0040_0000 + 32'h003F_FFFC; #1; // near top of the 4MB window
        check(32'b0, "near top of 4MB window, beyond implemented image -> 0");

        $display("==== tb_imem: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_IMEM: ALL TESTS PASSED");
        else $display("TB_IMEM: FAILURES PRESENT");
        $finish;
    end
endmodule
