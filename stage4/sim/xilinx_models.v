`timescale 1ns/1ps
// ============================================================================
// xilinx_models.v - SIMULATION ONLY. Behavioural stand-ins for the two
// UltraScale+ primitives rvbl2_clkgen instantiates, so the CL simulates in
// Icarus Verilog. Never upload this file to the AWS project: Vivado supplies
// the real MMCME4_BASE and BUFG.
//
// MMCME4_BASE: CLKOUT0 period = CLKIN1_PERIOD * CLKOUT0_DIVIDE_F /
// CLKFBOUT_MULT_F (DIVCLK_DIVIDE = 1). LOCKED rises 64 input clocks after RST
// falls; while RST is high the outputs stop. No phase relationship to CLKIN1 is
// modelled: the crossings must work for any phase, and a free-running output
// exercises that.
// ============================================================================
module MMCME4_BASE #(
    parameter real CLKIN1_PERIOD    = 4.0,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F  = 4.0,
    parameter real CLKOUT0_DIVIDE_F = 20.0
) (
    input  wire CLKIN1, RST, PWRDWN, CLKFBIN,
    output wire CLKFBOUT, CLKFBOUTB,
    output reg  CLKOUT0 = 1'b0,
    output wire CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
    output wire CLKOUT4, CLKOUT5, CLKOUT6,
    output reg  LOCKED = 1'b0
);
    localparam real HALF = CLKIN1_PERIOD * CLKOUT0_DIVIDE_F / CLKFBOUT_MULT_F / 2.0;
    integer n = 0;
    always @(posedge CLKIN1 or posedge RST)
        if (RST) begin n = 0; LOCKED <= 1'b0; end
        else if (n < 64) n = n + 1;
        else LOCKED <= 1'b1;
    always begin
        #(HALF);
        if (!RST && n > 8) CLKOUT0 = ~CLKOUT0;
    end
    assign CLKFBOUT = CLKIN1;
    assign {CLKFBOUTB, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
            CLKOUT4, CLKOUT5, CLKOUT6} = 11'b0;
endmodule

module BUFG (input wire I, output wire O);
    assign O = I;
endmodule
