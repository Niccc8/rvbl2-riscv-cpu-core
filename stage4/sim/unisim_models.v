// ============================================================================
// unisim_models.v - SIMULATION/LINT ONLY. Cycle-based stand-ins for the three
// UltraScale+ primitives riscv.sv may instantiate, for Verilator (no delays).
// Never upload: Vivado supplies the real MMCME4_BASE, BUFG and BUFGCE_DIV.
//
// MMCME4_BASE: CLKOUT0 = CLKIN1 x CLKFBOUT_MULT_F / CLKOUT0_DIVIDE_F, made by
// counting input edges (integer ratio only, here 32 / 4 = 8), phase-aligned to
// CLKIN1. LOCKED rises 64 input cycles after RST falls; until then CLKOUT0 is
// held low, as the real MMCM's outputs are before lock.
// ============================================================================
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module MMCME4_BASE #(
    parameter real    CLKIN1_PERIOD    = 4.0,
    parameter integer DIVCLK_DIVIDE    = 1,
    parameter real    CLKFBOUT_MULT_F  = 4.0,
    parameter real    CLKOUT0_DIVIDE_F = 32.0
) (
    input  wire CLKIN1,
    input  wire RST,
    input  wire PWRDWN,
    input  wire CLKFBIN,
    output wire CLKFBOUT,
    output reg  CLKOUT0,
    output reg  LOCKED
);
    localparam integer RATIO = $rtoi(CLKOUT0_DIVIDE_F / CLKFBOUT_MULT_F + 0.5);
    localparam integer HALF  = RATIO / 2;
    reg [7:0] lock_n = 8'd0;
    reg [7:0] div_n  = 8'd0;
    initial begin CLKOUT0 = 1'b0; LOCKED = 1'b0; end
    always @(posedge CLKIN1) begin
        if (RST) begin
            lock_n <= 8'd0; LOCKED <= 1'b0; CLKOUT0 <= 1'b0; div_n <= 8'd0;
        end else begin
            if (lock_n < 8'd64) lock_n <= lock_n + 8'd1;
            else                LOCKED <= 1'b1;
            if (lock_n >= 8'd16) begin
                if (div_n == HALF[7:0] - 8'd1) begin div_n <= 8'd0; CLKOUT0 <= ~CLKOUT0; end
                else div_n <= div_n + 8'd1;
            end
        end
    end
    assign CLKFBOUT = CLKIN1;
endmodule

module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

module BUFGCE_DIV #(parameter integer BUFGCE_DIVIDE = 8) (
    input  wire I,
    input  wire CE,
    input  wire CLR,
    output reg  O
);
    reg [3:0] n = 4'd0;
    initial O = 1'b0;
    always @(posedge I) begin
        if (CLR) begin n <= 4'd0; O <= 1'b0; end
        else if (CE) begin
            if (n == BUFGCE_DIVIDE[3:0] / 2 - 4'd1) begin n <= 4'd0; O <= ~O; end
            else n <= n + 4'd1;
        end
    end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
