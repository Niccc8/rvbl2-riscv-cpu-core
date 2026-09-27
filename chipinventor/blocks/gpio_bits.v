// ============================================================================
// gpio_bits.v - splits gpio's 8-bit pin buses into the single bits the canvas
// Inout Pins need, and gathers the eight pad levels back into gpio_i.
//
// ChipInventor cannot slice a bus in a wire, and one Inout Pin has a single
// enable (D) for its whole width, so per-pin direction needs eight 1-bit pins.
// Wire each pin pins_io_n like this:
//
//     cN_o -> C (data)      dN_o -> D (enable)      right terminal -> pN_i
//
// The platform then emits `assign pins_io_n = dN ? cN : 1'bZ;` - Figure 1's
// output tri-state, enabled by DATADIR[n] and driving DATAOUT[n]. Swapping C
// and D still compiles, but the pin would then drive whenever DATAOUT[n] = 1,
// even as an input; check_export.py fails that polarity explicitly.
//
// Pure wiring: no logic, no state.
// ============================================================================
module gpio_bits (
    input  wire [7:0] gpio_o,    // from gpio.gpio_o  (DATAOUT)
    input  wire [7:0] gpio_oe,   // from gpio.gpio_oe (DATADIR)
    input  wire       p0_i,
    input  wire       p1_i,
    input  wire       p2_i,
    input  wire       p3_i,
    input  wire       p4_i,
    input  wire       p5_i,
    input  wire       p6_i,
    input  wire       p7_i,
    output wire [7:0] gpio_i,    // to gpio.gpio_i
    output wire       c0_o,
    output wire       d0_o,
    output wire       c1_o,
    output wire       d1_o,
    output wire       c2_o,
    output wire       d2_o,
    output wire       c3_o,
    output wire       d3_o,
    output wire       c4_o,
    output wire       d4_o,
    output wire       c5_o,
    output wire       d5_o,
    output wire       c6_o,
    output wire       d6_o,
    output wire       c7_o,
    output wire       d7_o
);
    assign {c7_o, c6_o, c5_o, c4_o, c3_o, c2_o, c1_o, c0_o} = gpio_o;
    assign {d7_o, d6_o, d5_o, d4_o, d3_o, d2_o, d1_o, d0_o} = gpio_oe;
    assign gpio_i = {p7_i, p6_i, p5_i, p4_i, p3_i, p2_i, p1_i, p0_i};
endmodule
