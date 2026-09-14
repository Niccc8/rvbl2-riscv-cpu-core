// ============================================================================
// branch_comparator.v - evaluates the 6 RV32I branch conditions.
// Purely combinational, kept separate from the ALU (§6.2, §9.6).
// ============================================================================
module branch_comparator (
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [2:0]  funct3,
    output reg         branch_taken
);
    always @(*) begin
        case (funct3)
            3'b000: branch_taken = (rs1_data == rs2_data);                       // BEQ
            3'b001: branch_taken = (rs1_data != rs2_data);                       // BNE
            3'b100: branch_taken = ($signed(rs1_data) <  $signed(rs2_data));     // BLT
            3'b101: branch_taken = ($signed(rs1_data) >= $signed(rs2_data));     // BGE
            3'b110: branch_taken = (rs1_data <  rs2_data);                       // BLTU
            3'b111: branch_taken = (rs1_data >= rs2_data);                       // BGEU
            default: branch_taken = 1'b0; // funct3 010/011 unused by RV32I branches
        endcase
    end
endmodule
