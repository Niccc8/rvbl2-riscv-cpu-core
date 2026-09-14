// ============================================================================
// mux2_32.v - generic 2-to-1 32-bit multiplexer.
//
// The project canvas holds no logic of its own: every wire drawn on it is a
// whole-bus point-to-point connection, so a selection that used to be a single
// `assign x = s ? a : b;` inside riscv_core.v has to exist as a real block.
// Four instances cover every such selection in the datapath:
//
//   alu_a     S=alu_src_a_sel   A=rs1_data    B=pc
//   alu_b     S=alu_src_b_sel   A=rs2_data    B=imm
//   address   S=addr_src_sel    A=pc          B=alu_result
//   pc_next   S=pc_src_sel      A=pc_plus_4   B=alu_result
//
// Polarity matters when wiring: S=0 selects A, S=1 selects B. Every control
// signal above is named for the thing it selects when asserted, so the
// asserted case is always the B leg.
// ============================================================================
module mux2_32 (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        s,
    output wire [31:0] z
);
    assign z = s ? b : a;
endmodule
