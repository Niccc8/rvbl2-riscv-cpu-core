// ============================================================================
// pc_reg.v - program counter. Reset vector = IMEM base (0x00400000).
// Bits [1:0] forced to 0 on every load (covers JALR's
// "clear LSB" requirement and keeps PC always word-aligned, matching
// IMEM's word-only addressing).
// ============================================================================
module pc_reg (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        pc_write,
    input  wire [31:0] pc_next,
    // (* keep *) - see dmem.v for why this is needed (zero-output top level).
    (* keep *) output reg  [31:0] pc
);
    localparam [31:0] RESET_VECTOR = 32'h0040_0000;

    always @(posedge clk_i) begin
        if (rst_i)
            pc <= RESET_VECTOR;
        else if (pc_write)
            pc <= {pc_next[31:2], 2'b00};
    end
endmodule
