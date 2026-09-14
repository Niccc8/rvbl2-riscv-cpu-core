// ============================================================================
// register_file.v - 32 x 32-bit GPRs. x0 hardwired zero. Async read,
// synchronous write scoped to WriteBack by control_unit.
// ============================================================================
module register_file (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    input  wire        reg_write,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);
    // (* keep *) - see dmem.v for why this is needed (zero-output top level).
    (* keep *) reg [31:0] regs [0:31];
    integer i;

    // Async reads; x0 read-side default is defense-in-depth (§9.8), the
    // write-guard below is what actually makes x0 permanently zero.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : regs[rs2_addr];

    always @(posedge clk_i) begin
        if (rst_i) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
        end else if (reg_write && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end
endmodule
