// ============================================================================
// tb_dmem_probe.vh - hierarchical access to a DMEM word from a testbench,
// independent of which dmem realization was compiled in.
//
// `top` has no data pins (Block Guide S2.2), so every DMEM check in this
// repository reaches into the array by hierarchical reference. That path
// differs between the two realizations: the behavioral build has one flat
// `mem` array, while the macro build splits the same 2048-word window across
// four 512-word OpenRAM banks.
//
// Only bank 0 (words 0-511, byte addresses 0x10010000-0x100107FC) is reachable
// through this helper. That covers every word the testbenches here check - the
// firmware signature array tops out at word 121 - but a new test that writes
// above word 511 needs the bank selected explicitly.
//
// Usage: `DMEM_WORD(dut.u_dmem, 0)
// ============================================================================
`ifdef DMEM_USE_SRAM_MACRO
  `define DMEM_WORD(path, idx) path.u_sram0.mem[idx]
`else
  `define DMEM_WORD(path, idx) path.mem[idx]
`endif
