// ============================================================================
// top.v - SoC top level: the RVBL-2 core, its two memories, and the Stage 3
// peripherals (GPIO at 0xF0000000, UART at 0xF1000000).
//
// Pins: clk_i and rst_i (Phase 2), plus pins_io[7:0], tx_o and rx_i, which
// Stage 3 Block Guide §1.2 and §2 add - superseding Phase 2's two-pin rule.
//
// The only logic here is Figure 1's output tri-state, one per GPIO pin:
// gpio_oe (DATADIR) enables the driver and gpio_o (DATAOUT) is the level. It
// stays at the chip boundary so the GPIO block itself never contains a
// tri-state. Everything else is instantiation and wiring, so any bug found
// here is a connectivity bug, never a logic bug.
//
// rx_i must idle high: a floating or low rx_i reads as a continuous break.
// ============================================================================
module top #(
    parameter IMEM_WORDS       = 4096,
    parameter DMEM_WORDS       = 2048,
    parameter IMEM_INIT_FILE   = "tests/progs/tb_firmware_prog.hex",
    parameter UART_CLK_FREQ_HZ = 30303030, // 33 ns ASIC clock
    parameter UART_BAUD_RATE   = 115200
) (
    input  wire       clk_i,
    input  wire       rst_i,
    inout  wire [7:0] pins_io,
    output wire       tx_o,
    input  wire       rx_i
);
    wire [31:0] core_address, core_store_data, mem_rdata_muxed;
    wire        core_we, core_oe;
    wire [3:0]  core_bw;
    // (* keep *) - the testbenches observe this firmware-completion event,
    // which reaches no pin.
    (* keep *) wire sys_event_o;

    wire [31:0] imem_rdata, dmem_rdata;
    wire        imem_oe, dmem_oe, dmem_we;
    wire [3:0]  dmem_bw;

    wire        periph_we;
    wire [3:0]  periph_bw;
    wire [31:0] periph_chain_head, gpio_rdata, uart_rdata;

    wire [7:0]  gpio_o, gpio_oe, gpio_i;

    riscv_core u_core (
        .clk_i(clk_i), .rst_i(rst_i),
        .mem_rdata_i(mem_rdata_muxed),
        .address_o(core_address), .we_o(core_we), .oe_o(core_oe), .bw_o(core_bw),
        .store_data_o(core_store_data), .sys_event_o(sys_event_o)
    );

    address_decoder u_decoder (
        .address_i(core_address), .we_i(core_we), .oe_i(core_oe), .bw_i(core_bw),
        .imem_rdata(imem_rdata), .dmem_rdata(dmem_rdata), .periph_rdata_i(uart_rdata),
        .imem_oe_o(imem_oe), .dmem_we_o(dmem_we), .dmem_oe_o(dmem_oe), .dmem_bw_o(dmem_bw),
        .periph_we_o(periph_we), .periph_bw_o(periph_bw), .periph_chain_o(periph_chain_head),
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

    // Read-back chain: decoder (zero) -> gpio -> uart -> decoder.
    gpio #(.SLOT(4'd0), .N_PINS(8)) u_gpio (
        .clk_i(clk_i), .rst_i(rst_i),
        .bus_addr_i(core_address), .bus_wdata_i(core_store_data),
        .bus_we_i(periph_we), .bus_bw_i(periph_bw),
        .bus_rdata_i(periph_chain_head), .bus_rdata_o(gpio_rdata),
        .gpio_o(gpio_o), .gpio_oe(gpio_oe), .gpio_i(gpio_i)
    );

    uart #(.SLOT(4'd1), .CLK_FREQ_HZ(UART_CLK_FREQ_HZ), .BAUD_RATE(UART_BAUD_RATE)) u_uart (
        .clk_i(clk_i), .rst_i(rst_i),
        .bus_addr_i(core_address), .bus_wdata_i(core_store_data),
        .bus_we_i(periph_we), .bus_bw_i(periph_bw),
        .bus_rdata_i(gpio_rdata), .bus_rdata_o(uart_rdata),
        .tx_o(tx_o), .rx_i(rx_i)
    );

    // Figure 1 output tri-state, per pin. The input path reads the pad itself;
    // gpio gates it with ~DATADIR.
    genvar n;
    generate
        for (n = 0; n < 8; n = n + 1) begin : g_pad
            assign pins_io[n] = gpio_oe[n] ? gpio_o[n] : 1'bz;
        end
    endgenerate
    assign gpio_i = pins_io;
endmodule
