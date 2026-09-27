// ============================================================================
// address_decoder.v - routes the core's single memory-transaction interface
// to IMEM, DMEM or the peripheral region, and muxes read data back.
//
// Every strobe routed to a target is explicitly qualified by that target's own
// select - NOT just "routed to DMEM" in general - otherwise an out-of-range
// store could alias into a real DMEM or peripheral write.
//
// Stage 3 adds ONE region, not one port per peripheral. 0xF0000000-0xFFFFFFFF
// is 16 slots of 16 MB (slot = addr[27:24]); each peripheral decodes its own
// slot and register offset (GPIO slot 0, UART slot 1). Read data comes back
// through a chain: periph_chain_o -> gpio -> uart -> periph_rdata_i, each
// peripheral OR-ing in its register only when it is addressed, so adding a
// peripheral changes no existing block. periph_chain_o is a constant zero; it
// exists only because the ChipInventor canvas cannot draw a constant.
//
// There is deliberately no peripheral read strobe. The core holds a load's
// address and oe_i across MEMORY and WRITEBACK, so a read-triggered action
// would fire twice; peripheral reads are therefore side-effect free.
// ============================================================================
module address_decoder (
    input  wire [31:0] address_i,
    input  wire        we_i,
    input  wire        oe_i,
    input  wire [3:0]  bw_i,
    input  wire [31:0] imem_rdata,
    input  wire [31:0] dmem_rdata,
    input  wire [31:0] periph_rdata_i,
    output wire        imem_oe_o,
    output wire        dmem_we_o,
    output wire        dmem_oe_o,
    output wire [3:0]  dmem_bw_o,
    output wire        periph_we_o,
    output wire [3:0]  periph_bw_o,
    output wire [31:0] periph_chain_o,
    output wire [31:0] data_o
);
    localparam [31:0] IMEM_BASE     = 32'h0040_0000;
    localparam [31:0] IMEM_LAST     = 32'h007F_FFFF; // 4MB architectural window
    localparam [31:0] DMEM_BASE     = 32'h1001_0000;
    localparam [31:0] DMEM_LAST     = 32'h1001_1FFF; // 8kB window
    localparam [3:0]  PERIPH_REGION = 4'hF;          // 0xF0000000-0xFFFFFFFF

    wire imem_sel   = (address_i >= IMEM_BASE) && (address_i <= IMEM_LAST);
    wire dmem_sel   = (address_i >= DMEM_BASE) && (address_i <= DMEM_LAST);
    wire periph_sel = (address_i[31:28] == PERIPH_REGION);

    // IMEM has no write port at all - we_i is never routed there.
    assign imem_oe_o = oe_i & imem_sel;
    assign dmem_oe_o = oe_i & dmem_sel;
    assign dmem_we_o = we_i & dmem_sel;
    assign dmem_bw_o = bw_i & {4{dmem_sel}};

    assign periph_we_o    = we_i & periph_sel;
    assign periph_bw_o    = bw_i & {4{periph_sel}};
    assign periph_chain_o = 32'b0;

    assign data_o = dmem_sel   ? dmem_rdata     :
                    imem_sel   ? imem_rdata     :
                    periph_sel ? periph_rdata_i : 32'b0;
endmodule
