

//  ---------- INLCUDED BLOCK: address_decoder  ---------- 
// ============================================================================
// address_decoder.v - routes the core's single memory-transaction interface
// to IMEM or DMEM based on address range, and muxes read data back.
//
// Every signal routed to a memory is explicitly qualified by that memory's
// own select (imem_sel / dmem_sel) - NOT just "routed to DMEM" in general -
// otherwise an out-of-range store could alias into a real DMEM write
// ============================================================================
module address_decoder (
    input  wire [31:0] address_i,
    input  wire        we_i,
    input  wire        oe_i,
    input  wire [3:0]  bw_i,
    input  wire [31:0] imem_rdata,
    input  wire [31:0] dmem_rdata,
    output wire        imem_oe_o,
    output wire        dmem_we_o,
    output wire        dmem_oe_o,
    output wire [3:0]  dmem_bw_o,
    output wire [31:0] data_o
);
    localparam [31:0] IMEM_BASE = 32'h0040_0000;
    localparam [31:0] IMEM_LAST = 32'h007F_FFFF; // 4MB architectural window
    localparam [31:0] DMEM_BASE = 32'h1001_0000;
    localparam [31:0] DMEM_LAST = 32'h1001_1FFF; // 8kB window

    wire imem_sel = (address_i >= IMEM_BASE) && (address_i <= IMEM_LAST);
    wire dmem_sel = (address_i >= DMEM_BASE) && (address_i <= DMEM_LAST);

    // IMEM has no write port at all (Block Guide §4.4) - we_o never routed there.
    assign imem_oe_o = oe_i & imem_sel;
    assign dmem_oe_o = oe_i & dmem_sel;
    assign dmem_we_o = we_i & dmem_sel;
    assign dmem_bw_o = bw_i & {4{dmem_sel}};

    assign data_o = dmem_sel ? dmem_rdata : (imem_sel ? imem_rdata : 32'b0);
endmodule



//  ---------- INLCUDED BLOCK: alu  ---------- 
// ============================================================================
// alu.v - Arithmetic/Logic Unit
// Implements Block Guide Table 9 (11 ops). Shared by ALU-reg, ALU-imm,
// LUI (PASS_B), AUIPC/branch-target/jump-target/load-store address (ADD).
// Purely combinational.
// ============================================================================
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result
);
    localparam [3:0]
        ALU_PASS_B = 4'h0,
        ALU_ADD    = 4'h1,
        ALU_SUB    = 4'h2,
        ALU_AND    = 4'h3,
        ALU_OR     = 4'h4,
        ALU_XOR    = 4'h5,
        ALU_SLL    = 4'h6,
        ALU_SRL    = 4'h7,
        ALU_SRA    = 4'h8, // "MRS" in Block Guide Table 9
        ALU_SLT    = 4'h9,
        ALU_SLTU   = 4'hA;

    always @(*) begin
        case (alu_op)
            ALU_PASS_B: result = b;
            ALU_ADD:    result = a + b;
            ALU_SUB:    result = a - b;
            ALU_AND:    result = a & b;
            ALU_OR:     result = a | b;
            ALU_XOR:    result = a ^ b;
            ALU_SLL:    result = a << b[4:0];
            ALU_SRL:    result = a >> b[4:0];
            ALU_SRA:    result = $signed(a) >>> b[4:0];
            ALU_SLT:    result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU:   result = (a < b) ? 32'd1 : 32'd0;
            default:    result = 32'd0; // safe default, no latch
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: branch_comparator  ---------- 
// ============================================================================
// branch_comparator.v - evaluates the 6 RV32I branch conditions.
// Purely combinational, kept separate from the ALU.
// ============================================================================
module branch_comparator (
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [2:0]  funct3,
    output reg         branch_taken
);
    always @(*) begin
        case (funct3)
            3'b000: branch_taken = (rs1_data == rs2_data);                       // BEQ
            3'b001: branch_taken = (rs1_data != rs2_data);                       // BNE
            3'b100: branch_taken = ($signed(rs1_data) <  $signed(rs2_data));     // BLT
            3'b101: branch_taken = ($signed(rs1_data) >= $signed(rs2_data));     // BGE
            3'b110: branch_taken = (rs1_data <  rs2_data);                       // BLTU
            3'b111: branch_taken = (rs1_data >= rs2_data);                       // BGEU
            default: branch_taken = 1'b0; // funct3 010/011 unused by RV32I branches
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: control_unit  ---------- 
// ============================================================================
// control_unit.v - Central FSM. Decodes instruction class from `ir` (full
// {opcode,funct3,funct7} tuple matching, not opcode alone), sequences
// the 6 states, and generates every datapath control signal.
//
// States: RESET, FETCH, DECODE, EXECUTE, MEMORY, WRITEBACK.
// Cycle counts: branch=3, store=4, ALU/mul/crc/jump/fence/
// ecall/ebreak/illegal=4, load=5.
//
// Every combinational output is gated by rst_i directly (not only via the
// state register having reached RESET) so an in-flight operation is
// aborted the same cycle reset asserts, not one cycle later.
// ============================================================================
module control_unit (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire [31:0] ir,
    input  wire        branch_taken,

    output wire [2:0]  state_o,

    output wire        alu_src_a_sel,   // 0=rs1_data, 1=pc
    output wire        alu_src_b_sel,   // 0=rs2_data, 1=imm
    output reg  [3:0]  alu_op,
    output wire        addr_src_sel,    // 0=pc, 1=alu_result
    output reg  [2:0]  wb_src_sel,      // 000=alu 001=mult 010=crc 011=lsu_load 100=pc+4
    output wire        pc_src_sel,      // 0=pc+4, 1=alu_result(target)

    output wire        pc_write,
    output wire        reg_write,
    output wire        we_o,
    output wire        oe_o,
    output wire        ir_write,
    output wire sys_event_o,

    output wire        is_valid_store,
    output wire [2:0]  op_size
);
    localparam [2:0]
        S_RESET     = 3'd0,
        S_FETCH     = 3'd1,
        S_DECODE    = 3'd2,
        S_EXECUTE   = 3'd3,
        S_MEMORY    = 3'd4,
        S_WRITEBACK = 3'd5;

    // (* keep *) - see dmem.v for why this is needed (zero-output top level).
    (* keep *) reg [2:0] state, next_state;
    assign state_o = state;

    // ---------------- Instruction fields --------------------------------
    wire [6:0]  opcode = ir[6:0];
    wire [2:0]  funct3 = ir[14:12];
    wire [6:0]  funct7 = ir[31:25];

    // ---------------- Full-tuple instruction class decode (§9.1) --------
    wire op_rtype  = (opcode == 7'b0110011);
    wire op_itype  = (opcode == 7'b0010011);
    wire op_load   = (opcode == 7'b0000011);
    wire op_store  = (opcode == 7'b0100011);
    wire op_branch = (opcode == 7'b1100011);
    wire op_jal    = (opcode == 7'b1101111);
    wire op_jalr   = (opcode == 7'b1100111);
    wire op_lui    = (opcode == 7'b0110111);
    wire op_auipc  = (opcode == 7'b0010111);
    wire op_fence  = (opcode == 7'b0001111);

    // ALU-reg: funct7=0000000 for all 8 base funct3 values; SUB(000)/SRA(101)
    // may additionally use funct7=0100000. Any other funct7 is illegal.
    wire alu_reg_f7_ok = (funct7 == 7'b0000000) ||
                         ((funct7 == 7'b0100000) && (funct3 == 3'b000 || funct3 == 3'b101));
    wire is_alu_reg = op_rtype && alu_reg_f7_ok;

    wire is_mul = op_rtype && (funct7 == 7'b0000001) && !funct3[2]; // Zmmul: funct3 000-011 only
    wire is_crc = op_rtype && (funct7 == 7'b1000000) &&
                  (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010);

    // ALU-imm: SLLI/SRLI/SRAI need imm[11:5] to be exactly 0000000/0100000;
    // every other funct3 has no funct7-equivalent constraint.
    wire shift_f7_ok = (funct3 == 3'b001) ? (ir[31:25] == 7'b0000000)
                                          : ((ir[31:25] == 7'b0000000) || (ir[31:25] == 7'b0100000));
    wire is_shift_imm = (funct3 == 3'b001) || (funct3 == 3'b101);
    wire is_alu_imm = op_itype && (!is_shift_imm || shift_f7_ok);

    wire is_load  = op_load  && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010 ||
                                  funct3 == 3'b100 || funct3 == 3'b101);
    wire is_store = op_store && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010);
    wire is_branch = op_branch && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b100 ||
                                    funct3 == 3'b101 || funct3 == 3'b110 || funct3 == 3'b111);
    wire is_jal  = op_jal;
    wire is_jalr = op_jalr && (funct3 == 3'b000);
    wire is_lui  = op_lui;
    wire is_auipc = op_auipc;
    // ECALL/EBREAK are single fixed encodings in RV32I - match them exactly
    // (rs1/rd/funct7 all zero) so no other SYSTEM-opcode word can pulse
    // sys_event_o and be mistaken for a firmware validation checkpoint.
    wire is_ecall_ebreak = (ir == 32'h0000_0073) || (ir == 32'h0010_0073);
    wire is_fence = op_fence; // NOP regardless of fm/pred/succ fields

    wire is_recognized = is_alu_reg || is_mul || is_crc || is_alu_imm || is_load || is_store ||
                         is_branch || is_jal || is_jalr || is_lui || is_auipc ||
                         is_ecall_ebreak || is_fence;
    wire is_illegal = ~is_recognized;

    assign is_valid_store = is_store;
    assign op_size = funct3;

    // ---------------- ALU op select (Table 9 decode) ---------------------
    always @(*) begin
        if (is_alu_reg) begin
            case (funct3)
                3'b000:  alu_op = funct7[5] ? 4'h2 : 4'h1; // SUB : ADD
                3'b001:  alu_op = 4'h6;                    // SLL
                3'b010:  alu_op = 4'h9;                    // SLT
                3'b011:  alu_op = 4'hA;                    // SLTU
                3'b100:  alu_op = 4'h5;                    // XOR
                3'b101:  alu_op = funct7[5] ? 4'h8 : 4'h7; // SRA : SRL
                3'b110:  alu_op = 4'h4;                    // OR
                3'b111:  alu_op = 4'h3;                    // AND
                default: alu_op = 4'h0;
            endcase
        end else if (is_alu_imm) begin
            case (funct3)
                3'b000:  alu_op = 4'h1; // ADDI
                3'b010:  alu_op = 4'h9; // SLTI
                3'b011:  alu_op = 4'hA; // SLTIU
                3'b100:  alu_op = 4'h5; // XORI
                3'b110:  alu_op = 4'h4; // ORI
                3'b111:  alu_op = 4'h3; // ANDI
                3'b001:  alu_op = 4'h6; // SLLI
                3'b101:  alu_op = ir[30] ? 4'h8 : 4'h7; // SRAI : SRLI
                default: alu_op = 4'h0;
            endcase
        end else if (is_lui) begin
            alu_op = 4'h0; // PASS_B
        end else begin
            alu_op = 4'h1; // ADD: AUIPC / branch target / jump target / load-store addr / JALR
        end
    end

    // ---------------- Datapath mux selects --------------------------------
    assign alu_src_a_sel = is_auipc || is_branch || is_jal;         // else rs1_data (incl. JALR)
    assign alu_src_b_sel = ~(is_alu_reg || is_mul || is_crc);       // else rs2_data

    assign addr_src_sel = (state == S_EXECUTE && (is_load || is_store)) ||
                          (state == S_MEMORY) ||
                          (state == S_WRITEBACK && is_load);

    always @(*) begin
        if (is_mul)              wb_src_sel = 3'b001;
        else if (is_crc)         wb_src_sel = 3'b010;
        else if (is_load)        wb_src_sel = 3'b011;
        else if (is_jal||is_jalr) wb_src_sel = 3'b100;
        else                     wb_src_sel = 3'b000; // ALU-class default
    end

    assign pc_src_sel = (is_branch && branch_taken) || is_jal || is_jalr;

    // ---------------- State register --------------------------------------
    always @(posedge clk_i) begin
        if (rst_i) state <= S_RESET;
        else       state <= next_state;
    end

    // ---------------- Next-state logic (§8.2) ------------------------------
    always @(*) begin
        case (state)
            S_RESET:     next_state = S_FETCH;
            S_FETCH:     next_state = S_DECODE;
            S_DECODE:    next_state = S_EXECUTE;
            S_EXECUTE: begin
                if (is_load || is_store) next_state = S_MEMORY;
                else if (is_branch)      next_state = S_FETCH;
                else                      next_state = S_WRITEBACK;
            end
            S_MEMORY: begin
                if (is_load) next_state = S_WRITEBACK;
                else         next_state = S_FETCH; // store
            end
            S_WRITEBACK: next_state = S_FETCH;
            default:     next_state = S_FETCH;
        endcase
    end

    // ---------------- Output logic, gated by rst_i directly (§9.1 fix) -----
    // FSM guarantees only branch reaches EXECUTE-terminal, only store
    // reaches MEMORY-terminal, and every other class (incl. load) reaches
    // WRITEBACK - so "state==S_WRITEBACK" alone is sufficient for those.
    assign ir_write = ~rst_i && (state == S_FETCH);

    assign pc_write = ~rst_i && ( (state == S_EXECUTE && is_branch) ||
                                  (state == S_MEMORY  && is_store) ||
                                  (state == S_WRITEBACK) );

    assign reg_write = ~rst_i && (state == S_WRITEBACK) &&
                       !(is_fence || is_illegal || is_ecall_ebreak);

    assign we_o = ~rst_i && (state == S_MEMORY) && is_store;

    assign oe_o = ~rst_i && ( (state == S_FETCH) ||
                              (state == S_MEMORY   && is_load) ||
                              (state == S_WRITEBACK && is_load) );

    assign sys_event_o = ~rst_i && (state == S_EXECUTE) && is_ecall_ebreak;

endmodule



//  ---------- INLCUDED BLOCK: crc_unit  ---------- 
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



//  ---------- INLCUDED BLOCK: dmem  ---------- 
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



//  ---------- INLCUDED BLOCK: imem  ---------- 
// ============================================================================
// imem.v - Instruction/constant ROM. Combinational read: "Upon receiving the
// memory address to be accessed and a read signal (output enable), the 32-bit
// instruction that was in that position is received by the kernel" (Block
// Guide S4.2 - no cycle-latency language, unlike DMEM's S4.3).
//
// The official firmware MUST stay at word 0: it is position-dependent, and
// derives its .bss base from the PC (auipc s0, 0xfc10 at 0x0040011C gives
// 0x10010000, which is DMEM_BASE). The supplementary program is
// position-independent and is placed above it.
//
// The *architectural* window is the full 4MB at 0x00400000 (Table 13), which
// address_decoder range-checks against. The ROM below covers only the words
// the images actually occupy; any address inside the 4MB window but past or
// between them falls to the `default` leg and reads back 0 rather than
// aliasing into a real word. That is the same guarantee the file-driven
// version's impl_sel comparison gave.
// ============================================================================
module imem (
    input  wire [31:0] address_i,    // full byte address (already imem_sel-gated by decoder)
    input  wire        oe_i,
    output reg  [31:0] data_o
);
    // Word index within the 4MB architectural window (22-bit byte address ->
    // 20-bit word index), exactly as the file-driven version computed it.
    wire [19:0] word_addr = address_i[21:2];

    always @(*) begin
        if (!oe_i) data_o = 32'b0;
        else begin
            case (word_addr)
                20'd0     : data_o = 32'h123452b7;
                20'd1     : data_o = 32'h12345337;
                20'd2     : data_o = 32'h3e629463;
                20'd3     : data_o = 32'h00001297;
                20'd4     : data_o = 32'h3e028063;
                20'd5     : data_o = 32'h00a00293;
                20'd6     : data_o = 32'hffd28313;
                20'd7     : data_o = 32'h00700393;
                20'd8     : data_o = 32'h3c731863;
                20'd9     : data_o = 32'h006283b3;
                20'd10    : data_o = 32'h01100e13;
                20'd11    : data_o = 32'h3dc39263;
                20'd12    : data_o = 32'h405e03b3;
                20'd13    : data_o = 32'h3a639e63;
                20'd14    : data_o = 32'h0ff00293;
                20'd15    : data_o = 32'h0f02c313;
                20'd16    : data_o = 32'h00f00393;
                20'd17    : data_o = 32'h3a731663;
                20'd18    : data_o = 32'h7002e313;
                20'd19    : data_o = 32'h7ff00393;
                20'd20    : data_o = 32'h3a731063;
                20'd21    : data_o = 32'h0f02f313;
                20'd22    : data_o = 32'h0f000393;
                20'd23    : data_o = 32'h38731a63;
                20'd24    : data_o = 32'h0aa00293;
                20'd25    : data_o = 32'h05500313;
                20'd26    : data_o = 32'h0062c3b3;
                20'd27    : data_o = 32'h0ff00e13;
                20'd28    : data_o = 32'h39c39063;
                20'd29    : data_o = 32'h0062e3b3;
                20'd30    : data_o = 32'h37c39c63;
                20'd31    : data_o = 32'h0062f3b3;
                20'd32    : data_o = 32'h36039863;
                20'd33    : data_o = 32'h00100293;
                20'd34    : data_o = 32'h00429313;
                20'd35    : data_o = 32'h01000393;
                20'd36    : data_o = 32'h36731063;
                20'd37    : data_o = 32'h0023d313;
                20'd38    : data_o = 32'h00400e13;
                20'd39    : data_o = 32'h35c31a63;
                20'd40    : data_o = 32'hff000293;
                20'd41    : data_o = 32'h4022d313;
                20'd42    : data_o = 32'hffc00393;
                20'd43    : data_o = 32'h34731263;
                20'd44    : data_o = 32'h00100293;
                20'd45    : data_o = 32'h00400313;
                20'd46    : data_o = 32'h006293b3;
                20'd47    : data_o = 32'h01000e13;
                20'd48    : data_o = 32'h33c39863;
                20'd49    : data_o = 32'h00200313;
                20'd50    : data_o = 32'h006e53b3;
                20'd51    : data_o = 32'h00400e93;
                20'd52    : data_o = 32'h33d39063;
                20'd53    : data_o = 32'hff000293;
                20'd54    : data_o = 32'h4062d3b3;
                20'd55    : data_o = 32'hffc00e93;
                20'd56    : data_o = 32'h31d39863;
                20'd57    : data_o = 32'h00a00293;
                20'd58    : data_o = 32'h0142a313;
                20'd59    : data_o = 32'h00100393;
                20'd60    : data_o = 32'h30731063;
                20'd61    : data_o = 32'hff600293;
                20'd62    : data_o = 32'h0142b313;
                20'd63    : data_o = 32'h2e031a63;
                20'd64    : data_o = 32'h00a00293;
                20'd65    : data_o = 32'h01400313;
                20'd66    : data_o = 32'h0062a3b3;
                20'd67    : data_o = 32'h00100e13;
                20'd68    : data_o = 32'h2fc39063;
                20'd69    : data_o = 32'h005333b3;
                20'd70    : data_o = 32'h2c039c63;
                20'd71    : data_o = 32'h0fc10417;
                20'd72    : data_o = 32'hee440413;
                20'd73    : data_o = 32'h12345337;
                20'd74    : data_o = 32'h67830313;
                20'd75    : data_o = 32'h00642023;
                20'd76    : data_o = 32'h0000b3b7;
                20'd77    : data_o = 32'habb38393;
                20'd78    : data_o = 32'h00741223;
                20'd79    : data_o = 32'h0cc00e13;
                20'd80    : data_o = 32'h01c40423;
                20'd81    : data_o = 32'h00042e83;
                20'd82    : data_o = 32'h2a6e9463;
                20'd83    : data_o = 32'h00441f03;
                20'd84    : data_o = 32'hffffbfb7;
                20'd85    : data_o = 32'habbf8f93;
                20'd86    : data_o = 32'h29ff1c63;
                20'd87    : data_o = 32'h00445f03;
                20'd88    : data_o = 32'h0000bfb7;
                20'd89    : data_o = 32'habbf8f93;
                20'd90    : data_o = 32'h29ff1463;
                20'd91    : data_o = 32'h00840f03;
                20'd92    : data_o = 32'hfcc00f93;
                20'd93    : data_o = 32'h27ff1e63;
                20'd94    : data_o = 32'h00844f03;
                20'd95    : data_o = 32'h0cc00f93;
                20'd96    : data_o = 32'h27ff1863;
                20'd97    : data_o = 32'h00500293;
                20'd98    : data_o = 32'h00a00313;
                20'd99    : data_o = 32'h00500393;
                20'd100   : data_o = 32'hff600e13;
                20'd101   : data_o = 32'hff600e93;
                20'd102   : data_o = 32'h00728463;
                20'd103   : data_o = 32'h2540006f;
                20'd104   : data_o = 32'h01de0463;
                20'd105   : data_o = 32'h24c0006f;
                20'd106   : data_o = 32'h00629463;
                20'd107   : data_o = 32'h2440006f;
                20'd108   : data_o = 32'h01c29463;
                20'd109   : data_o = 32'h23c0006f;
                20'd110   : data_o = 32'h0062c463;
                20'd111   : data_o = 32'h2340006f;
                20'd112   : data_o = 32'h005e4463;
                20'd113   : data_o = 32'h22c0006f;
                20'd114   : data_o = 32'h00535463;
                20'd115   : data_o = 32'h2240006f;
                20'd116   : data_o = 32'h01c2d463;
                20'd117   : data_o = 32'h21c0006f;
                20'd118   : data_o = 32'h0062e463;
                20'd119   : data_o = 32'h2140006f;
                20'd120   : data_o = 32'h01c2e463;
                20'd121   : data_o = 32'h20c0006f;
                20'd122   : data_o = 32'h00537463;
                20'd123   : data_o = 32'h2040006f;
                20'd124   : data_o = 32'h005e7463;
                20'd125   : data_o = 32'h1fc0006f;
                20'd126   : data_o = 32'h00800f6f;
                20'd127   : data_o = 32'h1f40006f;
                20'd128   : data_o = 32'h00000f97;
                20'd129   : data_o = 32'h010f8f93;
                20'd130   : data_o = 32'h000f8067;
                20'd131   : data_o = 32'h1e40006f;
                20'd132   : data_o = 32'h00100013;
                20'd133   : data_o = 32'h1c001e63;
                20'd134   : data_o = 32'hdeadc2b7;
                20'd135   : data_o = 32'heef28293;
                20'd136   : data_o = 32'h00028313;
                20'd137   : data_o = 32'h00030393;
                20'd138   : data_o = 32'h00038f93;
                20'd139   : data_o = 32'hdeadc2b7;
                20'd140   : data_o = 32'heef28293;
                20'd141   : data_o = 32'h1a5f9e63;
                20'd142   : data_o = 32'h000185b7;
                20'd143   : data_o = 32'h6a058593;
                20'd144   : data_o = 32'h00200613;
                20'd145   : data_o = 32'hee6b36b7;
                20'd146   : data_o = 32'h80068693;
                20'd147   : data_o = 32'h000312b7;
                20'd148   : data_o = 32'hd4028293;
                20'd149   : data_o = 32'hdcd65337;
                20'd150   : data_o = 32'hfff00393;
                20'd151   : data_o = 32'h00100e13;
                20'd152   : data_o = 32'h02c58533;
                20'd153   : data_o = 32'h18551663;
                20'd154   : data_o = 32'h02c68533;
                20'd155   : data_o = 32'h18651263;
                20'd156   : data_o = 32'h02c59533;
                20'd157   : data_o = 32'h16051e63;
                20'd158   : data_o = 32'h02c69533;
                20'd159   : data_o = 32'h16751a63;
                20'd160   : data_o = 32'h02c6b533;
                20'd161   : data_o = 32'h17c51663;
                20'd162   : data_o = 32'h02c6a533;
                20'd163   : data_o = 32'h16751263;
                20'd164   : data_o = 32'h02d62533;
                20'd165   : data_o = 32'h15c51e63;
                20'd166   : data_o = 32'h000028b7;
                20'd167   : data_o = 32'he8288893;
                20'd168   : data_o = 32'h00010437;
                20'd169   : data_o = 32'hfff40413;
                20'd170   : data_o = 32'h01200493;
                20'd171   : data_o = 32'h03400913;
                20'd172   : data_o = 32'h05600993;
                20'd173   : data_o = 32'h07800a13;
                20'd174   : data_o = 32'h09000a93;
                20'd175   : data_o = 32'h0ab00b13;
                20'd176   : data_o = 32'h0cd00b93;
                20'd177   : data_o = 32'h0ef00c13;
                20'd178   : data_o = 32'h80848433;
                20'd179   : data_o = 32'h80890433;
                20'd180   : data_o = 32'h80898433;
                20'd181   : data_o = 32'h808a0433;
                20'd182   : data_o = 32'h808a8433;
                20'd183   : data_o = 32'h808b0433;
                20'd184   : data_o = 32'h808b8433;
                20'd185   : data_o = 32'h808c0433;
                20'd186   : data_o = 32'h11141463;
                20'd187   : data_o = 32'h000102b7;
                20'd188   : data_o = 32'hfff28293;
                20'd189   : data_o = 32'h00001337;
                20'd190   : data_o = 32'h23430313;
                20'd191   : data_o = 32'h000053b7;
                20'd192   : data_o = 32'h67838393;
                20'd193   : data_o = 32'h00009e37;
                20'd194   : data_o = 32'h0abe0e13;
                20'd195   : data_o = 32'h0000deb7;
                20'd196   : data_o = 32'hdefe8e93;
                20'd197   : data_o = 32'h805312b3;
                20'd198   : data_o = 32'h805392b3;
                20'd199   : data_o = 32'h805e12b3;
                20'd200   : data_o = 32'h805e92b3;
                20'd201   : data_o = 32'h0d129663;
                20'd202   : data_o = 32'h00010537;
                20'd203   : data_o = 32'hfff50513;
                20'd204   : data_o = 32'h123455b7;
                20'd205   : data_o = 32'h67858593;
                20'd206   : data_o = 32'h90abd637;
                20'd207   : data_o = 32'hdef60613;
                20'd208   : data_o = 32'h80a5a533;
                20'd209   : data_o = 32'h80a62533;
                20'd210   : data_o = 32'h0b151463;
                20'd211   : data_o = 32'h00000297;
                20'd212   : data_o = 32'h0ac28293;
                20'd213   : data_o = 32'h0002a303;
                20'd214   : data_o = 32'h0042a383;
                20'd215   : data_o = 32'h00010537;
                20'd216   : data_o = 32'hfff50513;
                20'd217   : data_o = 32'h80a32533;
                20'd218   : data_o = 32'h80a3a533;
                20'd219   : data_o = 32'h000028b7;
                20'd220   : data_o = 32'he8288893;
                20'd221   : data_o = 32'h07151e63;
                20'd222   : data_o = 32'h01400293;
                20'd223   : data_o = 32'h00a00313;
                20'd224   : data_o = 32'h006283b3;
                20'd225   : data_o = 32'h40628e33;
                20'd226   : data_o = 32'h03c38eb3;
                20'd227   : data_o = 32'h12c00f13;
                20'd228   : data_o = 32'h07ee9063;
                20'd229   : data_o = 32'h00000297;
                20'd230   : data_o = 32'h06c28293;
                20'd231   : data_o = 32'h0fc10317;
                20'd232   : data_o = 32'hc7430313;
                20'd233   : data_o = 32'h00300393;
                20'd234   : data_o = 32'h0002ae03;
                20'd235   : data_o = 32'h01c32023;
                20'd236   : data_o = 32'h00428293;
                20'd237   : data_o = 32'h00430313;
                20'd238   : data_o = 32'hfff38393;
                20'd239   : data_o = 32'hfe0396e3;
                20'd240   : data_o = 32'h0fc10317;
                20'd241   : data_o = 32'hc5030313;
                20'd242   : data_o = 32'h00032e03;
                20'd243   : data_o = 32'h11111eb7;
                20'd244   : data_o = 32'h111e8e93;
                20'd245   : data_o = 32'h01de1e63;
                20'd246   : data_o = 32'h00832e03;
                20'd247   : data_o = 32'h33333eb7;
                20'd248   : data_o = 32'h333e8e93;
                20'd249   : data_o = 32'h01de1663;
                20'd250   : data_o = 32'h00000213;
                20'd251   : data_o = 32'h0000006f;
                20'd252   : data_o = 32'hfff00213;
                20'd253   : data_o = 32'h0000006f;
                20'd254   : data_o = 32'h12345678;
                20'd255   : data_o = 32'h90abcdef;
                20'd256   : data_o = 32'h11111111;
                20'd257   : data_o = 32'h22222222;
                20'd258   : data_o = 32'h33333333;
                // ---- gap: words 259..511 read back 32'h0 ----
                20'd512   : data_o = 32'h10010a37;
                20'd513   : data_o = 32'h10010fb7;
                20'd514   : data_o = 32'h100f8f93;
                20'd515   : data_o = 32'h00500093;
                20'd516   : data_o = 32'h00a00113;
                20'd517   : data_o = 32'h00208f33;
                20'd518   : data_o = 32'h00f00e93;
                20'd519   : data_o = 32'h01df4e33;
                20'd520   : data_o = 32'h01cfa023;
                20'd521   : data_o = 32'h00a00093;
                20'd522   : data_o = 32'h00500113;
                20'd523   : data_o = 32'h40208f33;
                20'd524   : data_o = 32'h00500e93;
                20'd525   : data_o = 32'h01df4e33;
                20'd526   : data_o = 32'h01cfa223;
                20'd527   : data_o = 32'h00100093;
                20'd528   : data_o = 32'h01f00113;
                20'd529   : data_o = 32'h00209f33;
                20'd530   : data_o = 32'h80000eb7;
                20'd531   : data_o = 32'h000e8e93;
                20'd532   : data_o = 32'h01df4e33;
                20'd533   : data_o = 32'h01cfa423;
                20'd534   : data_o = 32'h800000b7;
                20'd535   : data_o = 32'h00008093;
                20'd536   : data_o = 32'h80000137;
                20'd537   : data_o = 32'hfff10113;
                20'd538   : data_o = 32'h0020af33;
                20'd539   : data_o = 32'h00100e93;
                20'd540   : data_o = 32'h01df4e33;
                20'd541   : data_o = 32'h01cfa623;
                20'd542   : data_o = 32'h800000b7;
                20'd543   : data_o = 32'h00008093;
                20'd544   : data_o = 32'h80000137;
                20'd545   : data_o = 32'hfff10113;
                20'd546   : data_o = 32'h0020bf33;
                20'd547   : data_o = 32'h00000e93;
                20'd548   : data_o = 32'h01df4e33;
                20'd549   : data_o = 32'h01cfa823;
                20'd550   : data_o = 32'haaaab0b7;
                20'd551   : data_o = 32'haaa08093;
                20'd552   : data_o = 32'hfff00113;
                20'd553   : data_o = 32'h0020cf33;
                20'd554   : data_o = 32'h55555eb7;
                20'd555   : data_o = 32'h555e8e93;
                20'd556   : data_o = 32'h01df4e33;
                20'd557   : data_o = 32'h01cfaa23;
                20'd558   : data_o = 32'h800000b7;
                20'd559   : data_o = 32'h00008093;
                20'd560   : data_o = 32'h00400113;
                20'd561   : data_o = 32'h0020df33;
                20'd562   : data_o = 32'h08000eb7;
                20'd563   : data_o = 32'h000e8e93;
                20'd564   : data_o = 32'h01df4e33;
                20'd565   : data_o = 32'h01cfac23;
                20'd566   : data_o = 32'hfff00093;
                20'd567   : data_o = 32'h00500113;
                20'd568   : data_o = 32'h4020df33;
                20'd569   : data_o = 32'hfff00e93;
                20'd570   : data_o = 32'h01df4e33;
                20'd571   : data_o = 32'h01cfae23;
                20'd572   : data_o = 32'hf0f0f0b7;
                20'd573   : data_o = 32'h0f008093;
                20'd574   : data_o = 32'h0f0f1137;
                20'd575   : data_o = 32'hf0f10113;
                20'd576   : data_o = 32'h0020ef33;
                20'd577   : data_o = 32'hfff00e93;
                20'd578   : data_o = 32'h01df4e33;
                20'd579   : data_o = 32'h03cfa023;
                20'd580   : data_o = 32'hff0100b7;
                20'd581   : data_o = 32'hf0008093;
                20'd582   : data_o = 32'h0ff01137;
                20'd583   : data_o = 32'hff010113;
                20'd584   : data_o = 32'h0020ff33;
                20'd585   : data_o = 32'h0f001eb7;
                20'd586   : data_o = 32'hf00e8e93;
                20'd587   : data_o = 32'h01df4e33;
                20'd588   : data_o = 32'h03cfa223;
                20'd589   : data_o = 32'h06400093;
                20'd590   : data_o = 32'hfce08f13;
                20'd591   : data_o = 32'h03200e93;
                20'd592   : data_o = 32'h01df4e33;
                20'd593   : data_o = 32'h03cfa423;
                20'd594   : data_o = 32'hffb00093;
                20'd595   : data_o = 32'h0000af13;
                20'd596   : data_o = 32'h00100e93;
                20'd597   : data_o = 32'h01df4e33;
                20'd598   : data_o = 32'h03cfa623;
                20'd599   : data_o = 32'h00500093;
                20'd600   : data_o = 32'h00a0bf13;
                20'd601   : data_o = 32'h00100e93;
                20'd602   : data_o = 32'h01df4e33;
                20'd603   : data_o = 32'h03cfa823;
                20'd604   : data_o = 32'h0f0f10b7;
                20'd605   : data_o = 32'hf0f08093;
                20'd606   : data_o = 32'hfff0cf13;
                20'd607   : data_o = 32'hf0f0feb7;
                20'd608   : data_o = 32'h0f0e8e93;
                20'd609   : data_o = 32'h01df4e33;
                20'd610   : data_o = 32'h03cfaa23;
                20'd611   : data_o = 32'h000100b7;
                20'd612   : data_o = 32'hf0008093;
                20'd613   : data_o = 32'h00f0ef13;
                20'd614   : data_o = 32'h00010eb7;
                20'd615   : data_o = 32'hf0fe8e93;
                20'd616   : data_o = 32'h01df4e33;
                20'd617   : data_o = 32'h03cfac23;
                20'd618   : data_o = 32'hfff00093;
                20'd619   : data_o = 32'h00f0ff13;
                20'd620   : data_o = 32'h00f00e93;
                20'd621   : data_o = 32'h01df4e33;
                20'd622   : data_o = 32'h03cfae23;
                20'd623   : data_o = 32'h00100093;
                20'd624   : data_o = 32'h00a09f13;
                20'd625   : data_o = 32'h40000e93;
                20'd626   : data_o = 32'h01df4e33;
                20'd627   : data_o = 32'h05cfa023;
                20'd628   : data_o = 32'h800000b7;
                20'd629   : data_o = 32'h00008093;
                20'd630   : data_o = 32'h0040df13;
                20'd631   : data_o = 32'h08000eb7;
                20'd632   : data_o = 32'h000e8e93;
                20'd633   : data_o = 32'h01df4e33;
                20'd634   : data_o = 32'h05cfa223;
                20'd635   : data_o = 32'hff800093;
                20'd636   : data_o = 32'h4020df13;
                20'd637   : data_o = 32'hffe00e93;
                20'd638   : data_o = 32'h01df4e33;
                20'd639   : data_o = 32'h05cfa423;
                20'd640   : data_o = 32'hdeadc137;
                20'd641   : data_o = 32'heef10113;
                20'd642   : data_o = 32'h002a2023;
                20'd643   : data_o = 32'h000a2f03;
                20'd644   : data_o = 32'hdeadceb7;
                20'd645   : data_o = 32'heefe8e93;
                20'd646   : data_o = 32'h01df4e33;
                20'd647   : data_o = 32'h05cfa623;
                20'd648   : data_o = 32'habcd9137;
                20'd649   : data_o = 32'h23410113;
                20'd650   : data_o = 32'h002a2223;
                20'd651   : data_o = 32'h004a1f03;
                20'd652   : data_o = 32'hffff9eb7;
                20'd653   : data_o = 32'h234e8e93;
                20'd654   : data_o = 32'h01df4e33;
                20'd655   : data_o = 32'h05cfa823;
                20'd656   : data_o = 32'habcd8137;
                20'd657   : data_o = 32'h00010113;
                20'd658   : data_o = 32'h002a2423;
                20'd659   : data_o = 32'h008a5f03;
                20'd660   : data_o = 32'h00008eb7;
                20'd661   : data_o = 32'h000e8e93;
                20'd662   : data_o = 32'h01df4e33;
                20'd663   : data_o = 32'h05cfaa23;
                20'd664   : data_o = 32'haabbd137;
                20'd665   : data_o = 32'hcf110113;
                20'd666   : data_o = 32'h002a2623;
                20'd667   : data_o = 32'h00ca0f03;
                20'd668   : data_o = 32'hff100e93;
                20'd669   : data_o = 32'h01df4e33;
                20'd670   : data_o = 32'h05cfac23;
                20'd671   : data_o = 32'haabbd137;
                20'd672   : data_o = 32'hc7f10113;
                20'd673   : data_o = 32'h002a2823;
                20'd674   : data_o = 32'h010a4f03;
                20'd675   : data_o = 32'h07f00e93;
                20'd676   : data_o = 32'h01df4e33;
                20'd677   : data_o = 32'h05cfae23;
                20'd678   : data_o = 32'haabb8137;
                20'd679   : data_o = 32'h0cc10113;
                20'd680   : data_o = 32'h022a2023;
                20'd681   : data_o = 32'h021a0f03;
                20'd682   : data_o = 32'hf8000e93;
                20'd683   : data_o = 32'h01df4e33;
                20'd684   : data_o = 32'h07cfa023;
                20'd685   : data_o = 32'haa7fc137;
                20'd686   : data_o = 32'hbcc10113;
                20'd687   : data_o = 32'h022a2223;
                20'd688   : data_o = 32'h026a0f03;
                20'd689   : data_o = 32'h07f00e93;
                20'd690   : data_o = 32'h01df4e33;
                20'd691   : data_o = 32'h07cfa223;
                20'd692   : data_o = 32'h91aac137;
                20'd693   : data_o = 32'hbcc10113;
                20'd694   : data_o = 32'h022a2423;
                20'd695   : data_o = 32'h02ba0f03;
                20'd696   : data_o = 32'hf9100e93;
                20'd697   : data_o = 32'h01df4e33;
                20'd698   : data_o = 32'h07cfa423;
                20'd699   : data_o = 32'haabb8137;
                20'd700   : data_o = 32'h0cc10113;
                20'd701   : data_o = 32'h022a2623;
                20'd702   : data_o = 32'h02da4f03;
                20'd703   : data_o = 32'h08000e93;
                20'd704   : data_o = 32'h01df4e33;
                20'd705   : data_o = 32'h07cfa623;
                20'd706   : data_o = 32'h91aac137;
                20'd707   : data_o = 32'hbcc10113;
                20'd708   : data_o = 32'h022a2823;
                20'd709   : data_o = 32'h033a4f03;
                20'd710   : data_o = 32'h09100e93;
                20'd711   : data_o = 32'h01df4e33;
                20'd712   : data_o = 32'h07cfa823;
                20'd713   : data_o = 32'h8765b137;
                20'd714   : data_o = 32'hbcd10113;
                20'd715   : data_o = 32'h022a2a23;
                20'd716   : data_o = 32'h036a1f03;
                20'd717   : data_o = 32'hffff8eb7;
                20'd718   : data_o = 32'h765e8e93;
                20'd719   : data_o = 32'h01df4e33;
                20'd720   : data_o = 32'h07cfaa23;
                20'd721   : data_o = 32'h8765b137;
                20'd722   : data_o = 32'hbcd10113;
                20'd723   : data_o = 32'h022a2c23;
                20'd724   : data_o = 32'h03aa5f03;
                20'd725   : data_o = 32'h00008eb7;
                20'd726   : data_o = 32'h765e8e93;
                20'd727   : data_o = 32'h01df4e33;
                20'd728   : data_o = 32'h07cfac23;
                20'd729   : data_o = 32'hfff00113;
                20'd730   : data_o = 32'h002a2a23;
                20'd731   : data_o = 32'hcafec137;
                20'd732   : data_o = 32'habe10113;
                20'd733   : data_o = 32'h002a2a23;
                20'd734   : data_o = 32'h014a2f03;
                20'd735   : data_o = 32'hcafeceb7;
                20'd736   : data_o = 32'habee8e93;
                20'd737   : data_o = 32'h01df4e33;
                20'd738   : data_o = 32'h07cfae23;
                20'd739   : data_o = 32'hfff00113;
                20'd740   : data_o = 32'h002a2c23;
                20'd741   : data_o = 32'h0000b137;
                20'd742   : data_o = 32'hbcd10113;
                20'd743   : data_o = 32'h002a1c23;
                20'd744   : data_o = 32'h018a5f03;
                20'd745   : data_o = 32'h0000beb7;
                20'd746   : data_o = 32'hbcde8e93;
                20'd747   : data_o = 32'h01df4e33;
                20'd748   : data_o = 32'h09cfa023;
                20'd749   : data_o = 32'hfff00113;
                20'd750   : data_o = 32'h002a2e23;
                20'd751   : data_o = 32'h0ef00113;
                20'd752   : data_o = 32'h002a0e23;
                20'd753   : data_o = 32'h01ca4f03;
                20'd754   : data_o = 32'h0ef00e93;
                20'd755   : data_o = 32'h01df4e33;
                20'd756   : data_o = 32'h09cfa223;
                20'd757   : data_o = 32'hfff00113;
                20'd758   : data_o = 32'h042a2023;
                20'd759   : data_o = 32'h05a00113;
                20'd760   : data_o = 32'h042a00a3;
                20'd761   : data_o = 32'h041a4f03;
                20'd762   : data_o = 32'h05a00e93;
                20'd763   : data_o = 32'h01df4e33;
                20'd764   : data_o = 32'h09cfa423;
                20'd765   : data_o = 32'hfff00113;
                20'd766   : data_o = 32'h042a2223;
                20'd767   : data_o = 32'h0a500113;
                20'd768   : data_o = 32'h042a0323;
                20'd769   : data_o = 32'h046a4f03;
                20'd770   : data_o = 32'h0a500e93;
                20'd771   : data_o = 32'h01df4e33;
                20'd772   : data_o = 32'h09cfa623;
                20'd773   : data_o = 32'hfff00113;
                20'd774   : data_o = 32'h042a2423;
                20'd775   : data_o = 32'h03c00113;
                20'd776   : data_o = 32'h042a05a3;
                20'd777   : data_o = 32'h04ba4f03;
                20'd778   : data_o = 32'h03c00e93;
                20'd779   : data_o = 32'h01df4e33;
                20'd780   : data_o = 32'h09cfa823;
                20'd781   : data_o = 32'hfff00113;
                20'd782   : data_o = 32'h042a2623;
                20'd783   : data_o = 32'h00001137;
                20'd784   : data_o = 32'h23410113;
                20'd785   : data_o = 32'h042a1723;
                20'd786   : data_o = 32'h04ea5f03;
                20'd787   : data_o = 32'h00001eb7;
                20'd788   : data_o = 32'h234e8e93;
                20'd789   : data_o = 32'h01df4e33;
                20'd790   : data_o = 32'h09cfaa23;
                20'd791   : data_o = 32'h00700093;
                20'd792   : data_o = 32'h00700113;
                20'd793   : data_o = 32'h00000f13;
                20'd794   : data_o = 32'h00208463;
                20'd795   : data_o = 32'h00100f13;
                20'd796   : data_o = 32'h00000e93;
                20'd797   : data_o = 32'h01df4e33;
                20'd798   : data_o = 32'h09cfac23;
                20'd799   : data_o = 32'h00700093;
                20'd800   : data_o = 32'h00800113;
                20'd801   : data_o = 32'h00000f13;
                20'd802   : data_o = 32'h00208463;
                20'd803   : data_o = 32'h00100f13;
                20'd804   : data_o = 32'h00100e93;
                20'd805   : data_o = 32'h01df4e33;
                20'd806   : data_o = 32'h09cfae23;
                20'd807   : data_o = 32'h00700093;
                20'd808   : data_o = 32'h00800113;
                20'd809   : data_o = 32'h00000f13;
                20'd810   : data_o = 32'h00209463;
                20'd811   : data_o = 32'h00100f13;
                20'd812   : data_o = 32'h00000e93;
                20'd813   : data_o = 32'h01df4e33;
                20'd814   : data_o = 32'h0bcfa023;
                20'd815   : data_o = 32'h00700093;
                20'd816   : data_o = 32'h00700113;
                20'd817   : data_o = 32'h00000f13;
                20'd818   : data_o = 32'h00209463;
                20'd819   : data_o = 32'h00100f13;
                20'd820   : data_o = 32'h00100e93;
                20'd821   : data_o = 32'h01df4e33;
                20'd822   : data_o = 32'h0bcfa223;
                20'd823   : data_o = 32'h800000b7;
                20'd824   : data_o = 32'h00008093;
                20'd825   : data_o = 32'h80000137;
                20'd826   : data_o = 32'hfff10113;
                20'd827   : data_o = 32'h00000f13;
                20'd828   : data_o = 32'h0020c463;
                20'd829   : data_o = 32'h00100f13;
                20'd830   : data_o = 32'h00000e93;
                20'd831   : data_o = 32'h01df4e33;
                20'd832   : data_o = 32'h0bcfa423;
                20'd833   : data_o = 32'h800000b7;
                20'd834   : data_o = 32'hfff08093;
                20'd835   : data_o = 32'h80000137;
                20'd836   : data_o = 32'h00010113;
                20'd837   : data_o = 32'h00000f13;
                20'd838   : data_o = 32'h0020c463;
                20'd839   : data_o = 32'h00100f13;
                20'd840   : data_o = 32'h00100e93;
                20'd841   : data_o = 32'h01df4e33;
                20'd842   : data_o = 32'h0bcfa623;
                20'd843   : data_o = 32'h800000b7;
                20'd844   : data_o = 32'hfff08093;
                20'd845   : data_o = 32'h80000137;
                20'd846   : data_o = 32'h00010113;
                20'd847   : data_o = 32'h00000f13;
                20'd848   : data_o = 32'h0020d463;
                20'd849   : data_o = 32'h00100f13;
                20'd850   : data_o = 32'h00000e93;
                20'd851   : data_o = 32'h01df4e33;
                20'd852   : data_o = 32'h0bcfa823;
                20'd853   : data_o = 32'h800000b7;
                20'd854   : data_o = 32'h00008093;
                20'd855   : data_o = 32'h80000137;
                20'd856   : data_o = 32'hfff10113;
                20'd857   : data_o = 32'h00000f13;
                20'd858   : data_o = 32'h0020d463;
                20'd859   : data_o = 32'h00100f13;
                20'd860   : data_o = 32'h00100e93;
                20'd861   : data_o = 32'h01df4e33;
                20'd862   : data_o = 32'h0bcfaa23;
                20'd863   : data_o = 32'h800000b7;
                20'd864   : data_o = 32'hfff08093;
                20'd865   : data_o = 32'h80000137;
                20'd866   : data_o = 32'h00010113;
                20'd867   : data_o = 32'h00000f13;
                20'd868   : data_o = 32'h0020e463;
                20'd869   : data_o = 32'h00100f13;
                20'd870   : data_o = 32'h00000e93;
                20'd871   : data_o = 32'h01df4e33;
                20'd872   : data_o = 32'h0bcfac23;
                20'd873   : data_o = 32'h800000b7;
                20'd874   : data_o = 32'h00008093;
                20'd875   : data_o = 32'h80000137;
                20'd876   : data_o = 32'hfff10113;
                20'd877   : data_o = 32'h00000f13;
                20'd878   : data_o = 32'h0020e463;
                20'd879   : data_o = 32'h00100f13;
                20'd880   : data_o = 32'h00100e93;
                20'd881   : data_o = 32'h01df4e33;
                20'd882   : data_o = 32'h0bcfae23;
                20'd883   : data_o = 32'h800000b7;
                20'd884   : data_o = 32'h00008093;
                20'd885   : data_o = 32'h80000137;
                20'd886   : data_o = 32'hfff10113;
                20'd887   : data_o = 32'h00000f13;
                20'd888   : data_o = 32'h0020f463;
                20'd889   : data_o = 32'h00100f13;
                20'd890   : data_o = 32'h00000e93;
                20'd891   : data_o = 32'h01df4e33;
                20'd892   : data_o = 32'h0dcfa023;
                20'd893   : data_o = 32'h800000b7;
                20'd894   : data_o = 32'hfff08093;
                20'd895   : data_o = 32'h80000137;
                20'd896   : data_o = 32'h00010113;
                20'd897   : data_o = 32'h00000f13;
                20'd898   : data_o = 32'h0020f463;
                20'd899   : data_o = 32'h00100f13;
                20'd900   : data_o = 32'h00100e93;
                20'd901   : data_o = 32'h01df4e33;
                20'd902   : data_o = 32'h0dcfa223;
                20'd903   : data_o = 32'h12345f37;
                20'd904   : data_o = 32'h12345eb7;
                20'd905   : data_o = 32'h000e8e93;
                20'd906   : data_o = 32'h01df4e33;
                20'd907   : data_o = 32'h0dcfa423;
                20'd908   : data_o = 32'h0001e0b7;
                20'd909   : data_o = 32'h24008093;
                20'd910   : data_o = 32'h00002137;
                20'd911   : data_o = 32'ha8510113;
                20'd912   : data_o = 32'h02208f33;
                20'd913   : data_o = 32'h31f51eb7;
                20'd914   : data_o = 32'hb40e8e93;
                20'd915   : data_o = 32'h01df4e33;
                20'd916   : data_o = 32'h0dcfa623;
                20'd917   : data_o = 32'h800000b7;
                20'd918   : data_o = 32'h00008093;
                20'd919   : data_o = 32'h80000137;
                20'd920   : data_o = 32'h00010113;
                20'd921   : data_o = 32'h02209f33;
                20'd922   : data_o = 32'h40000eb7;
                20'd923   : data_o = 32'h000e8e93;
                20'd924   : data_o = 32'h01df4e33;
                20'd925   : data_o = 32'h0dcfa823;
                20'd926   : data_o = 32'hffe00093;
                20'd927   : data_o = 32'hfff00113;
                20'd928   : data_o = 32'h0220af33;
                20'd929   : data_o = 32'hffe00e93;
                20'd930   : data_o = 32'h01df4e33;
                20'd931   : data_o = 32'h0dcfaa23;
                20'd932   : data_o = 32'hfff00093;
                20'd933   : data_o = 32'hfff00113;
                20'd934   : data_o = 32'h0220bf33;
                20'd935   : data_o = 32'hffe00e93;
                20'd936   : data_o = 32'h01df4e33;
                20'd937   : data_o = 32'h0dcfac23;
                20'd938   : data_o = 32'h06100093;
                20'd939   : data_o = 32'h00010137;
                20'd940   : data_o = 32'hfff10113;
                20'd941   : data_o = 32'h80208f33;
                20'd942   : data_o = 32'h0000aeb7;
                20'd943   : data_o = 32'hd77e8e93;
                20'd944   : data_o = 32'h01df4e33;
                20'd945   : data_o = 32'h0dcfae23;
                20'd946   : data_o = 32'h000060b7;
                20'd947   : data_o = 32'h16208093;
                20'd948   : data_o = 32'h00010137;
                20'd949   : data_o = 32'hfff10113;
                20'd950   : data_o = 32'h80209f33;
                20'd951   : data_o = 32'h00007eb7;
                20'd952   : data_o = 32'h9f0e8e93;
                20'd953   : data_o = 32'h01df4e33;
                20'd954   : data_o = 32'h0fcfa023;
                20'd955   : data_o = 32'h616260b7;
                20'd956   : data_o = 32'h36408093;
                20'd957   : data_o = 32'h00010137;
                20'd958   : data_o = 32'hfff10113;
                20'd959   : data_o = 32'h8020af33;
                20'd960   : data_o = 32'h00003eb7;
                20'd961   : data_o = 32'hcf6e8e93;
                20'd962   : data_o = 32'h01df4e33;
                20'd963   : data_o = 32'h0fcfa223;
                20'd964   : data_o = 32'h0080036f;
                20'd965   : data_o = 32'h00100393;
                20'd966   : data_o = 32'h00100413;
                20'd967   : data_o = 32'h00000517;
                20'd968   : data_o = 32'h01450513;
                20'd969   : data_o = 32'h000504e7;
                20'd970   : data_o = 32'h00100593;
                20'd971   : data_o = 32'h00c0006f;
                20'd972   : data_o = 32'h00100613;
                20'd973   : data_o = 32'h00048067;
                20'd974   : data_o = 32'h00100693;
                20'd975   : data_o = 32'h00005717;
                20'd976   : data_o = 32'h07700793;
                20'd977   : data_o = 32'h0000000f;
                20'd978   : data_o = 32'h00078813;
                20'd979   : data_o = 32'h08800893;
                20'd980   : data_o = 32'h00100073;
                20'd981   : data_o = 32'h00088913;
                20'd982   : data_o = 32'h00000a97;
                20'd983   : data_o = 32'h00caab03;
                20'd984   : data_o = 32'h0080006f;
                20'd985   : data_o = 32'hcafebabe;
                20'd986   : data_o = 32'h00100b93;
                20'd987   : data_o = 32'h00000c13;
                20'd988   : data_o = 32'h00100c93;
                20'd989   : data_o = 32'h00600d13;
                20'd990   : data_o = 32'h019c0c33;
                20'd991   : data_o = 32'h001c8c93;
                20'd992   : data_o = 32'hffaccce3;
                20'd993   : data_o = 32'h00100d93;
                20'd994   : data_o = 32'h00000073;
                default: data_o = 32'b0;
            endcase
        end
    end
endmodule



//  ---------- INLCUDED BLOCK: immediate_generator  ---------- 
// ============================================================================
// immediate_generator.v - extracts & sign-extends I/S/B/U/J immediates.
// Purely combinational.
// ============================================================================
module immediate_generator (
    input  wire [31:0] ir,
    output reg  [31:0] imm
);
    wire [6:0] opcode = ir[6:0];

    localparam [6:0]
        OPC_LOAD   = 7'b0000011,
        OPC_ALUIMM = 7'b0010011,
        OPC_JALR   = 7'b1100111,
        OPC_STORE  = 7'b0100011,
        OPC_BRANCH = 7'b1100011,
        OPC_LUI    = 7'b0110111,
        OPC_AUIPC  = 7'b0010111,
        OPC_JAL    = 7'b1101111;

    always @(*) begin
        case (opcode)
            OPC_LOAD, OPC_ALUIMM, OPC_JALR: // I-type
                imm = {{20{ir[31]}}, ir[31:20]};
            OPC_STORE: // S-type
                imm = {{20{ir[31]}}, ir[31:25], ir[11:7]};
            OPC_BRANCH: // B-type, imm[0] architecturally 0
                imm = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
            OPC_LUI, OPC_AUIPC: // U-type
                imm = {ir[31:12], 12'b0};
            OPC_JAL: // J-type, imm[0] architecturally 0
                imm = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};
            default:
                imm = 32'b0; // R-type / SYSTEM / FENCE: don't-care, datapath won't select it
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: ir_fields  ---------- 
// ============================================================================
// ir_fields.v - extracts the three register-address fields from the
// instruction register.
//
// This block exists only because the project canvas cannot slice a bus: every
// connection it generates is a whole bus of exactly matching width, so
// `ir[19:15]` cannot be drawn as a wire. Keeping the extraction here lets
// register_file.v stay byte-identical to the verified original rather than
// growing an instruction port and slicing internally.
// ============================================================================
module ir_fields (
    input  wire [31:0] ir,
    output wire [4:0]  rs1_addr,
    output wire [4:0]  rs2_addr,
    output wire [4:0]  rd_addr
);
    assign rs1_addr = ir[19:15];
    assign rs2_addr = ir[24:20];
    assign rd_addr  = ir[11:7];
endmodule



//  ---------- INLCUDED BLOCK: ir_reg  ---------- 
// ============================================================================
// ir_reg.v - instruction register. Loaded exactly once per instruction,
// at the Fetch->Decode edge (ir_write asserted only during FETCH). This is
// the linchpin of the no-ALUOut/no-MDR datapath.
// ============================================================================
module ir_reg (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        ir_write,
    input  wire [31:0] imem_data,
    // (* keep *) - see dmem.v for why this is needed (zero-output top level).
    output reg  [31:0] ir
);
    localparam [31:0] NOP = 32'h0000_0013; // ADDI x0,x0,0 - waveform readability only

    always @(posedge clk_i) begin
        if (rst_i)
            ir <= NOP;
        else if (ir_write)
            ir <= imem_data;
    end
endmodule



//  ---------- INLCUDED BLOCK: lsu  ---------- 
// ============================================================================
// lsu.v - Load/Store Unit. Converts between the core's byte/half/word
// transaction view and the flat word-addressed, byte-writable memory
// interface. Purely combinational.
//
// op_size is funct3 directly: op_size[1:0] = width (00/01/10 =
// byte/half/word), op_size[2] = unsigned-load flag.
//
// Misaligned half/word accesses are deliberately made a clean, deterministic
// no-op rather than left undefined: misaligned stores assert byte_write_o=0000
// (no write), misaligned loads return 0.
// ============================================================================
module lsu (
    input  wire [31:0] alu_result,     // effective address
    input  wire [31:0] rs2_data,       // register value to store
    input  wire [2:0]  op_size,        // = funct3
    input  wire        is_valid_store, // gates byte_write_o (§9.1 full-tuple decode)
    input  wire [31:0] mem_data_o,     // raw word read back from memory
    output reg  [31:0] core_data_i,    // extended load data -> WBSrc mux
    output reg  [3:0]  byte_write_o,   // bw_o
    output reg  [31:0] store_data_o    // positioned store data -> mem
);
    wire [1:0] addr_lsb        = alu_result[1:0];
    wire [1:0] size            = op_size[1:0];
    wire       load_unsigned   = op_size[2];

    // ---------------- Store path: byte-write mask + data positioning -----
    always @(*) begin
        byte_write_o = 4'b0000;
        store_data_o = 32'b0;
        if (is_valid_store) begin
            case (size)
                2'b00: begin // byte
                    case (addr_lsb)
                        2'b00: begin byte_write_o = 4'b0001; store_data_o = {24'b0, rs2_data[7:0]}; end
                        2'b01: begin byte_write_o = 4'b0010; store_data_o = {16'b0, rs2_data[7:0], 8'b0}; end
                        2'b10: begin byte_write_o = 4'b0100; store_data_o = {8'b0, rs2_data[7:0], 16'b0}; end
                        2'b11: begin byte_write_o = 4'b1000; store_data_o = {rs2_data[7:0], 24'b0}; end
                    endcase
                end
                2'b01: begin // half
                    case (addr_lsb)
                        2'b00: begin byte_write_o = 4'b0011; store_data_o = {16'b0, rs2_data[15:0]}; end
                        2'b10: begin byte_write_o = 4'b1100; store_data_o = {rs2_data[15:0], 16'b0}; end
                        default: begin byte_write_o = 4'b0000; store_data_o = 32'b0; end // misaligned
                    endcase
                end
                2'b10: begin // word
                    if (addr_lsb == 2'b00) begin byte_write_o = 4'b1111; store_data_o = rs2_data; end
                    else begin byte_write_o = 4'b0000; store_data_o = 32'b0; end // misaligned
                end
                default: begin byte_write_o = 4'b0000; store_data_o = 32'b0; end
            endcase
        end
    end

    // ---------------- Load path: extraction + sign/zero extension --------
    always @(*) begin
        case (size)
            2'b00: begin // byte
                case (addr_lsb)
                    2'b00: core_data_i = load_unsigned ? {24'b0, mem_data_o[7:0]}   : {{24{mem_data_o[7]}},  mem_data_o[7:0]};
                    2'b01: core_data_i = load_unsigned ? {24'b0, mem_data_o[15:8]}  : {{24{mem_data_o[15]}}, mem_data_o[15:8]};
                    2'b10: core_data_i = load_unsigned ? {24'b0, mem_data_o[23:16]} : {{24{mem_data_o[23]}}, mem_data_o[23:16]};
                    2'b11: core_data_i = load_unsigned ? {24'b0, mem_data_o[31:24]} : {{24{mem_data_o[31]}}, mem_data_o[31:24]};
                endcase
            end
            2'b01: begin // half
                case (addr_lsb)
                    2'b00: core_data_i = load_unsigned ? {16'b0, mem_data_o[15:0]}  : {{16{mem_data_o[15]}}, mem_data_o[15:0]};
                    2'b10: core_data_i = load_unsigned ? {16'b0, mem_data_o[31:16]} : {{16{mem_data_o[31]}}, mem_data_o[31:16]};
                    default: core_data_i = 32'b0; // misaligned
                endcase
            end
            2'b10: core_data_i = (addr_lsb == 2'b00) ? mem_data_o : 32'b0; // word / misaligned
            default: core_data_i = 32'b0;
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: multiplier  ---------- 
// ============================================================================
// multiplier.v - MUL/MULH/MULHSU/MULHU (Zmmul). Combinational, single
// Execute cycle. funct3 directly drives operand-signedness
// and result-half selection per Table 10:
//
//   funct3   op       A signed   B signed   result
//   000      MUL      yes        yes        product[31:0]
//   001      MULH     yes        yes        product[63:32]
//   010      MULHSU   yes        no         product[63:32]
//   011      MULHU    no         no         product[63:32]
//
// NOTE: result_sel_upper must be (funct3[1] | funct3[0]), NOT funct3[0]
// alone -- funct3[0] alone is wrong specifically for MULHSU (funct3=010),
// where it evaluates to 0 (lower half) instead of the correct 1 (upper
// half).
// ============================================================================
module multiplier (
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [2:0]  funct3,
    output reg  [31:0] result
);
    wire a_signed    = ~(funct3[1] & funct3[0]); // 0 only for MULHU (011)
    wire b_signed    = ~funct3[1];               // 1 only for MUL/MULH (00x)
    wire sel_upper   = funct3[1] | funct3[0];    // 0 only for MUL (000)

    wire [63:0] a_ext = a_signed ? {{32{rs1_data[31]}}, rs1_data} : {32'b0, rs1_data};
    wire [63:0] b_ext = b_signed ? {{32{rs2_data[31]}}, rs2_data} : {32'b0, rs2_data};

    // Widen the assignment context to 128 bits so Icarus/Yosys evaluate the
    // multiply at full precision rather than truncating at 64 bits before
    // the low-64 slice is taken (standard Verilog context-width practice).
    wire [127:0] product_full = a_ext * b_ext;
    wire [63:0]  product      = product_full[63:0];

    always @(*) begin
        result = sel_upper ? product[63:32] : product[31:0];
    end
endmodule



//  ---------- INLCUDED BLOCK: mux2_32  ---------- 
// ============================================================================
// mux2_32.v - generic 2-to-1 32-bit multiplexer.
//
// The project canvas holds no logic of its own: every wire drawn on it is a
// whole-bus point-to-point connection, so a selection that used to be a single
// `assign x = s ? a : b;` inside riscv_core.v has to exist as a real block.
// Four instances cover every such selection in the datapath:
//
//   alu_a     S=alu_src_a_sel   A=rs1_data    B=pc
//   alu_b     S=alu_src_b_sel   A=rs2_data    B=imm
//   address   S=addr_src_sel    A=pc          B=alu_result
//   pc_next   S=pc_src_sel      A=pc_plus_4   B=alu_result
//
// Polarity matters when wiring: S=0 selects A, S=1 selects B. Every control
// signal above is named for the thing it selects when asserted, so the
// asserted case is always the B leg.
// ============================================================================
module mux2_32 (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        s,
    output wire [31:0] z
);
    assign z = s ? b : a;
endmodule



//  ---------- INLCUDED BLOCK: pc_incrementer  ---------- 
// ============================================================================
// pc_incrementer.v - dedicated PC+4 adder, deliberately not the shared ALU,
// so it is available every cycle without needing an ALU cycle.
// ============================================================================
module pc_incrementer (
    input  wire [31:0] pc,
    output wire [31:0] pc_plus_4
);
    assign pc_plus_4 = pc + 32'd4;
endmodule



//  ---------- INLCUDED BLOCK: pc_reg  ---------- 
// ============================================================================
// pc_reg.v - program counter. Reset vector = IMEM base (0x00400000).
// Bits [1:0] forced to 0 on every load (covers JALR's
// "clear LSB" requirement and keeps PC always word-aligned, matching
// IMEM's word-only addressing).
// ============================================================================
module pc_reg (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        pc_write,
    input  wire [31:0] pc_next,
    // (* keep *) - see dmem.v for why this is needed (zero-output top level).
    output reg  [31:0] pc
);
    localparam [31:0] RESET_VECTOR = 32'h0040_0000;

    always @(posedge clk_i) begin
        if (rst_i)
            pc <= RESET_VECTOR;
        else if (pc_write)
            pc <= {pc_next[31:2], 2'b00};
    end
endmodule



//  ---------- INLCUDED BLOCK: register_file  ---------- 
// ============================================================================
// register_file.v - 32 x 32-bit GPRs. x0 hardwired zero. Async read,
// synchronous write scoped to WriteBack by control_unit.
// ============================================================================
module register_file (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    input  wire        reg_write,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);
    // (* keep *) - see dmem.v for why this is needed (zero-output top level).
    (* keep *) reg [31:0] regs [0:31];
    integer i;

    // Async reads; x0 read-side default is defense-in-depth (§9.8), the
    // write-guard below is what actually makes x0 permanently zero.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : regs[rs2_addr];

    always @(posedge clk_i) begin
        if (rst_i) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
        end else if (reg_write && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end
endmodule



//  ---------- INLCUDED BLOCK: wb_mux_32  ---------- 
// ============================================================================
// wb_mux_32.v - writeback source multiplexer.
//
// Selects which unit's result is committed to the register file, from
// control_unit's wb_src_sel. This was the `case (wb_src_sel)` block inside
// riscv_core.v; the project canvas holds no logic of its own, so it becomes a
// real block.
//
// Encoding is control_unit's, unchanged:
//   000  alu_result     ALU-reg / ALU-imm / LUI / AUIPC
//   001  mult_result    Zmmul
//   010  crc_result     Xicrc
//   011  lsu_load_data  loads
//   100  pc_plus_4      JAL / JALR link
//
// The inputs are named for their sources rather than A..H so the canvas shows
// what is actually being selected. Selects 101/110/111 are never generated by
// control_unit; they fall through to alu_result, matching the original
// `default:` leg exactly rather than producing a distinct undefined value.
// ============================================================================
module wb_mux_32 (
    input  wire [31:0] alu_result,
    input  wire [31:0] mult_result,
    input  wire [31:0] crc_result,
    input  wire [31:0] lsu_load_data,
    input  wire [31:0] pc_plus_4,
    input  wire [2:0]  wb_src_sel,
    output reg  [31:0] wb_data
);
    always @(*) begin
        case (wb_src_sel)
            3'b001:  wb_data = mult_result;
            3'b010:  wb_data = crc_result;
            3'b011:  wb_data = lsu_load_data;
            3'b100:  wb_data = pc_plus_4;
            default: wb_data = alu_result;
        endcase
    end
endmodule


// Automatically generated by ChipInventor Cloud EDA Tool - 3.15
// Careful: this file (hdl.v) will be automatically replaced
// when you ask tool to generate top Verilog code by clicking
// at BLOCKS button.

module top (

  input wire clk_i,
  input wire rst_i

);

//Internal Wires
 wire [31:0] w_1;
 wire [31:0] w_2;
 wire w_3;
 wire [31:0] w_4;
 wire [31:0] w_5;
 wire w_9;
 wire [31:0] w_10;
 wire w_13;
 wire w_14;
 wire [3:0] w_15;
 wire [31:0] w_16;
 wire [31:0] w_17;
 wire w_18;
 wire w_19;
 wire w_20;
 wire [3:0] w_21;
 wire [31:0] w_22;
 wire [31:0] w_24;
 wire [31:0] w_25;
 wire [4:0] w_26;
 wire [4:0] w_27;
 wire [4:0] w_28;
 wire [31:0] w_30;
 wire [31:0] w_31;
 wire w_32;
 wire [31:0] w_33;
 wire [31:0] w_37;
 wire w_43;
 wire [31:0] w_44;
 wire w_45;
 wire [31:0] w_46;
 wire [2:0] w_47;
 wire w_48;
 wire [3:0] w_49;
 wire [31:0] w_53;
 wire [31:0] w_55;
 wire w_57;
 wire [31:0] w_58;
 wire [2:0] w_59;
 wire w_60;
 wire w_62;

//Instances of Modules
mux2_32 blk3669_1 (
         .a (w_1),
         .b (w_2),
         .s (w_3),
         .z (w_4)
     );

pc_incrementer blk3670_3 (
         .pc_plus_4 (w_1),
         .pc (w_5)
     );

mux2_32 blk3669_4 (
         .a (w_5),
         .b (w_2),
         .s (w_9),
         .z (w_10)
     );

address_decoder blk3655_5 (
         .address_i (w_10),
         .we_i (w_13),
         .oe_i (w_14),
         .bw_i (w_15),
         .imem_rdata (w_16),
         .dmem_rdata (w_17),
         .imem_oe_o (w_18),
         .dmem_we_o (w_19),
         .dmem_oe_o (w_20),
         .dmem_bw_o (w_21),
         .data_o (w_22)
     );

imem blk3661_6 (
         .address_i (w_10),
         .data_o (w_16),
         .oe_i (w_18)
     );

dmem #(.DMEM_WORDS(2048)) blk3660_7 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .address_i (w_10),
         .data_o (w_17),
         .we_i (w_19),
         .oe_i (w_20),
         .bw_i (w_21),
         .data_i (w_24)
     );

ir_fields blk3663_9 (
         .ir (w_25),
         .rs1_addr (w_26),
         .rs2_addr (w_27),
         .rd_addr (w_28)
     );

immediate_generator blk3662_10 (
         .ir (w_25),
         .imm (w_30)
     );

register_file blk3672_11 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .rs1_addr (w_26),
         .rs2_addr (w_27),
         .rd_addr (w_28),
         .rd_data (w_31),
         .reg_write (w_32),
         .rs1_data (w_33),
         .rs2_data (w_37)
     );

mux2_32 blk3669_12 (
         .a (w_33),
         .b (w_5),
         .s (w_43),
         .z (w_44)
     );

mux2_32 blk3669_13 (
         .b (w_30),
         .a (w_37),
         .s (w_45),
         .z (w_46)
     );

branch_comparator blk3657_14 (
         .rs1_data (w_33),
         .rs2_data (w_37),
         .funct3 (w_47),
         .branch_taken (w_48)
     );

alu blk3656_15 (
         .result (w_2),
         .a (w_44),
         .b (w_46),
         .alu_op (w_49)
     );

multiplier blk3666_16 (
         .rs1_data (w_33),
         .rs2_data (w_37),
         .funct3 (w_47),
         .result (w_53)
     );

crc_unit blk3659_17 (
         .rs1_data (w_33),
         .rs2_data (w_37),
         .funct3 (w_47),
         .result (w_55)
     );

lsu blk3665_18 (
         .byte_write_o (w_15),
         .mem_data_o (w_22),
         .store_data_o (w_24),
         .rs2_data (w_37),
         .alu_result (w_2),
         .op_size (w_47),
         .is_valid_store (w_57),
         .core_data_i (w_58)
     );

wb_mux_32 blk3673_19 (
         .pc_plus_4 (w_1),
         .wb_data (w_31),
         .alu_result (w_2),
         .mult_result (w_53),
         .crc_result (w_55),
         .lsu_load_data (w_58),
         .wb_src_sel (w_59)
     );

ir_reg blk3664_23 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .imem_data (w_22),
         .ir (w_25),
         .ir_write (w_60)
     );

pc_reg blk3671_24 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .pc_next (w_4),
         .pc (w_5),
         .pc_write (w_62)
     );

control_unit blk3658_25 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .pc_src_sel (w_3),
         .addr_src_sel (w_9),
         .we_o (w_13),
         .oe_o (w_14),
         .reg_write (w_32),
         .alu_src_a_sel (w_43),
         .alu_src_b_sel (w_45),
         .op_size (w_47),
         .branch_taken (w_48),
         .alu_op (w_49),
         .is_valid_store (w_57),
         .wb_src_sel (w_59),
         .ir_write (w_60),
         .ir (w_25),
         .pc_write (w_62)
     );


endmodule
