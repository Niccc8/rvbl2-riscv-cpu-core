// ============================================================================
// Simulation wrapper for the OpenRAM behavioral model.
//
// The vendor model (sky130_sram_2kbyte_1rw1r_32x512_8.v) carries no `timescale
// directive of its own, but its read path depends on delays:
//
//     #(T_HOLD) dout0 = 32'bx;              // T_HOLD = 1
//     dout0 <= #(DELAY) mem[addr0_reg];     // DELAY  = 3
//
// Compiled without a timescale in scope those resolve against the simulator's
// default unit rather than the testbench's, which pushes the read data far
// beyond the end of the run - dout0 simply stays X forever, and the model's own
// read/write $display tracing never executes either, because the blocking
// #(T_HOLD) never completes. The symptom is every DMEM read returning X with no
// other diagnostic.
//
// Including the vendor file here, behind a timescale that matches the
// testbenches (1ns/1ps), fixes that without editing the vendor source, so the
// macro stays byte-identical to what upstream ships. Compile this file instead
// of the raw model for simulation; synthesis and place-and-route use the .lef
// and .lib, and never see either file.
// ============================================================================
`timescale 1ns/1ps
`include "macros/sky130_sram_2kbyte_1rw1r_32x512_8.v"
