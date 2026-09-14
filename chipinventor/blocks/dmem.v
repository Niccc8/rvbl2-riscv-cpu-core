// ============================================================================
// dmem.v - Data SRAM, word-addressed internally, byte-writable via bw_i.
// Synchronous 1-cycle read AND write (Block Guide S4.3, MANDATORY) - the
// registered read is what the no-ALUOut/no-MDR datapath timing relies on.
//
// Block Guide S4.3: "the memory maintains n 4-byte words, where n is the
// total size of the memory in bytes divided by 4", with the architectural
// window fixed at 8kB (Table 13). DMEM_WORDS therefore sets the instantiated
// capacity while the decoder keeps range-checking the full 8kB window; the
// impl_sel guard below is what makes an address inside that window but beyond
// the instantiated array read back 0 and write nothing, instead of aliasing
// into a real word. That guard is also the resize knob: if place-and-route
// cannot absorb 2048 words (65,536 flip-flops), DMEM_WORDS drops to 1024 or
// 512 with no other edit anywhere and no rewiring.
//
// rst_i is unused by this realization and is kept only so the block's port
// list stays stable if a reset-aware memory is substituted later.
// ============================================================================
module dmem #(
    parameter DMEM_WORDS = 2048 // 8kB / 4 bytes-per-word (architectural max)
) (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire [31:0] address_i, // full byte address
    input  wire        we_i,
    input  wire        oe_i,
    input  wire [3:0]  bw_i,
    input  wire [31:0] data_i,
    output wire [31:0] data_o
);
    // Full architectural word index within the 8kB window (Table 13), plus the
    // implemented-range guard.
    wire [10:0] word_addr = address_i[12:2];
    wire        impl_sel  = (word_addr < DMEM_WORDS);

    // (* keep *) prevents synthesis tools from concluding this array is
    // unobservable dead logic. `top` deliberately has zero data outputs
    // (Block Guide S2.2), so a flow that eliminates logic with no path to a
    // primary output would otherwise remove this entire design. Purely a
    // synthesis hint; has no effect on simulation.
    (* keep *) reg [31:0] mem [0:DMEM_WORDS-1];
    localparam AWIDTH = (DMEM_WORDS <= 1) ? 1 : $clog2(DMEM_WORDS);
    wire [AWIDTH-1:0] phys_addr = word_addr[AWIDTH-1:0];

    reg [31:0] data_r;
    assign data_o = data_r;

    always @(posedge clk_i) begin
        if (we_i && impl_sel) begin
            if (bw_i[0]) mem[phys_addr][7:0]   <= data_i[7:0];
            if (bw_i[1]) mem[phys_addr][15:8]  <= data_i[15:8];
            if (bw_i[2]) mem[phys_addr][23:16] <= data_i[23:16];
            if (bw_i[3]) mem[phys_addr][31:24] <= data_i[31:24];
        end else if (oe_i) begin
            data_r <= impl_sel ? mem[phys_addr] : 32'b0;
        end
    end
endmodule
