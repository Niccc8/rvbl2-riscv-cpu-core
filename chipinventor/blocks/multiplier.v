// ============================================================================
// multiplier.v - MUL/MULH/MULHSU/MULHU (Zmmul). Combinational, single
// Execute cycle. funct3 directly drives operand-signedness
// and result-half selection per Table 10:
//
//   funct3   op       A signed   B signed   result
//   000      MUL      yes        yes        product[31:0]
//   001      MULH     yes        yes        product[63:32]
//   010      MULHSU   yes        no         product[63:32]
//   011      MULHU    no         no         product[63:32]
//
// NOTE: result_sel_upper must be (funct3[1] | funct3[0]), NOT funct3[0]
// alone -- funct3[0] alone is wrong specifically for MULHSU (funct3=010),
// where it evaluates to 0 (lower half) instead of the correct 1 (upper
// half).
// ============================================================================
module multiplier (
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [2:0]  funct3,
    output reg  [31:0] result
);
    wire a_signed    = ~(funct3[1] & funct3[0]); // 0 only for MULHU (011)
    wire b_signed    = ~funct3[1];               // 1 only for MUL/MULH (00x)
    wire sel_upper   = funct3[1] | funct3[0];    // 0 only for MUL (000)

    wire [63:0] a_ext = a_signed ? {{32{rs1_data[31]}}, rs1_data} : {32'b0, rs1_data};
    wire [63:0] b_ext = b_signed ? {{32{rs2_data[31]}}, rs2_data} : {32'b0, rs2_data};

    // Widen the assignment context to 128 bits so Icarus/Yosys evaluate the
    // multiply at full precision rather than truncating at 64 bits before
    // the low-64 slice is taken (standard Verilog context-width practice).
    wire [127:0] product_full = a_ext * b_ext;
    wire [63:0]  product      = product_full[63:0];

    always @(*) begin
        result = sel_upper ? product[63:32] : product[31:0];
    end
endmodule
