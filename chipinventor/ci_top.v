// ============================================================================
// ci_top.v - local mirror of the `top` the ChipInventor canvas will generate.
//
// This file is NOT pasted into the platform. The platform builds its own top
// from the wires you draw; this is a hand-written copy of that same structure
// so the whole design can be simulated locally, with the same flat hierarchy
// and the same 20 block instances, before anything is entered on the website.
// If tb_chipinventor passes against this, it passes against the real thing.
//
// Differences from rtl/top.v, all forced by the platform:
//
//   * FLAT. The platform generates exactly one level: `top` instantiating
//     blocks. There is no riscv_core between them, so every net that used to
//     be internal to riscv_core.v is a top-level wire here.
//   * The muxes are real blocks. riscv_core.v selected with inline `assign`s
//     and a `case`; the canvas holds no logic of its own, so those became
//     mux2_32 x4 and wb_mux_32.
//   * ir_fields exists. The canvas cannot slice a bus, so ir[19:15] and
//     friends cannot be drawn as wires and are extracted in a block instead.
//   * funct3 is NOT extracted. control_unit already publishes it as op_size,
//     so branch_comparator/multiplier/crc_unit/lsu all take that one output.
//   * No parameters at this level. On the canvas, DMEM_WORDS is set on the
//     dmem block instance itself, so it is set here the same way.
//
// Only clk_i and rst_i are pins, per Block Guide Table 5 (mandatory). state_o
// and sys_event_o are deliberately left unconnected and observed by the
// testbench through hierarchical references.
// ============================================================================
module top (
    input wire clk_i,
    input wire rst_i
);
    // ---------------- Datapath nets -------------------------------------
    wire [31:0] pc, pc_plus_4, pc_next;
    wire [31:0] ir, imm;
    wire [4:0]  rs1_addr, rs2_addr, rd_addr;
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] alu_a, alu_b, alu_result;
    wire [31:0] mult_result, crc_result, lsu_load_data, wb_data;
    wire        branch_taken;

    // ---------------- Memory-system nets --------------------------------
    wire [31:0] core_address, core_store_data, mem_rdata_muxed;
    wire [31:0] imem_rdata, dmem_rdata;
    wire [3:0]  core_bw, dmem_bw;
    wire        imem_oe, dmem_oe, dmem_we;

    // ---------------- Control nets --------------------------------------
    wire [2:0]  state_o;
    wire        alu_src_a_sel, alu_src_b_sel, addr_src_sel, pc_src_sel;
    wire        pc_write, reg_write, ir_write, core_we, core_oe;
    wire        sys_event_o, is_valid_store;
    wire [3:0]  alu_op;
    wire [2:0]  wb_src_sel, op_size;

    // ====================================================================
    // Control
    // ====================================================================
    control_unit u_ctrl (
        .clk_i(clk_i), .rst_i(rst_i), .ir(ir), .branch_taken(branch_taken),
        .state_o(state_o),
        .alu_src_a_sel(alu_src_a_sel), .alu_src_b_sel(alu_src_b_sel), .alu_op(alu_op),
        .addr_src_sel(addr_src_sel), .wb_src_sel(wb_src_sel), .pc_src_sel(pc_src_sel),
        .pc_write(pc_write), .reg_write(reg_write), .we_o(core_we), .oe_o(core_oe),
        .ir_write(ir_write), .sys_event_o(sys_event_o),
        .is_valid_store(is_valid_store), .op_size(op_size)
    );

    // ====================================================================
    // Instruction path
    // ====================================================================
    pc_reg u_pc (
        .clk_i(clk_i), .rst_i(rst_i), .pc_write(pc_write),
        .pc_next(pc_next), .pc(pc)
    );

    pc_incrementer u_pcinc (.pc(pc), .pc_plus_4(pc_plus_4));

    ir_reg u_ir (
        .clk_i(clk_i), .rst_i(rst_i), .ir_write(ir_write),
        .imem_data(mem_rdata_muxed), .ir(ir)
    );

    ir_fields u_irf (
        .ir(ir), .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr)
    );

    immediate_generator u_imm (.ir(ir), .imm(imm));

    // ====================================================================
    // Register file and execute units
    // ====================================================================
    register_file u_rf (
        .clk_i(clk_i), .rst_i(rst_i),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr),
        .rd_data(wb_data), .reg_write(reg_write),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // alu_a: s=0 -> rs1_data, s=1 -> pc  (AUIPC / branch / JAL targets)
    mux2_32 u_muxa (.a(rs1_data), .b(pc), .s(alu_src_a_sel), .z(alu_a));
    // alu_b: s=0 -> rs2_data, s=1 -> imm
    mux2_32 u_muxb (.a(rs2_data), .b(imm), .s(alu_src_b_sel), .z(alu_b));

    alu u_alu (.a(alu_a), .b(alu_b), .alu_op(alu_op), .result(alu_result));

    // op_size is funct3 - one control output feeds all four consumers.
    branch_comparator u_bc (
        .rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(op_size),
        .branch_taken(branch_taken)
    );

    multiplier u_mul (
        .rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(op_size),
        .result(mult_result)
    );

    crc_unit u_crc (
        .rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(op_size),
        .result(crc_result)
    );

    // NOTE when wiring on the canvas: lsu's port names read backwards.
    // mem_data_o is an INPUT (word read back from memory) and core_data_i is
    // an OUTPUT (extended load data heading for the writeback mux).
    lsu u_lsu (
        .alu_result(alu_result), .rs2_data(rs2_data), .op_size(op_size),
        .is_valid_store(is_valid_store), .mem_data_o(mem_rdata_muxed),
        .core_data_i(lsu_load_data), .byte_write_o(core_bw),
        .store_data_o(core_store_data)
    );

    wb_mux_32 u_wbmux (
        .alu_result(alu_result), .mult_result(mult_result), .crc_result(crc_result),
        .lsu_load_data(lsu_load_data), .pc_plus_4(pc_plus_4),
        .wb_src_sel(wb_src_sel), .wb_data(wb_data)
    );

    // address: s=0 -> pc (fetch), s=1 -> alu_result (load/store address)
    mux2_32 u_muxaddr (.a(pc), .b(alu_result), .s(addr_src_sel), .z(core_address));
    // pc_next: s=0 -> pc_plus_4, s=1 -> alu_result (branch/jump target)
    mux2_32 u_muxpc (.a(pc_plus_4), .b(alu_result), .s(pc_src_sel), .z(pc_next));

    // ====================================================================
    // Memory system
    // ====================================================================
    address_decoder u_decoder (
        .address_i(core_address), .we_i(core_we), .oe_i(core_oe), .bw_i(core_bw),
        .imem_rdata(imem_rdata), .dmem_rdata(dmem_rdata),
        .imem_oe_o(imem_oe), .dmem_we_o(dmem_we), .dmem_oe_o(dmem_oe),
        .dmem_bw_o(dmem_bw), .data_o(mem_rdata_muxed)
    );

    imem u_imem (
        .address_i(core_address), .oe_i(imem_oe), .data_o(imem_rdata)
    );

    dmem #(.DMEM_WORDS(2048)) u_dmem (
        .clk_i(clk_i), .rst_i(rst_i),
        .address_i(core_address), .we_i(dmem_we), .oe_i(dmem_oe), .bw_i(dmem_bw),
        .data_i(core_store_data), .data_o(dmem_rdata)
    );
endmodule
