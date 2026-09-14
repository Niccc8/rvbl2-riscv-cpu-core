// ============================================================================
// top.v - SoC top level. Only external pins are clk_i/rst_i (Block Guide
// §2.2, Table 5 - MANDATORY). Zero behavioral logic of its own: pure
// instantiation + wiring (§9.15), so any bug found here is a connectivity
// bug, never a logic bug.
// ============================================================================
module top #(
    parameter IMEM_WORDS = 4096,
    parameter DMEM_WORDS = 2048,
    parameter IMEM_INIT_FILE = "tests/progs/tb_firmware_prog.hex"
) (
    input wire clk_i,
    input wire rst_i
);
    wire [31:0] core_address, core_store_data, mem_rdata_muxed;
    wire        core_we, core_oe;
    wire [3:0]  core_bw;
    // (* keep *) - no data pins exist at this level, so nothing else anchors
    // this net; without it a flattening flow deletes the firmware-completion
    // event the integration testbenches observe.
    (* keep *) wire sys_event_o;

    wire [31:0] imem_rdata, dmem_rdata;
    wire        imem_oe, dmem_oe, dmem_we;
    wire [3:0]  dmem_bw;

    riscv_core u_core (
        .clk_i(clk_i), .rst_i(rst_i),
        .mem_rdata_i(mem_rdata_muxed),
        .address_o(core_address), .we_o(core_we), .oe_o(core_oe), .bw_o(core_bw),
        .store_data_o(core_store_data), .sys_event_o(sys_event_o)
    );

    address_decoder u_decoder (
        .address_i(core_address), .we_i(core_we), .oe_i(core_oe), .bw_i(core_bw),
        .imem_rdata(imem_rdata), .dmem_rdata(dmem_rdata),
        .imem_oe_o(imem_oe), .dmem_we_o(dmem_we), .dmem_oe_o(dmem_oe), .dmem_bw_o(dmem_bw),
        .data_o(mem_rdata_muxed)
    );

    imem #(.IMEM_WORDS(IMEM_WORDS), .INIT_FILE(IMEM_INIT_FILE)) u_imem (
        .address_i(core_address), .oe_i(imem_oe), .data_o(imem_rdata)
    );

    dmem #(.DMEM_WORDS(DMEM_WORDS)) u_dmem (
        .clk_i(clk_i), .rst_i(rst_i),
        .address_i(core_address), .we_i(dmem_we), .oe_i(dmem_oe), .bw_i(dmem_bw),
        .data_i(core_store_data), .data_o(dmem_rdata)
    );
endmodule
