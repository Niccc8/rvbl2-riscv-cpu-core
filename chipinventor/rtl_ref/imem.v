// ============================================================================
// imem.v - Instruction/constant ROM. Combinational read: "Upon receiving the
// memory address to be accessed and a read signal (output enable), the 32-bit
// instruction that was in that position is received by the kernel" (Block
// Guide S4.2 - no cycle-latency language, unlike DMEM's S4.3).
//
// The *architectural* window is the full 4MB at 0x00400000 (Table 13), which
// address_decoder range-checks against. The *instantiated* array is sized to
// IMEM_WORDS so a physical flow does not have to realise a literal 4MB ROM.
// Addresses within the 4MB window but beyond IMEM_WORDS read back 0 rather
// than aliasing into the small physical array - impl_sel below is what
// enforces that.
//
// INIT_FILE must name a real firmware image. With an empty INIT_FILE the ROM
// elaborates as all-zeros and synthesis constant-folds the whole array away,
// producing a netlist with no instruction memory at all; the default below
// and the imem cell-count gate in scripts/synth_yosys_generic.sh exist to
// stop that reaching a physical run.
// ============================================================================
module imem #(
    parameter IMEM_WORDS = 4096,                            // instantiated capacity (16KB @ 4096 words)
    parameter INIT_FILE  = "tests/progs/tb_firmware_prog.hex" // $readmemh ROM image
) (
    input  wire [31:0] address_i,    // full byte address (already imem_sel-gated by decoder)
    input  wire        oe_i,
    output reg  [31:0] data_o
);
    localparam AWIDTH = (IMEM_WORDS <= 1) ? 1 : $clog2(IMEM_WORDS);

    reg [31:0] rom [0:IMEM_WORDS-1];

`ifdef SYNTHESIS
    // Synthesis: a bare, unconditional $readmemh is what lets the tool attach
    // the image to the memory and realise it as ROM logic. Wrapping it in a
    // conditional, or preceding it with a variable-index zero-fill loop, makes
    // the initialisation unresolvable at elaboration - the array then contains
    // nothing, and the whole ROM constant-folds to zero.
    initial $readmemh(INIT_FILE, rom);
`else
    // Simulation: zero-fill first so unpopulated words read as 0 rather than
    // x, and tolerate an empty INIT_FILE for unit tests that write the ROM
    // contents themselves.
    integer k;
    initial begin
        for (k = 0; k < IMEM_WORDS; k = k + 1) rom[k] = 32'b0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, rom);
    end
`endif

    // Full architectural word index within the 4MB window (22-bit byte
    // address -> 20-bit word index).
    wire [19:0] word_addr = address_i[21:2];
    wire        impl_sel  = (word_addr < IMEM_WORDS);

    always @(*) begin
        data_o = (oe_i && impl_sel) ? rom[word_addr[AWIDTH-1:0]] : 32'b0;
    end
endmodule
