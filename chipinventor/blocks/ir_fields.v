// ============================================================================
// ir_fields.v - extracts the three register-address fields from the
// instruction register.
//
// This block exists only because the project canvas cannot slice a bus: every
// connection it generates is a whole bus of exactly matching width, so
// `ir[19:15]` cannot be drawn as a wire. Keeping the extraction here lets
// register_file.v stay byte-identical to the verified original rather than
// growing an instruction port and slicing internally.
// ============================================================================
module ir_fields (
    input  wire [31:0] ir,
    output wire [4:0]  rs1_addr,
    output wire [4:0]  rs2_addr,
    output wire [4:0]  rd_addr
);
    assign rs1_addr = ir[19:15];
    assign rs2_addr = ir[24:20];
    assign rd_addr  = ir[11:7];
endmodule
