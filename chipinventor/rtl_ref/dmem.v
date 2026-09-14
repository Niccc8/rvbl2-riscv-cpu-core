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
// into a real word.
//
// TWO REALIZATIONS, ONE INTERFACE
// ------------------------------
// Default (no define): a behavioral register array. Portable plain Verilog
// with no external dependencies - this is what synthesizes on any flow, and
// what to use where a hard SRAM macro is unavailable.
//
// `define DMEM_USE_SRAM_MACRO: four sky130_sram_2kbyte_1rw1r_32x512_8 OpenRAM
// macros banked to the same 2048x32 window. Roughly halves total cell area and
// makes place-and-route far lighter (65,536 flip-flops become four hard
// blocks), but requires the macro's .v/.lef/.lib/.gds to be available to the
// flow - see macros/README.md. Only the macro branch mentions the macro at
// all, so without the define this file has no dependency on it whatsoever.
//
// Both realizations present identical behaviour at this module's ports for
// every access this core generates; the full testbench suite passes either
// way (scripts/run_all.sh, and again with DMEM_MACRO=1).
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
    // implemented-range guard. Shared by both realizations below.
    wire [10:0] word_addr = address_i[12:2];
    wire        impl_sel  = (word_addr < DMEM_WORDS);

`ifdef DMEM_USE_SRAM_MACRO
    // ------------------------------------------------------------------
    // Hard-macro realization: 4 x 512-word banks = the full 2048x32 window.
    // ------------------------------------------------------------------
    // The macros are fixed at 512 words each, so this branch always provides
    // exactly 2048 words regardless of DMEM_WORDS.
    wire [1:0] bank       = word_addr[10:9];
    wire [8:0] macro_addr = word_addr[8:0];

    // csb0/web0 are active low. A cycle with neither we_i nor oe_i, or an
    // address outside the implemented range, deselects every bank - which is
    // what preserves the "out of range writes nothing" guarantee.
    wire access = impl_sel & (we_i | oe_i);
    wire web_n  = ~we_i;   // low = write, high = read

    wire [127:0] bank_dout;

    sky130_sram_2kbyte_1rw1r_32x512_8 u_sram0 (
        .clk0(clk_i), .csb0(~(access & (bank == 2'd0))), .web0(web_n),
        .wmask0(bw_i), .addr0(macro_addr), .din0(data_i), .dout0(bank_dout[31:0]),
        .clk1(clk_i), .csb1(1'b1), .addr1(9'b0), .dout1()
    );
    sky130_sram_2kbyte_1rw1r_32x512_8 u_sram1 (
        .clk0(clk_i), .csb0(~(access & (bank == 2'd1))), .web0(web_n),
        .wmask0(bw_i), .addr0(macro_addr), .din0(data_i), .dout0(bank_dout[63:32]),
        .clk1(clk_i), .csb1(1'b1), .addr1(9'b0), .dout1()
    );
    sky130_sram_2kbyte_1rw1r_32x512_8 u_sram2 (
        .clk0(clk_i), .csb0(~(access & (bank == 2'd2))), .web0(web_n),
        .wmask0(bw_i), .addr0(macro_addr), .din0(data_i), .dout0(bank_dout[95:64]),
        .clk1(clk_i), .csb1(1'b1), .addr1(9'b0), .dout1()
    );
    sky130_sram_2kbyte_1rw1r_32x512_8 u_sram3 (
        .clk0(clk_i), .csb0(~(access & (bank == 2'd3))), .web0(web_n),
        .wmask0(bw_i), .addr0(macro_addr), .din0(data_i), .dout0(bank_dout[127:96]),
        .clk1(clk_i), .csb1(1'b1), .addr1(9'b0), .dout1()
    );

    // Read data arrives one cycle after the address is presented, so the bank
    // mux must be driven by the bank that was selected when the read was
    // issued - not the one being presented now. Deselected macros drive X, so
    // this has to be a real select, never an OR of the four outputs.
    reg [1:0] bank_q;
    reg       read_q;
    always @(posedge clk_i) begin
        if (rst_i) begin
            bank_q <= 2'd0;
            read_q <= 1'b0;
        end else begin
            bank_q <= bank;
            read_q <= impl_sel & oe_i & ~we_i;
        end
    end

    assign data_o = read_q ? bank_dout[32*bank_q +: 32] : 32'b0;

`else
    // ------------------------------------------------------------------
    // Behavioral realization (default): a register array.
    // ------------------------------------------------------------------
    // (* keep *) prevents synthesis tools from concluding this array is
    // unobservable dead logic. `top` deliberately has zero data outputs
    // (Block Guide S2.2), so a naive RTL-to-gate flow that eliminates logic
    // with no path to a primary output would otherwise remove this entire
    // design. Purely a synthesis hint; has no effect on simulation.
    (* keep *) reg [31:0] mem [0:DMEM_WORDS-1];
    localparam AWIDTH = (DMEM_WORDS <= 1) ? 1 : $clog2(DMEM_WORDS);
    wire [AWIDTH-1:0] phys_addr = word_addr[AWIDTH-1:0];

    reg [31:0] data_r;
    assign data_o = data_r;

    // Simulation-only zero-fill for waveform determinism. Fenced off from
    // synthesis so it cannot attach init values to 65,536 flip-flops that
    // deliberately have no hardware reset network. Synthesis must therefore
    // define SYNTHESIS - scripts/synth_yosys_generic.sh passes -DSYNTHESIS and
    // openlane/config.json sets SYNTH_DEFINES for the same reason.
`ifndef SYNTHESIS
    integer k;
    initial begin
        for (k = 0; k < DMEM_WORDS; k = k + 1) mem[k] = 32'b0;
    end
`endif

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
`endif
endmodule
