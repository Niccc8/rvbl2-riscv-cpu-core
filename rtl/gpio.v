// ============================================================================
// gpio.v - PIN Controller (Stage 3 Block Guide §1). Memory-mapped at
// 0xF0000000 (peripheral slot SLOT = 0).
//
//   offset 0x0  DATAOUT  RW  level driven on pins configured as outputs
//   offset 0x4  DATAIN   R   level on pins configured as inputs
//   offset 0x8  DATADIR  RW  per-pin direction, 0 = input, 1 = output
//   anything else in the slot reads 0 and ignores writes (no aliasing)
//
// Figure 1 is split so each target realises the tri-state natively:
// gpio_oe = DATADIR enables the pad driver and gpio_o = DATAOUT is the level
// it drives; the tri-state itself is the ChipInventor Inout Pin (ASIC top),
// never inside this block, because FPGA fabric has no internal tri-states.
//
// Decisions (docs/GPIO_UART_INTEGRATION.md):
//   * Reset: all pins inputs, DATAOUT = 0 - nothing drives a pad out of reset.
//   * Inputs pass a 2-flip-flop synchroniser (sync1 -> sync2) before use;
//     sync2 is Figure 1's DATAIN flip-flop.
//   * DATAIN reads 0 for a pin configured as output: Figure 1's input buffer is
//     enabled by ~DATADIR, so an output pin's level never reaches DATAIN.
//   * Writes honour byte enables: bit b of a register is written only when
//     bus_bw_i[b/8] is set. With N_PINS <= 8 every field is in byte lane 0.
//   * Reserved bits read 0.
//
// Bus ports are the Stage 3 peripheral contract, identical in every
// peripheral (spec §4.2); reads have no side effects.
// ============================================================================
module gpio #(
    parameter [3:0] SLOT   = 4'd0, // 0xF0000000
    parameter       N_PINS = 8     // 1..32
) (
    input  wire              clk_i,
    input  wire              rst_i,
    input  wire [31:0]       bus_addr_i,
    input  wire [31:0]       bus_wdata_i,
    input  wire              bus_we_i,
    input  wire [3:0]        bus_bw_i,
    input  wire [31:0]       bus_rdata_i,
    output wire [31:0]       bus_rdata_o,
    output wire [N_PINS-1:0] gpio_o,
    output wire [N_PINS-1:0] gpio_oe,
    input  wire [N_PINS-1:0] gpio_i
);
    localparam [3:0] REGION      = 4'hF;
    localparam [1:0] OFF_DATAOUT = 2'd0,
                     OFF_DATAIN  = 2'd1,
                     OFF_DATADIR = 2'd2;

    // ---------------- Bus decode (the same four lines in every peripheral) --
    wire       hit     = (bus_addr_i[31:28] == REGION) && (bus_addr_i[27:24] == SLOT) &&
                         (bus_addr_i[23:4] == 20'b0);
    wire [1:0] off     = bus_addr_i[3:2];
    wire [3:0] wr_lane = {4{bus_we_i & hit}} & bus_bw_i;

    // Per-bit write enable over a 32-bit register, from the byte lanes.
    wire [31:0]       lane_bits = {{8{wr_lane[3]}}, {8{wr_lane[2]}}, {8{wr_lane[1]}}, {8{wr_lane[0]}}};
    wire [N_PINS-1:0] wr_dataout = (off == OFF_DATAOUT) ? lane_bits[N_PINS-1:0] : {N_PINS{1'b0}};
    wire [N_PINS-1:0] wr_datadir = (off == OFF_DATADIR) ? lane_bits[N_PINS-1:0] : {N_PINS{1'b0}};
    wire [N_PINS-1:0] wdata      = bus_wdata_i[N_PINS-1:0];

    // ---------------- Registers --------------------------------------------
    reg [N_PINS-1:0] dataout, datadir;
    reg [N_PINS-1:0] sync1, sync2;

    always @(posedge clk_i) begin
        if (rst_i) begin
            dataout <= {N_PINS{1'b0}};
            datadir <= {N_PINS{1'b0}};   // all inputs
            sync1   <= {N_PINS{1'b0}};
            sync2   <= {N_PINS{1'b0}};
        end else begin
            dataout <= (dataout & ~wr_dataout) | (wdata & wr_dataout);
            datadir <= (datadir & ~wr_datadir) | (wdata & wr_datadir);
            sync1   <= gpio_i;
            sync2   <= sync1;
        end
    end

    wire [N_PINS-1:0] datain = sync2 & ~datadir;

    assign gpio_o  = dataout;
    assign gpio_oe = datadir;

    // ---------------- Read-back chain ---------------------------------------
    reg [31:0] rdata_local;
    always @(*) begin
        rdata_local = 32'b0;
        case (off)
            OFF_DATAOUT: rdata_local[N_PINS-1:0] = dataout;
            OFF_DATAIN:  rdata_local[N_PINS-1:0] = datain;
            OFF_DATADIR: rdata_local[N_PINS-1:0] = datadir;
            default:     rdata_local = 32'b0;
        endcase
    end

    assign bus_rdata_o = bus_rdata_i | (hit ? rdata_local : 32'b0);
endmodule
