// ============================================================================
// imem_mock.v - the three-instruction ROM for the OpenLane / P&R run.
//
// The full ROM is 742 words; this is 3. Nothing else in the design changes,
// and the port list is identical to imem.v, so this is a drop-in swap of one
// block's Code field with no rewiring on the canvas.
//
// The program is theirs, unmodified:
//
//     addi x5, x0, 10        x5 = 10
//     addi x6, x0, 5         x6 = 5
//     add  x7, x5, x6        x7 = 15
//
// DIFFERENCES FROM THEIR SNIPPET, AND WHY
// ---------------------------------------
// Their snippet decodes the full 32-bit byte address and has no output-enable.
// This one keeps imem.v's word indexing and oe_i gating instead, because those
// are what address_decoder's contract is built on - a mock that answered on a
// different interface would not be exercising the design that gets taped out.
// The instruction words and the NOP default are exactly theirs.
//
// The NOP default (rather than imem.v's 32'h0) is deliberate and is also
// theirs: after the third instruction the core simply retires NOPs forever,
// which is the well-defined idle behaviour you want driving a synthesis run.
// ============================================================================
module imem (
    input  wire [31:0] address_i,    // full byte address (already imem_sel-gated by decoder)
    input  wire        oe_i,
    output reg  [31:0] data_o
);
    // Word index within the 4MB architectural window, identical to imem.v.
    wire [19:0] word_addr = address_i[21:2];

    always @(*) begin
        if (!oe_i) data_o = 32'b0;
        else begin
            case (word_addr)
                20'd0     : data_o = 32'h00a00293; // addi x5, x0, 10
                20'd1     : data_o = 32'h00500313; // addi x6, x0, 5
                20'd2     : data_o = 32'h006283b3; // add  x7, x5, x6
                default   : data_o = 32'h00000013; // nop
            endcase
        end
    end
endmodule
