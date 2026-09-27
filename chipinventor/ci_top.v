// ============================================================================
// ci_top.v - local mirror of the two ChipInventor projects the canvas will
// generate for Stage 3.
//
// This file is NOT pasted into the platform. The platform builds each project's
// module from the wires you draw; this is a hand-written copy of that same
// structure so the whole design can be simulated locally, with the same
// hierarchy and the same block instances, before anything is entered on the
// website. If tb_chipinventor passes against this, it passes against the real
// thing - and check_export.py proves the real thing is wired the same.
//
// TWO PROJECTS
// ------------
//   rvbl2_soc  The Phase 2 project (copied first - the graded original stays
//              untouched), minus imem, plus gpio and uart. Reused as IP: the
//              platform exports it as its own module, named after the project.
//   top        The chip: rvbl2_soc + imem + gpio_bits, and the pins.
//
// imem sits outside the SoC because it is the one block that must differ per
// target: the case-ROM (or imem_mock for P&R) here, a host-loadable RAM in the
// FPGA wrapper, which takes rvbl2_soc from the export unchanged.
//
// Differences from rtl/top.v, all forced by the platform:
//
//   * No riscv_core between top and the blocks. Every net that used to be
//     internal to riscv_core.v is a wire of rvbl2_soc.
//   * The muxes are real blocks (mux2_32 x4, wb_mux_32); the canvas holds no
//     logic of its own.
//   * ir_fields exists, and funct3 comes from control_unit.op_size, because
//     the canvas cannot slice a bus.
//   * Figure 1's pin tri-state is the canvas Inout Pin: one 1-bit pin per GPIO
//     bit, written exactly as the platform emits it, `assign pin = D ? C : 1'bZ`
//     (D = enable, C = data). gpio_bits splits the 8-bit buses for them.
//   * An SoC pin that also feeds blocks inside the project is exported as
//     `assign pin = wire;`, so imem_addr_o is written that way here too.
//   * Parameters are set on block instances, as the canvas does: dmem's
//     DMEM_WORDS and uart's CLK_FREQ_HZ. gpio's SLOT/N_PINS and uart's
//     SLOT/BAUD_RATE are left at the block defaults (0 / 8 / 1 / 115200).
//
// state_o and sys_event_o are deliberately left unconnected and observed by
// the testbench through hierarchical references.
// ============================================================================

// ============================================================================
// Project 1: rvbl2_soc (reused as IP in `top`)
// ============================================================================
module rvbl2_soc (
    input  wire        clk_i,
    input  wire        rst_i,
    output wire [31:0] imem_addr_o,
    output wire        imem_oe_o,
    input  wire [31:0] imem_rdata_i,
    output wire [7:0]  gpio_o,
    output wire [7:0]  gpio_oe,
    input  wire [7:0]  gpio_i,
    output wire        tx_o,
    input  wire        rx_i
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
    wire [31:0] dmem_rdata;
    wire [3:0]  core_bw, dmem_bw;
    wire        dmem_oe, dmem_we;

    // ---------------- Peripheral bus nets -------------------------------
    wire        periph_we;
    wire [3:0]  periph_bw;
    wire [31:0] periph_chain_head, gpio_rdata, uart_rdata;

    // ---------------- Control nets --------------------------------------
    wire [2:0]  state_o;
    wire        alu_src_a_sel, alu_src_b_sel, addr_src_sel, pc_src_sel;
    wire        pc_write, reg_write, ir_write, core_we, core_oe;
    wire        sys_event_o, is_valid_store;
    wire [3:0]  alu_op;
    wire [2:0]  wb_src_sel, op_size;

    // The address bus also feeds blocks inside this project, so the platform
    // exports the pin as an alias of the internal net.
    assign imem_addr_o = core_address;

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
        .imem_rdata(imem_rdata_i), .dmem_rdata(dmem_rdata), .periph_rdata_i(uart_rdata),
        .imem_oe_o(imem_oe_o), .dmem_we_o(dmem_we), .dmem_oe_o(dmem_oe),
        .dmem_bw_o(dmem_bw), .periph_we_o(periph_we), .periph_bw_o(periph_bw),
        .periph_chain_o(periph_chain_head), .data_o(mem_rdata_muxed)
    );

    dmem #(.DMEM_WORDS(2048)) u_dmem (
        .clk_i(clk_i), .rst_i(rst_i),
        .address_i(core_address), .we_i(dmem_we), .oe_i(dmem_oe), .bw_i(dmem_bw),
        .data_i(core_store_data), .data_o(dmem_rdata)
    );

    // ====================================================================
    // Peripherals. Read-back chain: decoder (zero) -> gpio -> uart -> decoder.
    // ====================================================================
    gpio u_gpio (
        .clk_i(clk_i), .rst_i(rst_i),
        .bus_addr_i(core_address), .bus_wdata_i(core_store_data),
        .bus_we_i(periph_we), .bus_bw_i(periph_bw),
        .bus_rdata_i(periph_chain_head), .bus_rdata_o(gpio_rdata),
        .gpio_o(gpio_o), .gpio_oe(gpio_oe), .gpio_i(gpio_i)
    );

    uart #(.CLK_FREQ_HZ(30303030)) u_uart (
        .clk_i(clk_i), .rst_i(rst_i),
        .bus_addr_i(core_address), .bus_wdata_i(core_store_data),
        .bus_we_i(periph_we), .bus_bw_i(periph_bw),
        .bus_rdata_i(gpio_rdata), .bus_rdata_o(uart_rdata),
        .tx_o(tx_o), .rx_i(rx_i)
    );
endmodule

// ============================================================================
// Project 2: top (the chip)
//
// Pins: clk_i and rst_i (Phase 2), pins_io_0..7, tx_o and rx_i (Stage 3).
// rx_i must idle high: a floating or low rx_i reads as a continuous break.
// ============================================================================
module top (
    input  wire clk_i,
    input  wire rst_i,
    inout  wire pins_io_0,
    inout  wire pins_io_1,
    inout  wire pins_io_2,
    inout  wire pins_io_3,
    inout  wire pins_io_4,
    inout  wire pins_io_5,
    inout  wire pins_io_6,
    inout  wire pins_io_7,
    output wire tx_o,
    input  wire rx_i
);
    wire [31:0] imem_addr, imem_rdata;
    wire        imem_oe;
    wire [7:0]  gpio_o, gpio_oe, gpio_i;
    wire        c0, c1, c2, c3, c4, c5, c6, c7;   // DATAOUT[n] -> pin C
    wire        d0, d1, d2, d3, d4, d5, d6, d7;   // DATADIR[n] -> pin D

    // The eight Inout Pins, as the platform writes them: D enables, C drives.
    assign pins_io_0 = d0 ? c0 : 1'bZ;
    assign pins_io_1 = d1 ? c1 : 1'bZ;
    assign pins_io_2 = d2 ? c2 : 1'bZ;
    assign pins_io_3 = d3 ? c3 : 1'bZ;
    assign pins_io_4 = d4 ? c4 : 1'bZ;
    assign pins_io_5 = d5 ? c5 : 1'bZ;
    assign pins_io_6 = d6 ? c6 : 1'bZ;
    assign pins_io_7 = d7 ? c7 : 1'bZ;

    rvbl2_soc u_soc (
        .clk_i(clk_i), .rst_i(rst_i),
        .imem_addr_o(imem_addr), .imem_oe_o(imem_oe), .imem_rdata_i(imem_rdata),
        .gpio_o(gpio_o), .gpio_oe(gpio_oe), .gpio_i(gpio_i),
        .tx_o(tx_o), .rx_i(rx_i)
    );

    imem u_imem (
        .address_i(imem_addr), .oe_i(imem_oe), .data_o(imem_rdata)
    );

    gpio_bits u_bits (
        .gpio_o(gpio_o), .gpio_oe(gpio_oe), .gpio_i(gpio_i),
        .p0_i(pins_io_0), .p1_i(pins_io_1), .p2_i(pins_io_2), .p3_i(pins_io_3),
        .p4_i(pins_io_4), .p5_i(pins_io_5), .p6_i(pins_io_6), .p7_i(pins_io_7),
        .c0_o(c0), .d0_o(d0), .c1_o(c1), .d1_o(d1), .c2_o(c2), .d2_o(d2),
        .c3_o(c3), .d3_o(d3), .c4_o(c4), .d4_o(d4), .c5_o(c5), .d5_o(d5),
        .c6_o(c6), .d6_o(d6), .c7_o(c7), .d7_o(d7)
    );
endmodule
