// ============================================================================
// crc_unit.v - CRCB/CRCH/CRCW (Xicrc). Combinational, zero-latency
//
// Structure follows Block Guide S3.1.3: three independent CRC
// blocks, one per input width (8 / 16 / 32 bits), each an algebraically
// unrolled parallel-XOR network, feeding a single output multiplexer
// selected per Table 11. Each block's `for` loop has constant bounds, so it
// flattens at elaboration into a flat XOR tree with no per-stage bypass
// muxing and no variable bit-selects.
//
// Algorithm: CRC-16-CCITT-FALSE (poly 0x1021, MSB-first, no input/output
// reflection, no final XOR), confirmed against the official validation
// firmware - all three widths chain to its expected 0x1E82.
//
// OPERAND ROLES (rs1 = data, rs2 = accumulator)
// -------------------------------------------------------------------
// The official validation firmware accumulates the CRC in rs2 and passes the
// new data in rs1:
//
//     crcb s0, s1, s0     # rd=s0, rs1=s1 (data byte), rs2=s0 (CRC so far)
//
// CRCB/CRCH/CRCW select how many bits of rs1 (8/16/32, MSB-first) are folded
// into one CRC-16 update - one shared CRC-16 algorithm over three input
// widths, not three different CRC algorithms.
// ============================================================================
module crc_unit (
    input  wire [31:0] rs1_data, // data to fold in
    input  wire [31:0] rs2_data, // running CRC / seed (low 16 bits used)
    input  wire [2:0]  funct3,   // 000=CRCB(8b) 001=CRCH(16b) 010=CRCW(32b)
    output reg  [31:0] result
);
    localparam [15:0] CRC16_POLY = 16'h1021;

    // One bit-serial LFSR step, MSB-first. Unrolling this over a constant
    // number of data bits is what turns the bit-serial definition into the
    // combinational XOR network each of the three blocks below is.
    function [15:0] crc16_step;
        input [15:0] crc_in;
        input        data_bit;
        reg          fb;
        begin
            fb = crc_in[15] ^ data_bit;
            crc16_step = {crc_in[14:0], 1'b0} ^ (fb ? CRC16_POLY : 16'h0000);
        end
    endfunction

    // ---- Block 1: CRCB, 8-bit input ------------------------------------
    function [15:0] crc16_b;
        input [15:0] seed;
        input [7:0]  data;
        integer i;
        reg [15:0] c;
        begin
            c = seed;
            for (i = 7; i >= 0; i = i - 1) c = crc16_step(c, data[i]);
            crc16_b = c;
        end
    endfunction

    // ---- Block 2: CRCH, 16-bit input -----------------------------------
    function [15:0] crc16_h;
        input [15:0] seed;
        input [15:0] data;
        integer i;
        reg [15:0] c;
        begin
            c = seed;
            for (i = 15; i >= 0; i = i - 1) c = crc16_step(c, data[i]);
            crc16_h = c;
        end
    endfunction

    // ---- Block 3: CRCW, 32-bit input -----------------------------------
    function [15:0] crc16_w;
        input [15:0] seed;
        input [31:0] data;
        integer i;
        reg [15:0] c;
        begin
            c = seed;
            for (i = 31; i >= 0; i = i - 1) c = crc16_step(c, data[i]);
            crc16_w = c;
        end
    endfunction

    wire [15:0] seed  = rs2_data[15:0];
    wire [15:0] crc_b = crc16_b(seed, rs1_data[7:0]);
    wire [15:0] crc_h = crc16_h(seed, rs1_data[15:0]);
    wire [15:0] crc_w = crc16_w(seed, rs1_data[31:0]);

    // ---- Output multiplexer (Block Guide Table 11) ----------------------
    always @(*) begin
        case (funct3[1:0])
            2'b00:   result = {16'b0, crc_b}; // CRCB
            2'b01:   result = {16'b0, crc_h}; // CRCH
            2'b10:   result = {16'b0, crc_w}; // CRCW
            default: result = {16'b0, seed};  // unused encoding: seed passes through
        endcase
    end
endmodule
