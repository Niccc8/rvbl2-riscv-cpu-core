// ============================================================================
// riscv_core.v - integrates control_unit + full datapath (§6.1, §7).
// Exposes the core-to-memory-system interface only (Fig.2/Fig.3-equivalent):
// address_o/we_o/oe_o/bw_o/store_data_o out, mem_rdata_i in.
//
// Internal signals (pc, ir, state) are intentionally NOT brought out as
// ports - a testbench that needs them uses hierarchical references
// (e.g. dut.u_pc.pc, dut.u_ctrl.state), matching the "no observable I/O"
// verification approach required by the 2-pin top level (§14.1).
// ============================================================================
module riscv_core (
    input  wire        clk_i,
    input  wire        rst_i,

    input  wire [31:0] mem_rdata_i,   // muxed read data from address_decoder
    output wire [31:0] address_o,
    output wire        we_o,
    output wire        oe_o,
    output wire [3:0]  bw_o,
    output wire [31:0] store_data_o,
    (* keep *) output wire sys_event_o
);
    wire [31:0] pc, pc_plus_4, ir, imm;
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] alu_a, alu_b, alu_result;
    wire [31:0] mult_result, crc_result, lsu_load_data;
    wire [31:0] pc_next;
    reg  [31:0] wb_data;

    wire [4:0] rs1_addr = ir[19:15];
    wire [4:0] rs2_addr = ir[24:20];
    wire [4:0] rd_addr  = ir[11:7];
    wire [2:0] funct3   = ir[14:12];

    wire [2:0] state;
    wire alu_src_a_sel, alu_src_b_sel, addr_src_sel, pc_src_sel;
    wire pc_write, reg_write, ir_write, is_valid_store;
    wire [3:0] alu_op;
    wire [2:0] wb_src_sel, op_size;
    wire branch_taken;

    control_unit u_ctrl (
        .clk_i(clk_i), .rst_i(rst_i), .ir(ir), .branch_taken(branch_taken),
        .state_o(state),
        .alu_src_a_sel(alu_src_a_sel), .alu_src_b_sel(alu_src_b_sel), .alu_op(alu_op),
        .addr_src_sel(addr_src_sel), .wb_src_sel(wb_src_sel), .pc_src_sel(pc_src_sel),
        .pc_write(pc_write), .reg_write(reg_write), .we_o(we_o), .oe_o(oe_o),
        .ir_write(ir_write), .sys_event_o(sys_event_o),
        .is_valid_store(is_valid_store), .op_size(op_size)
    );

    pc_reg u_pc (.clk_i(clk_i), .rst_i(rst_i), .pc_write(pc_write), .pc_next(pc_next), .pc(pc));
    pc_incrementer u_pcinc (.pc(pc), .pc_plus_4(pc_plus_4));
    ir_reg u_ir (.clk_i(clk_i), .rst_i(rst_i), .ir_write(ir_write), .imem_data(mem_rdata_i), .ir(ir));

    register_file u_rf (
        .clk_i(clk_i), .rst_i(rst_i),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr),
        .rd_data(wb_data), .reg_write(reg_write),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    immediate_generator u_imm (.ir(ir), .imm(imm));

    assign alu_a = alu_src_a_sel ? pc : rs1_data;
    assign alu_b = alu_src_b_sel ? imm : rs2_data;
    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(alu_op), .result(alu_result));

    branch_comparator u_bc (
        .rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(funct3), .branch_taken(branch_taken)
    );

    multiplier u_mul (.rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(funct3), .result(mult_result));
    crc_unit   u_crc (.rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(funct3), .result(crc_result));

    lsu u_lsu (
        .alu_result(alu_result), .rs2_data(rs2_data), .op_size(op_size),
        .is_valid_store(is_valid_store), .mem_data_o(mem_rdata_i),
        .core_data_i(lsu_load_data), .byte_write_o(bw_o), .store_data_o(store_data_o)
    );

    assign address_o = addr_src_sel ? alu_result : pc;
    assign pc_next    = pc_src_sel ? alu_result : pc_plus_4;

    always @(*) begin
        case (wb_src_sel)
            3'b001:  wb_data = mult_result;
            3'b010:  wb_data = crc_result;
            3'b011:  wb_data = lsu_load_data;
            3'b100:  wb_data = pc_plus_4;
            default: wb_data = alu_result;
        endcase
    end
endmodule
