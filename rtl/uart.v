// ============================================================================
// uart.v - Serial Controller (Stage 3 Block Guide §2). Memory-mapped at
// 0xF1000000 (peripheral slot SLOT = 1). 8-N-1, LSB first, full duplex.
//
//   offset 0x0  TXDATA   RW  [7:0] byte sent when TRANSMIT is set
//   offset 0x4  RXDATA   R   [7:0] last byte received
//   offset 0x8  CONTROL      bit 0 TRANSMIT (W, one-cycle pulse, reads 0)
//                            bit 1 RXDONE   (set by the receiver; write 0 clears,
//                                            write 1 has no effect)
//                            bit 2 TXDONE   (R, transmitter idle; resets to 1)
//   anything else in the slot reads 0 and ignores writes (no aliasing)
//
// Frame: start (0), D0..D7, one stop (1) = 10 bit-times of CLKS_PER_BIT clocks.
// CLKS_PER_BIT = round(CLK_FREQ_HZ / BAUD_RATE); CLK_FREQ_HZ must equal the
// clock actually driving clk_i (30303030 for the 33 ns ASIC constraint).
//
// Decisions (docs/GPIO_UART_INTEGRATION.md):
//   * TRANSMIT starts a frame only while the transmitter is idle; a TRANSMIT
//     written while busy is ignored. TXDATA is copied into the shift register
//     when the frame starts, so writing TXDATA mid-frame is safe.
//   * TXDONE clears on the edge that starts a frame and sets when the stop bit
//     has been fully sent. Software writes to it have no effect.
//   * RXDONE: a reception completing in the same cycle as a software clear
//     wins, so a byte is never lost silently.
//   * "No oversampling": rx_i passes a 2-flip-flop synchroniser; the start edge
//     is detected at the system clock rate, re-checked at mid-start (glitch
//     rejection), then each bit is sampled once, at mid-bit.
//   * A frame whose stop bit reads 0 (framing error, break) is dropped. The
//     receiver arms on a falling EDGE, so a line held low cannot start another
//     frame until it has returned high: no phantom bytes from a break or from
//     rx_i held low at reset.
//   * Overrun: a new byte overwrites RXDATA; RXDONE stays set.
//   * Counters run only while a frame is in flight: no toggling when idle.
//
// Bus ports are the Stage 3 peripheral contract (spec §4.2); reads have no
// side effects. CLKS_PER_BIT must be at least 4.
// ============================================================================
module uart #(
    parameter [3:0] SLOT        = 4'd1,       // 0xF1000000
    parameter       CLK_FREQ_HZ = 30303030,   // 33 ns ASIC clock
    parameter       BAUD_RATE   = 115200
) (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire [31:0] bus_addr_i,
    input  wire [31:0] bus_wdata_i,
    input  wire        bus_we_i,
    input  wire [3:0]  bus_bw_i,
    input  wire [31:0] bus_rdata_i,
    output wire [31:0] bus_rdata_o,
    output wire        tx_o,
    input  wire        rx_i
);
    localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;
    localparam integer CW           = (CLKS_PER_BIT <= 2) ? 1 : $clog2(CLKS_PER_BIT);
    localparam [CW-1:0] BIT_LAST    = CLKS_PER_BIT - 1;
    localparam [CW-1:0] HALF_LAST   = HALF_BIT - 1;

    localparam [3:0] REGION      = 4'hF;
    localparam [1:0] OFF_TXDATA  = 2'd0,
                     OFF_RXDATA  = 2'd1,
                     OFF_CONTROL = 2'd2;

    localparam [1:0] TX_IDLE = 2'd0, TX_START = 2'd1, TX_DATA = 2'd2, TX_STOP = 2'd3;
    localparam [1:0] RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;

    // ---------------- Bus decode (the same four lines in every peripheral) --
    wire       hit     = (bus_addr_i[31:28] == REGION) && (bus_addr_i[27:24] == SLOT) &&
                         (bus_addr_i[23:4] == 20'b0);
    wire [1:0] off     = bus_addr_i[3:2];
    wire [3:0] wr_lane = {4{bus_we_i & hit}} & bus_bw_i;

    // Every field lives in byte lane 0.
    wire wr_txdata  = wr_lane[0] & (off == OFF_TXDATA);
    wire wr_control = wr_lane[0] & (off == OFF_CONTROL);

    // ---------------- Programmer-visible registers --------------------------
    reg [7:0] txdata, rxdata;
    reg       transmit, rxdone, txdone;

    // ---------------- Transmitter -------------------------------------------
    reg [1:0]    tx_state;
    reg [CW-1:0] tx_cnt;
    reg [2:0]    tx_bit;
    reg [7:0]    tx_shift;
    reg          tx_q;
    wire         tx_tick = (tx_cnt == {CW{1'b0}});

    always @(posedge clk_i) begin
        if (rst_i) begin
            tx_state <= TX_IDLE;
            tx_cnt   <= {CW{1'b0}};
            tx_bit   <= 3'd0;
            tx_shift <= 8'd0;
            tx_q     <= 1'b1;               // line idles high
            txdone   <= 1'b1;               // idle: ready for the first byte
        end else begin
            case (tx_state)
                TX_IDLE: if (transmit) begin
                    tx_shift <= txdata;
                    tx_cnt   <= BIT_LAST;
                    tx_q     <= 1'b0;       // start bit
                    txdone   <= 1'b0;
                    tx_state <= TX_START;
                end
                TX_START: if (tx_tick) begin
                    tx_cnt   <= BIT_LAST;
                    tx_q     <= tx_shift[0];  // D0
                    tx_bit   <= 3'd0;
                    tx_state <= TX_DATA;
                end else tx_cnt <= tx_cnt - 1'b1;
                TX_DATA: if (tx_tick) begin
                    tx_cnt <= BIT_LAST;
                    if (tx_bit == 3'd7) begin
                        tx_q     <= 1'b1;   // stop bit
                        tx_state <= TX_STOP;
                    end else begin
                        tx_q     <= tx_shift[1];
                        tx_shift <= {1'b0, tx_shift[7:1]};
                        tx_bit   <= tx_bit + 1'b1;
                    end
                end else tx_cnt <= tx_cnt - 1'b1;
                TX_STOP: if (tx_tick) begin
                    txdone   <= 1'b1;
                    tx_state <= TX_IDLE;
                end else tx_cnt <= tx_cnt - 1'b1;
                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    assign tx_o = tx_q;

    // ---------------- Receiver ----------------------------------------------
    reg          rx_sync1, rx_sync2, rx_prev;
    reg [1:0]    rx_state;
    reg [CW-1:0] rx_cnt;
    reg [2:0]    rx_bit;
    reg [7:0]    rx_shift;
    wire         rx_tick = (rx_cnt == {CW{1'b0}});
    wire         rx_fall = rx_prev & ~rx_sync2;
    wire         rx_done = (rx_state == RX_STOP) & rx_tick & rx_sync2;

    always @(posedge clk_i) begin
        if (rst_i) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
            rx_prev  <= 1'b1;
            rx_state <= RX_IDLE;
            rx_cnt   <= {CW{1'b0}};
            rx_bit   <= 3'd0;
            rx_shift <= 8'd0;
        end else begin
            rx_sync1 <= rx_i;
            rx_sync2 <= rx_sync1;
            rx_prev  <= rx_sync2;
            case (rx_state)
                RX_IDLE: if (rx_fall) begin
                    rx_cnt   <= HALF_LAST;  // to mid-start
                    rx_state <= RX_START;
                end
                RX_START: if (rx_tick) begin
                    if (!rx_sync2) begin    // still low at mid-start: real start bit
                        rx_cnt   <= BIT_LAST;
                        rx_bit   <= 3'd0;
                        rx_state <= RX_DATA;
                    end else
                        rx_state <= RX_IDLE; // glitch
                end else rx_cnt <= rx_cnt - 1'b1;
                RX_DATA: if (rx_tick) begin
                    rx_shift <= {rx_sync2, rx_shift[7:1]};
                    rx_cnt   <= BIT_LAST;
                    if (rx_bit == 3'd7) rx_state <= RX_STOP;
                    else                rx_bit   <= rx_bit + 1'b1;
                end else rx_cnt <= rx_cnt - 1'b1;
                RX_STOP: if (rx_tick)
                    rx_state <= RX_IDLE;    // rx_done fires here if the stop bit is 1
                else rx_cnt <= rx_cnt - 1'b1;
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // ---------------- Register updates --------------------------------------
    always @(posedge clk_i) begin
        if (rst_i) begin
            txdata   <= 8'd0;
            rxdata   <= 8'd0;
            transmit <= 1'b0;
            rxdone   <= 1'b0;
        end else begin
            if (wr_txdata) txdata <= bus_wdata_i[7:0];
            transmit <= wr_control & bus_wdata_i[0];   // cleared the cycle after
            if (rx_done) rxdata <= rx_shift;
            rxdone <= rx_done | (rxdone & ~(wr_control & ~bus_wdata_i[1]));
        end
    end

    // ---------------- Read-back chain ---------------------------------------
    reg [31:0] rdata_local;
    always @(*) begin
        case (off)
            OFF_TXDATA:  rdata_local = {24'b0, txdata};
            OFF_RXDATA:  rdata_local = {24'b0, rxdata};
            OFF_CONTROL: rdata_local = {29'b0, txdone, rxdone, transmit};
            default:     rdata_local = 32'b0;
        endcase
    end

    assign bus_rdata_o = bus_rdata_i | (hit ? rdata_local : 32'b0);
endmodule
