// ============================================================================
// ir_reg.v - instruction register. Loaded exactly once per instruction,
// at the Fetch->Decode edge (ir_write asserted only during FETCH). This is
// the linchpin of the no-ALUOut/no-MDR datapath (§7.4/§9.3).
// ============================================================================
module ir_reg (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        ir_write,
    input  wire [31:0] imem_data,
    // (* keep *) - see dmem.v for why this is needed (zero-output top level).
    (* keep *) output reg  [31:0] ir
);
    localparam [31:0] NOP = 32'h0000_0013; // ADDI x0,x0,0 - waveform readability only

    always @(posedge clk_i) begin
        if (rst_i)
            ir <= NOP;
        else if (ir_write)
            ir <= imem_data;
    end
endmodule
