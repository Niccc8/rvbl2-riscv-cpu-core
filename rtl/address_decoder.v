// ============================================================================
// address_decoder.v - routes the core's single memory-transaction interface
// to IMEM or DMEM based on address range, and muxes read data back.
// Purely combinational (§9.14).
//
// Every signal routed to a memory is explicitly qualified by that memory's
// own select (imem_sel / dmem_sel) - NOT just "routed to DMEM" in general -
// otherwise an out-of-range store could alias into a real DMEM write
// (§9.14 v4 fix / risk R20).
// ============================================================================
module address_decoder (
    input  wire [31:0] address_i,
    input  wire        we_i,
    input  wire        oe_i,
    input  wire [3:0]  bw_i,
    input  wire [31:0] imem_rdata,
    input  wire [31:0] dmem_rdata,
    output wire        imem_oe_o,
    output wire        dmem_we_o,
    output wire        dmem_oe_o,
    output wire [3:0]  dmem_bw_o,
    output wire [31:0] data_o
);
    localparam [31:0] IMEM_BASE = 32'h0040_0000;
    localparam [31:0] IMEM_LAST = 32'h007F_FFFF; // 4MB architectural window
    localparam [31:0] DMEM_BASE = 32'h1001_0000;
    localparam [31:0] DMEM_LAST = 32'h1001_1FFF; // 8kB window

    wire imem_sel = (address_i >= IMEM_BASE) && (address_i <= IMEM_LAST);
    wire dmem_sel = (address_i >= DMEM_BASE) && (address_i <= DMEM_LAST);

    // IMEM has no write port at all (Block Guide §4.4) - we_o never routed there.
    assign imem_oe_o = oe_i & imem_sel;
    assign dmem_oe_o = oe_i & dmem_sel;
    assign dmem_we_o = we_i & dmem_sel;
    assign dmem_bw_o = bw_i & {4{dmem_sel}};

    assign data_o = dmem_sel ? dmem_rdata : (imem_sel ? imem_rdata : 32'b0);
endmodule
