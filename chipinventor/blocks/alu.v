// ============================================================================
// alu.v - Arithmetic/Logic Unit
// Implements Block Guide Table 9 (11 ops). Shared by ALU-reg, ALU-imm,
// LUI (PASS_B), AUIPC/branch-target/jump-target/load-store address (ADD).
// Purely combinational.
// ============================================================================
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result
);
    localparam [3:0]
        ALU_PASS_B = 4'h0,
        ALU_ADD    = 4'h1,
        ALU_SUB    = 4'h2,
        ALU_AND    = 4'h3,
        ALU_OR     = 4'h4,
        ALU_XOR    = 4'h5,
        ALU_SLL    = 4'h6,
        ALU_SRL    = 4'h7,
        ALU_SRA    = 4'h8, // "MRS" in Block Guide Table 9
        ALU_SLT    = 4'h9,
        ALU_SLTU   = 4'hA;

    always @(*) begin
        case (alu_op)
            ALU_PASS_B: result = b;
            ALU_ADD:    result = a + b;
            ALU_SUB:    result = a - b;
            ALU_AND:    result = a & b;
            ALU_OR:     result = a | b;
            ALU_XOR:    result = a ^ b;
            ALU_SLL:    result = a << b[4:0];
            ALU_SRL:    result = a >> b[4:0];
            ALU_SRA:    result = $signed(a) >>> b[4:0];
            ALU_SLT:    result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU:   result = (a < b) ? 32'd1 : 32'd0;
            default:    result = 32'd0; // safe default, no latch
        endcase
    end
endmodule
