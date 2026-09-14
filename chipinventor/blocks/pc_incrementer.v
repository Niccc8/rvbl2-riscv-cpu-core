// ============================================================================
// pc_incrementer.v - dedicated PC+4 adder, deliberately not the shared ALU,
// so it is available every cycle without needing an ALU cycle.
// ============================================================================
module pc_incrementer (
    input  wire [31:0] pc,
    output wire [31:0] pc_plus_4
);
    assign pc_plus_4 = pc + 32'd4;
endmodule
