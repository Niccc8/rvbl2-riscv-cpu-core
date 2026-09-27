

//  ---------- INLCUDED BLOCK: address_decoder  ---------- 
// ============================================================================
// address_decoder.v - routes the core's single memory-transaction interface
// to IMEM, DMEM or the peripheral region, and muxes read data back.
//
// Every strobe routed to a target is explicitly qualified by that target's own
// select - NOT just "routed to DMEM" in general - otherwise an out-of-range
// store could alias into a real DMEM or peripheral write.
//
// Stage 3 adds ONE region, not one port per peripheral. 0xF0000000-0xFFFFFFFF
// is 16 slots of 16 MB (slot = addr[27:24]); each peripheral decodes its own
// slot and register offset (GPIO slot 0, UART slot 1). Read data comes back
// through a chain: periph_chain_o -> gpio -> uart -> periph_rdata_i, each
// peripheral OR-ing in its register only when it is addressed, so adding a
// peripheral changes no existing block. periph_chain_o is a constant zero; it
// exists only because the ChipInventor canvas cannot draw a constant.
//
// There is deliberately no peripheral read strobe. The core holds a load's
// address and oe_i across MEMORY and WRITEBACK, so a read-triggered action
// would fire twice; peripheral reads are therefore side-effect free.
// ============================================================================
module address_decoder (
    input  wire [31:0] address_i,
    input  wire        we_i,
    input  wire        oe_i,
    input  wire [3:0]  bw_i,
    input  wire [31:0] imem_rdata,
    input  wire [31:0] dmem_rdata,
    input  wire [31:0] periph_rdata_i,
    output wire        imem_oe_o,
    output wire        dmem_we_o,
    output wire        dmem_oe_o,
    output wire [3:0]  dmem_bw_o,
    output wire        periph_we_o,
    output wire [3:0]  periph_bw_o,
    output wire [31:0] periph_chain_o,
    output wire [31:0] data_o
);
    localparam [31:0] IMEM_BASE     = 32'h0040_0000;
    localparam [31:0] IMEM_LAST     = 32'h007F_FFFF; // 4MB architectural window
    localparam [31:0] DMEM_BASE     = 32'h1001_0000;
    localparam [31:0] DMEM_LAST     = 32'h1001_1FFF; // 8kB window
    localparam [3:0]  PERIPH_REGION = 4'hF;          // 0xF0000000-0xFFFFFFFF

    wire imem_sel   = (address_i >= IMEM_BASE) && (address_i <= IMEM_LAST);
    wire dmem_sel   = (address_i >= DMEM_BASE) && (address_i <= DMEM_LAST);
    wire periph_sel = (address_i[31:28] == PERIPH_REGION);

    // IMEM has no write port at all - we_i is never routed there.
    assign imem_oe_o = oe_i & imem_sel;
    assign dmem_oe_o = oe_i & dmem_sel;
    assign dmem_we_o = we_i & dmem_sel;
    assign dmem_bw_o = bw_i & {4{dmem_sel}};

    assign periph_we_o    = we_i & periph_sel;
    assign periph_bw_o    = bw_i & {4{periph_sel}};
    assign periph_chain_o = 32'b0;

    assign data_o = dmem_sel   ? dmem_rdata     :
                    imem_sel   ? imem_rdata     :
                    periph_sel ? periph_rdata_i : 32'b0;
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
// crc_unit.v - CRCB/CRCH/CRCW (Xicrc). Combinational, zero-latency.
//
// GENERATED by chipinventor/scripts/gen_crc_xor.py; do not hand-edit.
//
// Structure follows Block Guide S3.1.3: three independent CRC blocks, one per
// input width (8 / 16 / 32 bits), each an algebraically unrolled XOR network,
// feeding a single output multiplexer selected per Table 11. Each block is
// written as byte updates - the eight LFSR steps of one byte already combined
// into the standard CRC-CCITT formula - so it is shifts and XORs only, and
// synthesis flattens it into the same XOR network as the bit-serial form.
// `gen_crc_xor.py --prove` shows this block and the Phase 2 one
// (rtl_ref/crc_unit.v, the same CRC as a bit-by-bit function loop) equal on
// every input: both are GF(2)-linear, and they agree on every basis vector.
//
// Why not the bit loop: in a simulator it re-runs 56 interpreted LFSR steps
// whenever a register operand changes, nearly every instruction. On the lane
// firmware that made simulating the chip about 2.7 times slower, which is the
// difference between fitting the ChipInventor simulator's time window or not.
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
    wire [15:0] seed = rs2_data[15:0];

    // One byte folded in, MSB first: the CRC-16/CCITT byte update, which is
    // the eight LFSR steps of the bit-serial definition already combined
    // (x is the byte's feedback; x << 12, x << 5 and x are where the
    // polynomial 0x1021 puts it). Shifts and XORs only.
    function [15:0] step8;
        input [15:0] c;
        input [7:0]  b;
        reg   [7:0]  x;
        begin
            x = c[15:8] ^ b;
            x = x ^ (x >> 4);
            step8 = {c[7:0], 8'h00} ^ {x[3:0], 12'h000} ^ {3'b000, x, 5'b00000} ^ {8'h00, x};
        end
    endfunction

    // ---- Block 1: CRCB, 8-bit input ------------------------------------
    // ---- Block 2: CRCH, 16-bit input: its two bytes, high first ----------
    // ---- Block 3: CRCW, 32-bit input: its four bytes, high first ---------
    // ---- Output multiplexer (Block Guide Table 11) ----------------------
    // Only the selected block is evaluated, which is what keeps a simulator
    // from recomputing three CRCs on every register-operand change.
    always @(*) begin
        case (funct3[1:0])
            2'b00:   result = {16'b0, step8(seed, rs1_data[7:0])};                        // CRCB
            2'b01:   result = {16'b0, step8(step8(seed, rs1_data[15:8]), rs1_data[7:0])}; // CRCH
            2'b10:   result = {16'b0, step8(step8(step8(step8(seed, rs1_data[31:24]),
                                                        rs1_data[23:16]),
                                                  rs1_data[15:8]),
                                            rs1_data[7:0])};                            // CRCW
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
// GENERATED FILE - do not hand-edit. Produced by
// chipinventor/scripts/gen_ci_imem.py from:
//   word    0..2773  0x00400000..0x00402B54  lane.hex (2774 words)
//                                          application firmware
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
//
// WHY A CASE AND NOT $readmemh
// ----------------------------
// The platform has no filesystem to read a hex image from, so the image is
// unrolled into the source here. Everything else about this block - the oe_i
// gating, the zero-on-deselect, the word indexing - is unchanged, so the
// address_decoder contract this sits behind is identical either way.
//
// FOR THE OPENLANE / P&R RUN, PASTE blocks/imem_mock.v INSTEAD.
// ============================================================================
module imem (
    input  wire [31:0] address_i,    // full byte address (already imem_sel-gated by decoder)
    input  wire        oe_i,
    output reg  [31:0] data_o
);
    // Word index within the 4MB architectural window (22-bit byte address ->
    // 20-bit word index), exactly as the file-driven version computed it.
    wire [19:0] word_addr = address_i[21:2];

    // Two-level case: 64-word pages, then the word in the page. The logic is
    // the same ROM; the split only keeps the simulator from walking one
    // thousand-arm case on every fetch.
    always @(*) begin
        if (!oe_i) data_o = 32'b0;
        else begin
            case (word_addr[19:6])
                14'd0   : case (word_addr[5:0])   // words 0..63
                    6'd0 : data_o = 32'h0fc12117;
                    6'd1 : data_o = 32'h00010113;
                    6'd2 : data_o = 32'h00003297;
                    6'd3 : data_o = 32'hb2c28293;
                    6'd4 : data_o = 32'h0fc10317;
                    6'd5 : data_o = 32'hff030313;
                    6'd6 : data_o = 32'h0fc10397;
                    6'd7 : data_o = 32'h00c38393;
                    6'd8 : data_o = 32'h00737c63;
                    6'd9 : data_o = 32'h0002ae03;
                    6'd10: data_o = 32'h01c32023;
                    6'd11: data_o = 32'h00428293;
                    6'd12: data_o = 32'h00430313;
                    6'd13: data_o = 32'hfedff06f;
                    6'd14: data_o = 32'h0fc10317;
                    6'd15: data_o = 32'hfec30313;
                    6'd16: data_o = 32'h0fc10397;
                    6'd17: data_o = 32'h15c38393;
                    6'd18: data_o = 32'h00737863;
                    6'd19: data_o = 32'h00032023;
                    6'd20: data_o = 32'h00430313;
                    6'd21: data_o = 32'hff5ff06f;
                    6'd22: data_o = 32'h39d010ef;
                    6'd23: data_o = 32'h00000073;
                    6'd24: data_o = 32'h0000006f;
                    6'd25: data_o = 32'h00050613;
                    6'd26: data_o = 32'h04058263;
                    6'd27: data_o = 32'h00000513;
                    6'd28: data_o = 32'h01f00713;
                    6'd29: data_o = 32'h00000793;
                    6'd30: data_o = 32'h00100893;
                    6'd31: data_o = 32'hfff00813;
                    6'd32: data_o = 32'h00e656b3;
                    6'd33: data_o = 32'h0016f693;
                    6'd34: data_o = 32'h00179793;
                    6'd35: data_o = 32'h00f6e7b3;
                    6'd36: data_o = 32'h00e896b3;
                    6'd37: data_o = 32'hfff70713;
                    6'd38: data_o = 32'h00b7e663;
                    6'd39: data_o = 32'h40b787b3;
                    6'd40: data_o = 32'h00d56533;
                    6'd41: data_o = 32'hfd071ee3;
                    6'd42: data_o = 32'h00008067;
                    6'd43: data_o = 32'hfff00513;
                    6'd44: data_o = 32'h00008067;
                    6'd45: data_o = 32'h00050693;
                    6'd46: data_o = 32'h02058a63;
                    6'd47: data_o = 32'h01f00793;
                    6'd48: data_o = 32'h00000513;
                    6'd49: data_o = 32'hfff00613;
                    6'd50: data_o = 32'h00f6d733;
                    6'd51: data_o = 32'h00151513;
                    6'd52: data_o = 32'h00177713;
                    6'd53: data_o = 32'h00a76533;
                    6'd54: data_o = 32'hfff78793;
                    6'd55: data_o = 32'h00b56463;
                    6'd56: data_o = 32'h40b50533;
                    6'd57: data_o = 32'hfec792e3;
                    6'd58: data_o = 32'h00008067;
                    6'd59: data_o = 32'h00008067;
                    6'd60: data_o = 32'h06058863;
                    6'd61: data_o = 32'h41f55713;
                    6'd62: data_o = 32'h41f5d793;
                    6'd63: data_o = 32'h00a748b3;
                    default: data_o = 32'b0;
                endcase
                14'd1   : case (word_addr[5:0])   // words 64..127
                    6'd0 : data_o = 32'h00b7c633;
                    6'd1 : data_o = 32'h40e888b3;
                    6'd2 : data_o = 32'h40f60633;
                    6'd3 : data_o = 32'h00000813;
                    6'd4 : data_o = 32'h01f00713;
                    6'd5 : data_o = 32'h00000793;
                    6'd6 : data_o = 32'h00100e13;
                    6'd7 : data_o = 32'hfff00313;
                    6'd8 : data_o = 32'h00e8d6b3;
                    6'd9 : data_o = 32'h0016f693;
                    6'd10: data_o = 32'h00179793;
                    6'd11: data_o = 32'h00f6e7b3;
                    6'd12: data_o = 32'h00ee16b3;
                    6'd13: data_o = 32'hfff70713;
                    6'd14: data_o = 32'h00c7e663;
                    6'd15: data_o = 32'h40c787b3;
                    6'd16: data_o = 32'h00d86833;
                    6'd17: data_o = 32'hfc671ee3;
                    6'd18: data_o = 32'h00a5c5b3;
                    6'd19: data_o = 32'h00080513;
                    6'd20: data_o = 32'h0005c463;
                    6'd21: data_o = 32'h00008067;
                    6'd22: data_o = 32'h41000533;
                    6'd23: data_o = 32'h00008067;
                    6'd24: data_o = 32'hfff00513;
                    6'd25: data_o = 32'h00008067;
                    6'd26: data_o = 32'h00050893;
                    6'd27: data_o = 32'h04058863;
                    6'd28: data_o = 32'h41f5d713;
                    6'd29: data_o = 32'h41f55793;
                    6'd30: data_o = 32'h00b74633;
                    6'd31: data_o = 32'h00a7c833;
                    6'd32: data_o = 32'h40f80833;
                    6'd33: data_o = 32'h40e60633;
                    6'd34: data_o = 32'h00000793;
                    6'd35: data_o = 32'h01f00713;
                    6'd36: data_o = 32'hfff00593;
                    6'd37: data_o = 32'h00e856b3;
                    6'd38: data_o = 32'h00179793;
                    6'd39: data_o = 32'h0016f693;
                    6'd40: data_o = 32'h00f6e7b3;
                    6'd41: data_o = 32'hfff70713;
                    6'd42: data_o = 32'h00c7e463;
                    6'd43: data_o = 32'h40c787b3;
                    6'd44: data_o = 32'hfeb712e3;
                    6'd45: data_o = 32'h00078513;
                    6'd46: data_o = 32'h0008c463;
                    6'd47: data_o = 32'h00008067;
                    6'd48: data_o = 32'h40f00533;
                    6'd49: data_o = 32'h00008067;
                    6'd50: data_o = 32'hf1000737;
                    6'd51: data_o = 32'h00870713;
                    6'd52: data_o = 32'h00072783;
                    6'd53: data_o = 32'h0047f793;
                    6'd54: data_o = 32'hfe078ce3;
                    6'd55: data_o = 32'hf10007b7;
                    6'd56: data_o = 32'h00a7a023;
                    6'd57: data_o = 32'h00300793;
                    6'd58: data_o = 32'h00f72023;
                    6'd59: data_o = 32'h00008067;
                    6'd60: data_o = 32'hf10007b7;
                    6'd61: data_o = 32'h0087a703;
                    6'd62: data_o = 32'h00050693;
                    6'd63: data_o = 32'h00878793;
                    default: data_o = 32'b0;
                endcase
                14'd2   : case (word_addr[5:0])   // words 128..191
                    6'd0 : data_o = 32'h00277713;
                    6'd1 : data_o = 32'h00070e63;
                    6'd2 : data_o = 32'hf1000737;
                    6'd3 : data_o = 32'h00472603;
                    6'd4 : data_o = 32'h00100513;
                    6'd5 : data_o = 32'h00c68023;
                    6'd6 : data_o = 32'h0007a023;
                    6'd7 : data_o = 32'h00008067;
                    6'd8 : data_o = 32'h00000513;
                    6'd9 : data_o = 32'h00008067;
                    6'd10: data_o = 32'hf1000737;
                    6'd11: data_o = 32'h00870713;
                    6'd12: data_o = 32'h00072783;
                    6'd13: data_o = 32'h0027f793;
                    6'd14: data_o = 32'hfe078ce3;
                    6'd15: data_o = 32'hf10007b7;
                    6'd16: data_o = 32'h0047a503;
                    6'd17: data_o = 32'h00072023;
                    6'd18: data_o = 32'h0ff57513;
                    6'd19: data_o = 32'h00008067;
                    6'd20: data_o = 32'h00054683;
                    6'd21: data_o = 32'h02068a63;
                    6'd22: data_o = 32'hf1000737;
                    6'd23: data_o = 32'hf10005b7;
                    6'd24: data_o = 32'h00870713;
                    6'd25: data_o = 32'h00300613;
                    6'd26: data_o = 32'h00150513;
                    6'd27: data_o = 32'h00072783;
                    6'd28: data_o = 32'h0047f793;
                    6'd29: data_o = 32'hfe078ce3;
                    6'd30: data_o = 32'h00d5a023;
                    6'd31: data_o = 32'h00c72023;
                    6'd32: data_o = 32'h00054683;
                    6'd33: data_o = 32'hfe0692e3;
                    6'd34: data_o = 32'h00008067;
                    6'd35: data_o = 32'hf1000737;
                    6'd36: data_o = 32'h004035b7;
                    6'd37: data_o = 32'h01c00693;
                    6'd38: data_o = 32'hb2058593;
                    6'd39: data_o = 32'hf1000337;
                    6'd40: data_o = 32'h00870713;
                    6'd41: data_o = 32'h00300893;
                    6'd42: data_o = 32'hffc00813;
                    6'd43: data_o = 32'h00d557b3;
                    6'd44: data_o = 32'h00f7f793;
                    6'd45: data_o = 32'h00f587b3;
                    6'd46: data_o = 32'h0007c603;
                    6'd47: data_o = 32'h00072783;
                    6'd48: data_o = 32'h0047f793;
                    6'd49: data_o = 32'hfe078ce3;
                    6'd50: data_o = 32'h00c32023;
                    6'd51: data_o = 32'h01172023;
                    6'd52: data_o = 32'hffc68693;
                    6'd53: data_o = 32'hfd069ce3;
                    6'd54: data_o = 32'h00008067;
                    6'd55: data_o = 32'hfd010113;
                    6'd56: data_o = 32'h02812423;
                    6'd57: data_o = 32'h03212023;
                    6'd58: data_o = 32'h01312e23;
                    6'd59: data_o = 32'h01512a23;
                    6'd60: data_o = 32'h02112623;
                    6'd61: data_o = 32'h02912223;
                    6'd62: data_o = 32'h01412c23;
                    6'd63: data_o = 32'h00050413;
                    default: data_o = 32'b0;
                endcase
                14'd3   : case (word_addr[5:0])   // words 192..255
                    6'd0 : data_o = 32'h00000913;
                    6'd1 : data_o = 32'h00410993;
                    6'd2 : data_o = 32'h00900a93;
                    6'd3 : data_o = 32'h00a00593;
                    6'd4 : data_o = 32'h00040513;
                    6'd5 : data_o = 32'h00000097;
                    6'd6 : data_o = 32'hda0080e7;
                    6'd7 : data_o = 32'h00190913;
                    6'd8 : data_o = 32'h03050793;
                    6'd9 : data_o = 32'h012984b3;
                    6'd10: data_o = 32'h00040513;
                    6'd11: data_o = 32'h00a00593;
                    6'd12: data_o = 32'hfef48fa3;
                    6'd13: data_o = 32'h00040a13;
                    6'd14: data_o = 32'h00000097;
                    6'd15: data_o = 32'hd2c080e7;
                    6'd16: data_o = 32'h00050413;
                    6'd17: data_o = 32'hfd4ae4e3;
                    6'd18: data_o = 32'hf1000737;
                    6'd19: data_o = 32'h00048693;
                    6'd20: data_o = 32'hf1000537;
                    6'd21: data_o = 32'h00870713;
                    6'd22: data_o = 32'h00300593;
                    6'd23: data_o = 32'hfff6c603;
                    6'd24: data_o = 32'h00072783;
                    6'd25: data_o = 32'h0047f793;
                    6'd26: data_o = 32'hfe078ce3;
                    6'd27: data_o = 32'h00c52023;
                    6'd28: data_o = 32'h00b72023;
                    6'd29: data_o = 32'hfff68693;
                    6'd30: data_o = 32'hfed992e3;
                    6'd31: data_o = 32'h02c12083;
                    6'd32: data_o = 32'h02812403;
                    6'd33: data_o = 32'h02412483;
                    6'd34: data_o = 32'h02012903;
                    6'd35: data_o = 32'h01c12983;
                    6'd36: data_o = 32'h01812a03;
                    6'd37: data_o = 32'h01412a83;
                    6'd38: data_o = 32'h03010113;
                    6'd39: data_o = 32'h00008067;
                    6'd40: data_o = 32'hf10006b7;
                    6'd41: data_o = 32'h0ff57713;
                    6'd42: data_o = 32'h00868693;
                    6'd43: data_o = 32'h0006a783;
                    6'd44: data_o = 32'h0047f793;
                    6'd45: data_o = 32'hfe078ce3;
                    6'd46: data_o = 32'hf10007b7;
                    6'd47: data_o = 32'h00e7a023;
                    6'd48: data_o = 32'hf1000737;
                    6'd49: data_o = 32'h00300793;
                    6'd50: data_o = 32'h00f6a023;
                    6'd51: data_o = 32'h00855513;
                    6'd52: data_o = 32'h00870713;
                    6'd53: data_o = 32'h00072783;
                    6'd54: data_o = 32'h0047f793;
                    6'd55: data_o = 32'hfe078ce3;
                    6'd56: data_o = 32'hf10007b7;
                    6'd57: data_o = 32'h00a7a023;
                    6'd58: data_o = 32'h00300793;
                    6'd59: data_o = 32'h00f72023;
                    6'd60: data_o = 32'h00008067;
                    6'd61: data_o = 32'hf1000737;
                    6'd62: data_o = 32'h00000693;
                    6'd63: data_o = 32'hf10008b7;
                    default: data_o = 32'b0;
                endcase
                14'd4   : case (word_addr[5:0])   // words 256..319
                    6'd0 : data_o = 32'h00870713;
                    6'd1 : data_o = 32'h00300813;
                    6'd2 : data_o = 32'h02000593;
                    6'd3 : data_o = 32'h00d55633;
                    6'd4 : data_o = 32'h00072783;
                    6'd5 : data_o = 32'h0047f793;
                    6'd6 : data_o = 32'hfe078ce3;
                    6'd7 : data_o = 32'h0ff67793;
                    6'd8 : data_o = 32'h00f8a023;
                    6'd9 : data_o = 32'h01072023;
                    6'd10: data_o = 32'h00868693;
                    6'd11: data_o = 32'hfeb690e3;
                    6'd12: data_o = 32'h00008067;
                    6'd13: data_o = 32'hf1000637;
                    6'd14: data_o = 32'h00860613;
                    6'd15: data_o = 32'h00062783;
                    6'd16: data_o = 32'h0027f793;
                    6'd17: data_o = 32'hfe078ce3;
                    6'd18: data_o = 32'hf10007b7;
                    6'd19: data_o = 32'h0047a683;
                    6'd20: data_o = 32'hf1000737;
                    6'd21: data_o = 32'h00062023;
                    6'd22: data_o = 32'h0ff6f693;
                    6'd23: data_o = 32'h00870713;
                    6'd24: data_o = 32'h00072783;
                    6'd25: data_o = 32'h0027f793;
                    6'd26: data_o = 32'hfe078ce3;
                    6'd27: data_o = 32'hf10007b7;
                    6'd28: data_o = 32'h0047a503;
                    6'd29: data_o = 32'h00072023;
                    6'd30: data_o = 32'h0ff57513;
                    6'd31: data_o = 32'h00851513;
                    6'd32: data_o = 32'h00d56533;
                    6'd33: data_o = 32'h01051513;
                    6'd34: data_o = 32'h01055513;
                    6'd35: data_o = 32'h00008067;
                    6'd36: data_o = 32'hf10006b7;
                    6'd37: data_o = 32'hf1000637;
                    6'd38: data_o = 32'h00000713;
                    6'd39: data_o = 32'h00000513;
                    6'd40: data_o = 32'h00868693;
                    6'd41: data_o = 32'h00460613;
                    6'd42: data_o = 32'h02000593;
                    6'd43: data_o = 32'h0006a783;
                    6'd44: data_o = 32'h0027f793;
                    6'd45: data_o = 32'hfe078ce3;
                    6'd46: data_o = 32'h00062783;
                    6'd47: data_o = 32'h0006a023;
                    6'd48: data_o = 32'h0ff7f793;
                    6'd49: data_o = 32'h00e797b3;
                    6'd50: data_o = 32'h00870713;
                    6'd51: data_o = 32'h00f56533;
                    6'd52: data_o = 32'hfcb71ee3;
                    6'd53: data_o = 32'h00008067;
                    6'd54: data_o = 32'h00050793;
                    6'd55: data_o = 32'h02060063;
                    6'd56: data_o = 32'h00c58633;
                    6'd57: data_o = 32'h00158593;
                    6'd58: data_o = 32'hfff5c703;
                    6'd59: data_o = 32'h80f707b3;
                    6'd60: data_o = 32'hfec59ae3;
                    6'd61: data_o = 32'h01079513;
                    6'd62: data_o = 32'h01055513;
                    6'd63: data_o = 32'h00008067;
                    default: data_o = 32'b0;
                endcase
                14'd5   : case (word_addr[5:0])   // words 320..383
                    6'd0 : data_o = 32'h00452683;
                    6'd1 : data_o = 32'h00c52783;
                    6'd2 : data_o = 32'h00852883;
                    6'd3 : data_o = 32'h00052303;
                    6'd4 : data_o = 32'h01b6d813;
                    6'd5 : data_o = 32'h0187d593;
                    6'd6 : data_o = 32'h00569713;
                    6'd7 : data_o = 32'h00879613;
                    6'd8 : data_o = 32'h006686b3;
                    6'd9 : data_o = 32'h011787b3;
                    6'd10: data_o = 32'h01076733;
                    6'd11: data_o = 32'h00b66633;
                    6'd12: data_o = 32'h00f64633;
                    6'd13: data_o = 32'h00d74733;
                    6'd14: data_o = 32'h01069593;
                    6'd15: data_o = 32'h0106d693;
                    6'd16: data_o = 32'h00f707b3;
                    6'd17: data_o = 32'h00d5e6b3;
                    6'd18: data_o = 32'h00d61813;
                    6'd19: data_o = 32'h00771593;
                    6'd20: data_o = 32'h01365893;
                    6'd21: data_o = 32'h01975713;
                    6'd22: data_o = 32'h00c686b3;
                    6'd23: data_o = 32'h00e5e733;
                    6'd24: data_o = 32'h01186633;
                    6'd25: data_o = 32'h01079593;
                    6'd26: data_o = 32'h0107d813;
                    6'd27: data_o = 32'h00d64633;
                    6'd28: data_o = 32'h00f747b3;
                    6'd29: data_o = 32'h0105e733;
                    6'd30: data_o = 32'h00d52023;
                    6'd31: data_o = 32'h00c52623;
                    6'd32: data_o = 32'h00f52223;
                    6'd33: data_o = 32'h00e52423;
                    6'd34: data_o = 32'h00008067;
                    6'd35: data_o = 32'h00062783;
                    6'd36: data_o = 32'h00c62703;
                    6'd37: data_o = 32'h00179793;
                    6'd38: data_o = 32'h00075463;
                    6'd39: data_o = 32'h0877c793;
                    6'd40: data_o = 32'h00f52023;
                    6'd41: data_o = 32'h00462703;
                    6'd42: data_o = 32'h00062683;
                    6'd43: data_o = 32'h00179793;
                    6'd44: data_o = 32'h00171713;
                    6'd45: data_o = 32'h01f6d693;
                    6'd46: data_o = 32'h00d76733;
                    6'd47: data_o = 32'h00e52223;
                    6'd48: data_o = 32'h00862703;
                    6'd49: data_o = 32'h00462683;
                    6'd50: data_o = 32'h00171713;
                    6'd51: data_o = 32'h01f6d693;
                    6'd52: data_o = 32'h00d76733;
                    6'd53: data_o = 32'h00e52423;
                    6'd54: data_o = 32'h00c62703;
                    6'd55: data_o = 32'h00862683;
                    6'd56: data_o = 32'h00171713;
                    6'd57: data_o = 32'h01f6d693;
                    6'd58: data_o = 32'h00d76733;
                    6'd59: data_o = 32'h00e52623;
                    6'd60: data_o = 32'h00075463;
                    6'd61: data_o = 32'h0877c793;
                    6'd62: data_o = 32'h00f5a023;
                    6'd63: data_o = 32'h00452783;
                    default: data_o = 32'b0;
                endcase
                14'd6   : case (word_addr[5:0])   // words 384..447
                    6'd0 : data_o = 32'h00052703;
                    6'd1 : data_o = 32'h00179793;
                    6'd2 : data_o = 32'h01f75713;
                    6'd3 : data_o = 32'h00e7e7b3;
                    6'd4 : data_o = 32'h00f5a223;
                    6'd5 : data_o = 32'h00852783;
                    6'd6 : data_o = 32'h00452703;
                    6'd7 : data_o = 32'h00179793;
                    6'd8 : data_o = 32'h01f75713;
                    6'd9 : data_o = 32'h00e7e7b3;
                    6'd10: data_o = 32'h00f5a423;
                    6'd11: data_o = 32'h00c52783;
                    6'd12: data_o = 32'h00852703;
                    6'd13: data_o = 32'h00179793;
                    6'd14: data_o = 32'h01f75713;
                    6'd15: data_o = 32'h00e7e7b3;
                    6'd16: data_o = 32'h00f5a623;
                    6'd17: data_o = 32'h00008067;
                    6'd18: data_o = 32'h00472e03;
                    6'd19: data_o = 32'h00872303;
                    6'd20: data_o = 32'h00c72883;
                    6'd21: data_o = 32'h00072703;
                    6'd22: data_o = 32'hfc010113;
                    6'd23: data_o = 32'h02812c23;
                    6'd24: data_o = 32'h02912a23;
                    6'd25: data_o = 32'h02112e23;
                    6'd26: data_o = 32'h03212823;
                    6'd27: data_o = 32'h03312623;
                    6'd28: data_o = 32'h03412423;
                    6'd29: data_o = 32'h03512223;
                    6'd30: data_o = 32'h00e12023;
                    6'd31: data_o = 32'h01c12223;
                    6'd32: data_o = 32'h00612423;
                    6'd33: data_o = 32'h01112623;
                    6'd34: data_o = 32'h00050493;
                    6'd35: data_o = 32'h00058413;
                    6'd36: data_o = 32'h10068663;
                    6'd37: data_o = 32'hfff68f93;
                    6'd38: data_o = 32'h004fdf93;
                    6'd39: data_o = 32'h220f8063;
                    6'd40: data_o = 32'h004f9f93;
                    6'd41: data_o = 32'h01f602b3;
                    6'd42: data_o = 32'h00010913;
                    6'd43: data_o = 32'h01010f13;
                    6'd44: data_o = 32'h00060713;
                    6'd45: data_o = 32'h00090313;
                    6'd46: data_o = 32'h00174883;
                    6'd47: data_o = 32'h00074e83;
                    6'd48: data_o = 32'h00274503;
                    6'd49: data_o = 32'h00374583;
                    6'd50: data_o = 32'h00889893;
                    6'd51: data_o = 32'h00032e03;
                    6'd52: data_o = 32'h01d8e8b3;
                    6'd53: data_o = 32'h01051513;
                    6'd54: data_o = 32'h01156533;
                    6'd55: data_o = 32'h01859593;
                    6'd56: data_o = 32'h00a5e5b3;
                    6'd57: data_o = 32'h00be45b3;
                    6'd58: data_o = 32'h00b32023;
                    6'd59: data_o = 32'h00430313;
                    6'd60: data_o = 32'h00470713;
                    6'd61: data_o = 32'hfc6f12e3;
                    6'd62: data_o = 32'h00012883;
                    6'd63: data_o = 32'h00412303;
                    default: data_o = 32'b0;
                endcase
                14'd7   : case (word_addr[5:0])   // words 448..511
                    6'd0 : data_o = 32'h00812e03;
                    6'd1 : data_o = 32'h00c12583;
                    6'd2 : data_o = 32'h00c00e93;
                    6'd3 : data_o = 32'h0185d393;
                    6'd4 : data_o = 32'h00531713;
                    6'd5 : data_o = 32'h01b35093;
                    6'd6 : data_o = 32'h00859513;
                    6'd7 : data_o = 32'h006888b3;
                    6'd8 : data_o = 32'h00be0e33;
                    6'd9 : data_o = 32'h00756533;
                    6'd10: data_o = 32'h00176733;
                    6'd11: data_o = 32'h01174733;
                    6'd12: data_o = 32'h01c54533;
                    6'd13: data_o = 32'h01089593;
                    6'd14: data_o = 32'h0108d893;
                    6'd15: data_o = 32'h01c703b3;
                    6'd16: data_o = 32'h0115e8b3;
                    6'd17: data_o = 32'h01355e13;
                    6'd18: data_o = 32'h00771313;
                    6'd19: data_o = 32'h00d51593;
                    6'd20: data_o = 32'h01975713;
                    6'd21: data_o = 32'h01c5e5b3;
                    6'd22: data_o = 32'h00e36333;
                    6'd23: data_o = 32'h00a888b3;
                    6'd24: data_o = 32'h01039713;
                    6'd25: data_o = 32'h0103de13;
                    6'd26: data_o = 32'hfffe8e93;
                    6'd27: data_o = 32'h0115c5b3;
                    6'd28: data_o = 32'h00734333;
                    6'd29: data_o = 32'h00ee6e33;
                    6'd30: data_o = 32'hf80e9ae3;
                    6'd31: data_o = 32'h01112023;
                    6'd32: data_o = 32'h00b12623;
                    6'd33: data_o = 32'h00612223;
                    6'd34: data_o = 32'h01c12423;
                    6'd35: data_o = 32'h01060613;
                    6'd36: data_o = 32'hf25610e3;
                    6'd37: data_o = 32'h41f68fb3;
                    6'd38: data_o = 32'h0100006f;
                    6'd39: data_o = 32'h00000f93;
                    6'd40: data_o = 32'h00010913;
                    6'd41: data_o = 32'h01010f13;
                    6'd42: data_o = 32'h000f0313;
                    6'd43: data_o = 32'h000f0513;
                    6'd44: data_o = 32'h00000713;
                    6'd45: data_o = 32'h01000e13;
                    6'd46: data_o = 32'h41f705b3;
                    6'd47: data_o = 32'h00e608b3;
                    6'd48: data_o = 32'h0015b593;
                    6'd49: data_o = 32'h01f77463;
                    6'd50: data_o = 32'h0008c583;
                    6'd51: data_o = 32'h00b50023;
                    6'd52: data_o = 32'h00170713;
                    6'd53: data_o = 32'h00150513;
                    6'd54: data_o = 32'hffc710e3;
                    6'd55: data_o = 32'h00068463;
                    6'd56: data_o = 32'h0cef8a63;
                    6'd57: data_o = 32'h00080a93;
                    6'd58: data_o = 32'h00090a13;
                    6'd59: data_o = 32'h010f0f13;
                    6'd60: data_o = 32'h00090793;
                    6'd61: data_o = 32'h00080613;
                    6'd62: data_o = 32'h00062683;
                    6'd63: data_o = 32'h00032583;
                    default: data_o = 32'b0;
                endcase
                14'd8   : case (word_addr[5:0])   // words 512..575
                    6'd0 : data_o = 32'h0007a703;
                    6'd1 : data_o = 32'h00430313;
                    6'd2 : data_o = 32'h00b6c6b3;
                    6'd3 : data_o = 32'h00d74733;
                    6'd4 : data_o = 32'h00e7a023;
                    6'd5 : data_o = 32'h00460613;
                    6'd6 : data_o = 32'h00478793;
                    6'd7 : data_o = 32'hfc6f1ee3;
                    6'd8 : data_o = 32'h00c00993;
                    6'd9 : data_o = 32'h00090513;
                    6'd10: data_o = 32'hfff98993;
                    6'd11: data_o = 32'h00000097;
                    6'd12: data_o = 32'hcd4080e7;
                    6'd13: data_o = 32'hfe0998e3;
                    6'd14: data_o = 32'h01010693;
                    6'd15: data_o = 32'h000a2783;
                    6'd16: data_o = 32'h000aa703;
                    6'd17: data_o = 32'h004a0a13;
                    6'd18: data_o = 32'h004a8a93;
                    6'd19: data_o = 32'h00e7c7b3;
                    6'd20: data_o = 32'hfefa2e23;
                    6'd21: data_o = 32'hff4694e3;
                    6'd22: data_o = 32'h01000613;
                    6'd23: data_o = 32'h02040a63;
                    6'd24: data_o = 32'hffc9f793;
                    6'd25: data_o = 32'h02078793;
                    6'd26: data_o = 32'h002787b3;
                    6'd27: data_o = 32'hfe07a783;
                    6'd28: data_o = 32'h0039f713;
                    6'd29: data_o = 32'h00371713;
                    6'd30: data_o = 32'h013486b3;
                    6'd31: data_o = 32'h00e7d7b3;
                    6'd32: data_o = 32'h00f68023;
                    6'd33: data_o = 32'h00198993;
                    6'd34: data_o = 32'h01340463;
                    6'd35: data_o = 32'hfcc99ae3;
                    6'd36: data_o = 32'h03c12083;
                    6'd37: data_o = 32'h03812403;
                    6'd38: data_o = 32'h03412483;
                    6'd39: data_o = 32'h03012903;
                    6'd40: data_o = 32'h02c12983;
                    6'd41: data_o = 32'h02812a03;
                    6'd42: data_o = 32'h02412a83;
                    6'd43: data_o = 32'h04010113;
                    6'd44: data_o = 32'h00008067;
                    6'd45: data_o = 32'h00078813;
                    6'd46: data_o = 32'hf2dff06f;
                    6'd47: data_o = 32'h00068f93;
                    6'd48: data_o = 32'h00010913;
                    6'd49: data_o = 32'h01010f13;
                    6'd50: data_o = 32'hee1ff06f;
                    6'd51: data_o = 32'h02060063;
                    6'd52: data_o = 32'h00c50633;
                    6'd53: data_o = 32'h00050793;
                    6'd54: data_o = 32'h0005c703;
                    6'd55: data_o = 32'h00178793;
                    6'd56: data_o = 32'h00158593;
                    6'd57: data_o = 32'hfee78fa3;
                    6'd58: data_o = 32'hfef618e3;
                    6'd59: data_o = 32'h00008067;
                    6'd60: data_o = 32'h02b56663;
                    6'd61: data_o = 32'hfff60793;
                    6'd62: data_o = 32'hfff00813;
                    6'd63: data_o = 32'h04060263;
                    default: data_o = 32'b0;
                endcase
                14'd9   : case (word_addr[5:0])   // words 576..639
                    6'd0 : data_o = 32'h00f58733;
                    6'd1 : data_o = 32'h00074683;
                    6'd2 : data_o = 32'h00f50733;
                    6'd3 : data_o = 32'hfff78793;
                    6'd4 : data_o = 32'h00d70023;
                    6'd5 : data_o = 32'hff0796e3;
                    6'd6 : data_o = 32'h00008067;
                    6'd7 : data_o = 32'hfe060ee3;
                    6'd8 : data_o = 32'h00c50633;
                    6'd9 : data_o = 32'h00050793;
                    6'd10: data_o = 32'h0005c703;
                    6'd11: data_o = 32'h00178793;
                    6'd12: data_o = 32'h00158593;
                    6'd13: data_o = 32'hfee78fa3;
                    6'd14: data_o = 32'hfec798e3;
                    6'd15: data_o = 32'h00008067;
                    6'd16: data_o = 32'h00008067;
                    6'd17: data_o = 32'h0ff5f593;
                    6'd18: data_o = 32'h00c50733;
                    6'd19: data_o = 32'h00050793;
                    6'd20: data_o = 32'h00060863;
                    6'd21: data_o = 32'h00178793;
                    6'd22: data_o = 32'hfeb78fa3;
                    6'd23: data_o = 32'hfef71ce3;
                    6'd24: data_o = 32'h00008067;
                    6'd25: data_o = 32'h02060663;
                    6'd26: data_o = 32'h00c50633;
                    6'd27: data_o = 32'h0080006f;
                    6'd28: data_o = 32'h02c50063;
                    6'd29: data_o = 32'h00054783;
                    6'd30: data_o = 32'h0005c703;
                    6'd31: data_o = 32'h00150513;
                    6'd32: data_o = 32'h00158593;
                    6'd33: data_o = 32'hfee786e3;
                    6'd34: data_o = 32'h40e78533;
                    6'd35: data_o = 32'h00008067;
                    6'd36: data_o = 32'h00000513;
                    6'd37: data_o = 32'h00008067;
                    6'd38: data_o = 32'h00452683;
                    6'd39: data_o = 32'h00852603;
                    6'd40: data_o = 32'h00052583;
                    6'd41: data_o = 32'h00369813;
                    6'd42: data_o = 32'h00d80833;
                    6'd43: data_o = 32'h00261793;
                    6'd44: data_o = 32'h00781713;
                    6'd45: data_o = 32'h00c787b3;
                    6'd46: data_o = 32'h41070733;
                    6'd47: data_o = 32'h00279793;
                    6'd48: data_o = 32'h00259813;
                    6'd49: data_o = 32'h00271713;
                    6'd50: data_o = 32'h40c787b3;
                    6'd51: data_o = 32'h00b80833;
                    6'd52: data_o = 32'h40d70733;
                    6'd53: data_o = 32'h00479793;
                    6'd54: data_o = 32'h00381813;
                    6'd55: data_o = 32'h00271713;
                    6'd56: data_o = 32'h40c787b3;
                    6'd57: data_o = 32'h00b80833;
                    6'd58: data_o = 32'h00d70733;
                    6'd59: data_o = 32'h00479793;
                    6'd60: data_o = 32'h40c787b3;
                    6'd61: data_o = 32'h00781813;
                    6'd62: data_o = 32'h00271713;
                    6'd63: data_o = 32'h40b80833;
                    default: data_o = 32'b0;
                endcase
                14'd10  : case (word_addr[5:0])   // words 640..703
                    6'd0 : data_o = 32'h40d70733;
                    6'd1 : data_o = 32'h00679893;
                    6'd2 : data_o = 32'h011787b3;
                    6'd3 : data_o = 32'h00281813;
                    6'd4 : data_o = 32'h00271713;
                    6'd5 : data_o = 32'h40b80833;
                    6'd6 : data_o = 32'h40d70733;
                    6'd7 : data_o = 32'h00579793;
                    6'd8 : data_o = 32'h40c787b3;
                    6'd9 : data_o = 32'h00581313;
                    6'd10: data_o = 32'h00671713;
                    6'd11: data_o = 32'h41030333;
                    6'd12: data_o = 32'h00d70733;
                    6'd13: data_o = 32'h00379813;
                    6'd14: data_o = 32'h010787b3;
                    6'd15: data_o = 32'h00471893;
                    6'd16: data_o = 32'h00831813;
                    6'd17: data_o = 32'h40680833;
                    6'd18: data_o = 32'h40e888b3;
                    6'd19: data_o = 32'h00379313;
                    6'd20: data_o = 32'h00481713;
                    6'd21: data_o = 32'h006787b3;
                    6'd22: data_o = 32'h00389813;
                    6'd23: data_o = 32'h00b70733;
                    6'd24: data_o = 32'h40d806b3;
                    6'd25: data_o = 32'h00279793;
                    6'd26: data_o = 32'h00d74733;
                    6'd27: data_o = 32'h00c787b3;
                    6'd28: data_o = 32'h00f74733;
                    6'd29: data_o = 32'h00871793;
                    6'd30: data_o = 32'h40e787b3;
                    6'd31: data_o = 32'h00479793;
                    6'd32: data_o = 32'h40e787b3;
                    6'd33: data_o = 32'h00279793;
                    6'd34: data_o = 32'h40e787b3;
                    6'd35: data_o = 32'h00479793;
                    6'd36: data_o = 32'h00e787b3;
                    6'd37: data_o = 32'h00379793;
                    6'd38: data_o = 32'h00e787b3;
                    6'd39: data_o = 32'h00279693;
                    6'd40: data_o = 32'h00d787b3;
                    6'd41: data_o = 32'h00279793;
                    6'd42: data_o = 32'h40e787b3;
                    6'd43: data_o = 32'h00479793;
                    6'd44: data_o = 32'h40e787b3;
                    6'd45: data_o = 32'h01a7d793;
                    6'd46: data_o = 32'hf10005b7;
                    6'd47: data_o = 32'hf1000f37;
                    6'd48: data_o = 32'h100106b7;
                    6'd49: data_o = 32'h10010337;
                    6'd50: data_o = 32'h00878e93;
                    6'd51: data_o = 32'h02468693;
                    6'd52: data_o = 32'h00858593;
                    6'd53: data_o = 32'h004f0f13;
                    6'd54: data_o = 32'h03f00293;
                    6'd55: data_o = 32'h19c30313;
                    6'd56: data_o = 32'h00100e13;
                    6'd57: data_o = 32'h0005a703;
                    6'd58: data_o = 32'h03f7f613;
                    6'd59: data_o = 32'h00277713;
                    6'd60: data_o = 32'h02070863;
                    6'd61: data_o = 32'h000f2f83;
                    6'd62: data_o = 32'h0005a023;
                    6'd63: data_o = 32'h0006a703;
                    default: data_o = 32'b0;
                endcase
                14'd11  : case (word_addr[5:0])   // words 704..767
                    6'd0 : data_o = 32'h0046a803;
                    6'd1 : data_o = 32'h03f77893;
                    6'd2 : data_o = 32'h41070833;
                    6'd3 : data_o = 32'h011308b3;
                    6'd4 : data_o = 32'h00170713;
                    6'd5 : data_o = 32'h0702e463;
                    6'd6 : data_o = 32'h00e6a023;
                    6'd7 : data_o = 32'h01f88023;
                    6'd8 : data_o = 32'h00c68733;
                    6'd9 : data_o = 32'h00c74703;
                    6'd10: data_o = 32'h00178793;
                    6'd11: data_o = 32'h00070663;
                    6'd12: data_o = 32'h01c70863;
                    6'd13: data_o = 32'hfbd798e3;
                    6'd14: data_o = 32'hfff00513;
                    6'd15: data_o = 32'h00008067;
                    6'd16: data_o = 32'h00161713;
                    6'd17: data_o = 32'h00c70733;
                    6'd18: data_o = 32'h00271713;
                    6'd19: data_o = 32'h00e30733;
                    6'd20: data_o = 32'h04072883;
                    6'd21: data_o = 32'h00052803;
                    6'd22: data_o = 32'hfd089ee3;
                    6'd23: data_o = 32'h04472883;
                    6'd24: data_o = 32'h00452803;
                    6'd25: data_o = 32'hfd0898e3;
                    6'd26: data_o = 32'h04872803;
                    6'd27: data_o = 32'h00852703;
                    6'd28: data_o = 32'hfce812e3;
                    6'd29: data_o = 32'h00060513;
                    6'd30: data_o = 32'h00008067;
                    6'd31: data_o = 32'h0086a703;
                    6'd32: data_o = 32'h00170713;
                    6'd33: data_o = 32'h00e6a423;
                    6'd34: data_o = 32'hf99ff06f;
                    6'd35: data_o = 32'h00452683;
                    6'd36: data_o = 32'h00852603;
                    6'd37: data_o = 32'h00052583;
                    6'd38: data_o = 32'h00369813;
                    6'd39: data_o = 32'h00d80833;
                    6'd40: data_o = 32'h00261793;
                    6'd41: data_o = 32'h00781713;
                    6'd42: data_o = 32'h00c787b3;
                    6'd43: data_o = 32'h41070733;
                    6'd44: data_o = 32'h00279793;
                    6'd45: data_o = 32'h00259813;
                    6'd46: data_o = 32'h00271713;
                    6'd47: data_o = 32'h40c787b3;
                    6'd48: data_o = 32'h00b80833;
                    6'd49: data_o = 32'h40d70733;
                    6'd50: data_o = 32'h00479793;
                    6'd51: data_o = 32'h00381813;
                    6'd52: data_o = 32'h00271713;
                    6'd53: data_o = 32'h40c787b3;
                    6'd54: data_o = 32'h00b80833;
                    6'd55: data_o = 32'h00d70733;
                    6'd56: data_o = 32'h00479793;
                    6'd57: data_o = 32'h40c787b3;
                    6'd58: data_o = 32'h00781813;
                    6'd59: data_o = 32'h00271713;
                    6'd60: data_o = 32'h40b80833;
                    6'd61: data_o = 32'h40d70733;
                    6'd62: data_o = 32'h00679893;
                    6'd63: data_o = 32'h011787b3;
                    default: data_o = 32'b0;
                endcase
                14'd12  : case (word_addr[5:0])   // words 768..831
                    6'd0 : data_o = 32'h00281813;
                    6'd1 : data_o = 32'h00271713;
                    6'd2 : data_o = 32'h40b80833;
                    6'd3 : data_o = 32'h40d70733;
                    6'd4 : data_o = 32'h00579793;
                    6'd5 : data_o = 32'h40c787b3;
                    6'd6 : data_o = 32'h00581313;
                    6'd7 : data_o = 32'h00671713;
                    6'd8 : data_o = 32'h41030333;
                    6'd9 : data_o = 32'h00d70733;
                    6'd10: data_o = 32'h00379813;
                    6'd11: data_o = 32'h010787b3;
                    6'd12: data_o = 32'h00471893;
                    6'd13: data_o = 32'h00831813;
                    6'd14: data_o = 32'h40680833;
                    6'd15: data_o = 32'h40e888b3;
                    6'd16: data_o = 32'h00379313;
                    6'd17: data_o = 32'h00481713;
                    6'd18: data_o = 32'h006787b3;
                    6'd19: data_o = 32'h00389813;
                    6'd20: data_o = 32'h40d806b3;
                    6'd21: data_o = 32'h00b70733;
                    6'd22: data_o = 32'h00279793;
                    6'd23: data_o = 32'h00d74733;
                    6'd24: data_o = 32'h00c787b3;
                    6'd25: data_o = 32'h00f74733;
                    6'd26: data_o = 32'h00871793;
                    6'd27: data_o = 32'h40e787b3;
                    6'd28: data_o = 32'h00479793;
                    6'd29: data_o = 32'h40e787b3;
                    6'd30: data_o = 32'h00279793;
                    6'd31: data_o = 32'h40e787b3;
                    6'd32: data_o = 32'h00479793;
                    6'd33: data_o = 32'h00e787b3;
                    6'd34: data_o = 32'h00379793;
                    6'd35: data_o = 32'h00e787b3;
                    6'd36: data_o = 32'h00279693;
                    6'd37: data_o = 32'h00d787b3;
                    6'd38: data_o = 32'h00279793;
                    6'd39: data_o = 32'h40e787b3;
                    6'd40: data_o = 32'h00479793;
                    6'd41: data_o = 32'h40e787b3;
                    6'd42: data_o = 32'h01a7d793;
                    6'd43: data_o = 32'hf10008b7;
                    6'd44: data_o = 32'hf1000eb7;
                    6'd45: data_o = 32'h100105b7;
                    6'd46: data_o = 32'h10010837;
                    6'd47: data_o = 32'h00878e13;
                    6'd48: data_o = 32'h02458593;
                    6'd49: data_o = 32'h00888893;
                    6'd50: data_o = 32'h004e8e93;
                    6'd51: data_o = 32'h03f00f13;
                    6'd52: data_o = 32'h19c80813;
                    6'd53: data_o = 32'h0008a703;
                    6'd54: data_o = 32'h03f7f693;
                    6'd55: data_o = 32'h00277713;
                    6'd56: data_o = 32'h02070863;
                    6'd57: data_o = 32'h000eaf83;
                    6'd58: data_o = 32'h0008a023;
                    6'd59: data_o = 32'h0005a703;
                    6'd60: data_o = 32'h0045a603;
                    6'd61: data_o = 32'h03f77313;
                    6'd62: data_o = 32'h40c70633;
                    6'd63: data_o = 32'h00680333;
                    default: data_o = 32'b0;
                endcase
                14'd13  : case (word_addr[5:0])   // words 832..895
                    6'd0 : data_o = 32'h00170713;
                    6'd1 : data_o = 32'h06cf6263;
                    6'd2 : data_o = 32'h00e5a023;
                    6'd3 : data_o = 32'h01f30023;
                    6'd4 : data_o = 32'h00d58633;
                    6'd5 : data_o = 32'h00269713;
                    6'd6 : data_o = 32'h04c64603;
                    6'd7 : data_o = 32'h00d70733;
                    6'd8 : data_o = 32'h00271713;
                    6'd9 : data_o = 32'h00e80733;
                    6'd10: data_o = 32'h00178793;
                    6'd11: data_o = 32'h00060a63;
                    6'd12: data_o = 32'h34072303;
                    6'd13: data_o = 32'h00052603;
                    6'd14: data_o = 32'h00c30863;
                    6'd15: data_o = 32'hf9c79ce3;
                    6'd16: data_o = 32'hfff00513;
                    6'd17: data_o = 32'h00008067;
                    6'd18: data_o = 32'h34472303;
                    6'd19: data_o = 32'h00452603;
                    6'd20: data_o = 32'hfec316e3;
                    6'd21: data_o = 32'h34872603;
                    6'd22: data_o = 32'h00852703;
                    6'd23: data_o = 32'hfee610e3;
                    6'd24: data_o = 32'h00068513;
                    6'd25: data_o = 32'h00008067;
                    6'd26: data_o = 32'h0085a703;
                    6'd27: data_o = 32'h00170713;
                    6'd28: data_o = 32'h00e5a423;
                    6'd29: data_o = 32'hf9dff06f;
                    6'd30: data_o = 32'h00452683;
                    6'd31: data_o = 32'h00852803;
                    6'd32: data_o = 32'h00052883;
                    6'd33: data_o = 32'h00369313;
                    6'd34: data_o = 32'h00d30333;
                    6'd35: data_o = 32'h00281793;
                    6'd36: data_o = 32'h00731713;
                    6'd37: data_o = 32'h010787b3;
                    6'd38: data_o = 32'h40670733;
                    6'd39: data_o = 32'h00279793;
                    6'd40: data_o = 32'h00289313;
                    6'd41: data_o = 32'h00271713;
                    6'd42: data_o = 32'h410787b3;
                    6'd43: data_o = 32'h01130333;
                    6'd44: data_o = 32'h40d70733;
                    6'd45: data_o = 32'h00479793;
                    6'd46: data_o = 32'h00331313;
                    6'd47: data_o = 32'h00271713;
                    6'd48: data_o = 32'h410787b3;
                    6'd49: data_o = 32'h01130333;
                    6'd50: data_o = 32'h00d70733;
                    6'd51: data_o = 32'h00479793;
                    6'd52: data_o = 32'h410787b3;
                    6'd53: data_o = 32'h00731313;
                    6'd54: data_o = 32'h00271713;
                    6'd55: data_o = 32'h41130333;
                    6'd56: data_o = 32'h40d70733;
                    6'd57: data_o = 32'h00679e13;
                    6'd58: data_o = 32'h01c787b3;
                    6'd59: data_o = 32'h00231313;
                    6'd60: data_o = 32'h00271713;
                    6'd61: data_o = 32'h41130333;
                    6'd62: data_o = 32'h40d70733;
                    6'd63: data_o = 32'h00579793;
                    default: data_o = 32'b0;
                endcase
                14'd14  : case (word_addr[5:0])   // words 896..959
                    6'd0 : data_o = 32'h410787b3;
                    6'd1 : data_o = 32'h00531e93;
                    6'd2 : data_o = 32'h00671713;
                    6'd3 : data_o = 32'h406e8eb3;
                    6'd4 : data_o = 32'h00d70733;
                    6'd5 : data_o = 32'h00379313;
                    6'd6 : data_o = 32'h006787b3;
                    6'd7 : data_o = 32'h00471e13;
                    6'd8 : data_o = 32'h008e9313;
                    6'd9 : data_o = 32'h41d30333;
                    6'd10: data_o = 32'h40ee0e33;
                    6'd11: data_o = 32'h00379e93;
                    6'd12: data_o = 32'h00431713;
                    6'd13: data_o = 32'h01d787b3;
                    6'd14: data_o = 32'h003e1313;
                    6'd15: data_o = 32'h40d306b3;
                    6'd16: data_o = 32'h01170733;
                    6'd17: data_o = 32'h00279793;
                    6'd18: data_o = 32'h00d74733;
                    6'd19: data_o = 32'h010787b3;
                    6'd20: data_o = 32'h00f74733;
                    6'd21: data_o = 32'h00871793;
                    6'd22: data_o = 32'h40e787b3;
                    6'd23: data_o = 32'h00479793;
                    6'd24: data_o = 32'h40e787b3;
                    6'd25: data_o = 32'h00279793;
                    6'd26: data_o = 32'h40e787b3;
                    6'd27: data_o = 32'h00479793;
                    6'd28: data_o = 32'h00e787b3;
                    6'd29: data_o = 32'h00379793;
                    6'd30: data_o = 32'h00e787b3;
                    6'd31: data_o = 32'h00279693;
                    6'd32: data_o = 32'h00d787b3;
                    6'd33: data_o = 32'h00279793;
                    6'd34: data_o = 32'h40e787b3;
                    6'd35: data_o = 32'h00479793;
                    6'd36: data_o = 32'h40e787b3;
                    6'd37: data_o = 32'hff010113;
                    6'd38: data_o = 32'h01a7d793;
                    6'd39: data_o = 32'hf1000e37;
                    6'd40: data_o = 32'hf10003b7;
                    6'd41: data_o = 32'h10010337;
                    6'd42: data_o = 32'h100108b7;
                    6'd43: data_o = 32'h00812623;
                    6'd44: data_o = 32'h00912423;
                    6'd45: data_o = 32'h01212223;
                    6'd46: data_o = 32'h00878293;
                    6'd47: data_o = 32'h00000e93;
                    6'd48: data_o = 32'h00000f93;
                    6'd49: data_o = 32'h00000f13;
                    6'd50: data_o = 32'h02430313;
                    6'd51: data_o = 32'h19c88893;
                    6'd52: data_o = 32'h008e0e13;
                    6'd53: data_o = 32'h00438393;
                    6'd54: data_o = 32'h03f00413;
                    6'd55: data_o = 32'h0300006f;
                    6'd56: data_o = 32'h01070733;
                    6'd57: data_o = 32'h00271713;
                    6'd58: data_o = 32'h00e88733;
                    6'd59: data_o = 32'h34c72703;
                    6'd60: data_o = 32'h000e8463;
                    6'd61: data_o = 32'h01f77663;
                    6'd62: data_o = 32'h00070f93;
                    6'd63: data_o = 32'h00080f13;
                    default: data_o = 32'b0;
                endcase
                14'd15  : case (word_addr[5:0])   // words 960..1023
                    6'd0 : data_o = 32'h00178793;
                    6'd1 : data_o = 32'h00100e93;
                    6'd2 : data_o = 32'h08578263;
                    6'd3 : data_o = 32'h000e2703;
                    6'd4 : data_o = 32'h03f7f813;
                    6'd5 : data_o = 32'h00277713;
                    6'd6 : data_o = 32'h02070863;
                    6'd7 : data_o = 32'h0003a483;
                    6'd8 : data_o = 32'h000e2023;
                    6'd9 : data_o = 32'h00032703;
                    6'd10: data_o = 32'h00432683;
                    6'd11: data_o = 32'h40d706b3;
                    6'd12: data_o = 32'h0ad46663;
                    6'd13: data_o = 32'h03f77693;
                    6'd14: data_o = 32'h00d886b3;
                    6'd15: data_o = 32'h00170713;
                    6'd16: data_o = 32'h00e32023;
                    6'd17: data_o = 32'h00968023;
                    6'd18: data_o = 32'h01030733;
                    6'd19: data_o = 32'h04c74703;
                    6'd20: data_o = 32'h02070c63;
                    6'd21: data_o = 32'h00281713;
                    6'd22: data_o = 32'h010706b3;
                    6'd23: data_o = 32'h00269693;
                    6'd24: data_o = 32'h00d886b3;
                    6'd25: data_o = 32'h3406a483;
                    6'd26: data_o = 32'h00052903;
                    6'd27: data_o = 32'hf7249ae3;
                    6'd28: data_o = 32'h00452483;
                    6'd29: data_o = 32'h3446a903;
                    6'd30: data_o = 32'hf69914e3;
                    6'd31: data_o = 32'h3486a483;
                    6'd32: data_o = 32'h00852683;
                    6'd33: data_o = 32'hf4d49ee3;
                    6'd34: data_o = 32'h00080f13;
                    6'd35: data_o = 32'h002f1793;
                    6'd36: data_o = 32'h01e787b3;
                    6'd37: data_o = 32'h00279793;
                    6'd38: data_o = 32'h00f888b3;
                    6'd39: data_o = 32'h01e30333;
                    6'd40: data_o = 32'h00100793;
                    6'd41: data_o = 32'h04f30623;
                    6'd42: data_o = 32'h00052803;
                    6'd43: data_o = 32'h00452683;
                    6'd44: data_o = 32'h00852703;
                    6'd45: data_o = 32'h00c12403;
                    6'd46: data_o = 32'h3508a023;
                    6'd47: data_o = 32'h34d8a223;
                    6'd48: data_o = 32'h34e8a423;
                    6'd49: data_o = 32'h34b8a823;
                    6'd50: data_o = 32'h34c8a623;
                    6'd51: data_o = 32'h00812483;
                    6'd52: data_o = 32'h00412903;
                    6'd53: data_o = 32'h01010113;
                    6'd54: data_o = 32'h00008067;
                    6'd55: data_o = 32'h00832703;
                    6'd56: data_o = 32'h00170713;
                    6'd57: data_o = 32'h00e32423;
                    6'd58: data_o = 32'hf61ff06f;
                    6'd59: data_o = 32'hf10007b7;
                    6'd60: data_o = 32'h0087a703;
                    6'd61: data_o = 32'h00878793;
                    6'd62: data_o = 32'h00277713;
                    6'd63: data_o = 32'h0c071463;
                    default: data_o = 32'b0;
                endcase
                14'd16  : case (word_addr[5:0])   // words 1024..1087
                    6'd0 : data_o = 32'h10010e37;
                    6'd1 : data_o = 32'h024e0e13;
                    6'd2 : data_o = 32'h08ce2603;
                    6'd3 : data_o = 32'h10060c63;
                    6'd4 : data_o = 32'h100118b7;
                    6'd5 : data_o = 32'h19c88893;
                    6'd6 : data_o = 32'h00052803;
                    6'd7 : data_o = 32'h84088793;
                    6'd8 : data_o = 32'h00000713;
                    6'd9 : data_o = 32'h0100006f;
                    6'd10: data_o = 32'h00170713;
                    6'd11: data_o = 32'h01478793;
                    6'd12: data_o = 32'h04e60663;
                    6'd13: data_o = 32'h0007a683;
                    6'd14: data_o = 32'hff0698e3;
                    6'd15: data_o = 32'h0047a303;
                    6'd16: data_o = 32'h00452683;
                    6'd17: data_o = 32'hfed312e3;
                    6'd18: data_o = 32'h0087a303;
                    6'd19: data_o = 32'h00852683;
                    6'd20: data_o = 32'hfcd31ce3;
                    6'd21: data_o = 32'h00271793;
                    6'd22: data_o = 32'h00e787b3;
                    6'd23: data_o = 32'h00279793;
                    6'd24: data_o = 32'h00f888b3;
                    6'd25: data_o = 32'h84c8a783;
                    6'd26: data_o = 32'h8508a703;
                    6'd27: data_o = 32'h00178793;
                    6'd28: data_o = 32'h84f8a623;
                    6'd29: data_o = 32'h0ab76463;
                    6'd30: data_o = 32'h00008067;
                    6'd31: data_o = 32'h00400793;
                    6'd32: data_o = 32'h04f60063;
                    6'd33: data_o = 32'h00160713;
                    6'd34: data_o = 32'h00261793;
                    6'd35: data_o = 32'h00052683;
                    6'd36: data_o = 32'h00c787b3;
                    6'd37: data_o = 32'h00279793;
                    6'd38: data_o = 32'h00f888b3;
                    6'd39: data_o = 32'h84d8a023;
                    6'd40: data_o = 32'h00452783;
                    6'd41: data_o = 32'h08ee2623;
                    6'd42: data_o = 32'h00100713;
                    6'd43: data_o = 32'h84f8a223;
                    6'd44: data_o = 32'h00852783;
                    6'd45: data_o = 32'h84e8a623;
                    6'd46: data_o = 32'h84b8a823;
                    6'd47: data_o = 32'h84f8a423;
                    6'd48: data_o = 32'h00008067;
                    6'd49: data_o = 32'hf10006b7;
                    6'd50: data_o = 32'h10010e37;
                    6'd51: data_o = 32'h024e0e13;
                    6'd52: data_o = 32'h0046a803;
                    6'd53: data_o = 32'h0007a023;
                    6'd54: data_o = 32'h000e2783;
                    6'd55: data_o = 32'h004e2703;
                    6'd56: data_o = 32'h03f00613;
                    6'd57: data_o = 32'h40e78733;
                    6'd58: data_o = 32'h02e66263;
                    6'd59: data_o = 32'h10010737;
                    6'd60: data_o = 32'h03f7f693;
                    6'd61: data_o = 32'h19c70713;
                    6'd62: data_o = 32'h00178793;
                    6'd63: data_o = 32'h00d70733;
                    default: data_o = 32'b0;
                endcase
                14'd17  : case (word_addr[5:0])   // words 1088..1151
                    6'd0 : data_o = 32'h00fe2023;
                    6'd1 : data_o = 32'h01070023;
                    6'd2 : data_o = 32'hf01ff06f;
                    6'd3 : data_o = 32'h008e2783;
                    6'd4 : data_o = 32'h00178793;
                    6'd5 : data_o = 32'h00fe2423;
                    6'd6 : data_o = 32'hef1ff06f;
                    6'd7 : data_o = 32'h84b8a823;
                    6'd8 : data_o = 32'h00008067;
                    6'd9 : data_o = 32'h100118b7;
                    6'd10: data_o = 32'h00100713;
                    6'd11: data_o = 32'h19c88893;
                    6'd12: data_o = 32'hf59ff06f;
                    6'd13: data_o = 32'h0025d783;
                    6'd14: data_o = 32'h0005d703;
                    6'd15: data_o = 32'h01079793;
                    6'd16: data_o = 32'h00e7e7b3;
                    6'd17: data_o = 32'h00f52023;
                    6'd18: data_o = 32'h0065d783;
                    6'd19: data_o = 32'h0045d703;
                    6'd20: data_o = 32'h01079793;
                    6'd21: data_o = 32'h00e7e7b3;
                    6'd22: data_o = 32'h00f52223;
                    6'd23: data_o = 32'h00a5d783;
                    6'd24: data_o = 32'h0085d703;
                    6'd25: data_o = 32'h01079793;
                    6'd26: data_o = 32'h00e7e7b3;
                    6'd27: data_o = 32'h00f52423;
                    6'd28: data_o = 32'h00008067;
                    6'd29: data_o = 32'hf1000eb7;
                    6'd30: data_o = 32'h10010637;
                    6'd31: data_o = 32'h100118b7;
                    6'd32: data_o = 32'h00000793;
                    6'd33: data_o = 32'h02460613;
                    6'd34: data_o = 32'h19c88893;
                    6'd35: data_o = 32'h00300313;
                    6'd36: data_o = 32'h00800e13;
                    6'd37: data_o = 32'h008e8e93;
                    6'd38: data_o = 32'h09062683;
                    6'd39: data_o = 32'h00f50733;
                    6'd40: data_o = 32'h00074803;
                    6'd41: data_o = 32'h07f6f713;
                    6'd42: data_o = 32'h00168593;
                    6'd43: data_o = 32'h00e88733;
                    6'd44: data_o = 32'h08b62823;
                    6'd45: data_o = 32'h89070823;
                    6'd46: data_o = 32'h06678063;
                    6'd47: data_o = 32'h00178793;
                    6'd48: data_o = 32'hfdc79ce3;
                    6'd49: data_o = 32'hf10007b7;
                    6'd50: data_o = 32'h0087a703;
                    6'd51: data_o = 32'h00878793;
                    6'd52: data_o = 32'h00277713;
                    6'd53: data_o = 32'h06070e63;
                    6'd54: data_o = 32'hf1000737;
                    6'd55: data_o = 32'h00472503;
                    6'd56: data_o = 32'h0007a023;
                    6'd57: data_o = 32'h00062683;
                    6'd58: data_o = 32'h00462783;
                    6'd59: data_o = 32'h03f00593;
                    6'd60: data_o = 32'h40f687b3;
                    6'd61: data_o = 32'h0af5e863;
                    6'd62: data_o = 32'h100107b7;
                    6'd63: data_o = 32'h03f6f713;
                    default: data_o = 32'b0;
                endcase
                14'd18  : case (word_addr[5:0])   // words 1152..1215
                    6'd0 : data_o = 32'h19c78793;
                    6'd1 : data_o = 32'h00168693;
                    6'd2 : data_o = 32'h00e787b3;
                    6'd3 : data_o = 32'h00d62023;
                    6'd4 : data_o = 32'h00a78023;
                    6'd5 : data_o = 32'h00008067;
                    6'd6 : data_o = 32'h000ea783;
                    6'd7 : data_o = 32'hf1000737;
                    6'd8 : data_o = 32'h07f5f593;
                    6'd9 : data_o = 32'h0027f793;
                    6'd10: data_o = 32'h00470713;
                    6'd11: data_o = 32'h03f00813;
                    6'd12: data_o = 32'h00268693;
                    6'd13: data_o = 32'h00b885b3;
                    6'd14: data_o = 32'h00079e63;
                    6'd15: data_o = 32'h00454703;
                    6'd16: data_o = 32'h08d62823;
                    6'd17: data_o = 32'h00400793;
                    6'd18: data_o = 32'h88e58823;
                    6'd19: data_o = 32'hf71ff06f;
                    6'd20: data_o = 32'h00008067;
                    6'd21: data_o = 32'h00072f03;
                    6'd22: data_o = 32'h000ea023;
                    6'd23: data_o = 32'h00062783;
                    6'd24: data_o = 32'h00462683;
                    6'd25: data_o = 32'h03f7f593;
                    6'd26: data_o = 32'h40d786b3;
                    6'd27: data_o = 32'h00178713;
                    6'd28: data_o = 32'h100107b7;
                    6'd29: data_o = 32'h19c78793;
                    6'd30: data_o = 32'h00b787b3;
                    6'd31: data_o = 32'h00d86a63;
                    6'd32: data_o = 32'h01e78023;
                    6'd33: data_o = 32'h00e62023;
                    6'd34: data_o = 32'h00400793;
                    6'd35: data_o = 32'hf0dff06f;
                    6'd36: data_o = 32'h00862783;
                    6'd37: data_o = 32'h00178793;
                    6'd38: data_o = 32'h00f62423;
                    6'd39: data_o = 32'h00400793;
                    6'd40: data_o = 32'hef9ff06f;
                    6'd41: data_o = 32'h00862783;
                    6'd42: data_o = 32'h00178793;
                    6'd43: data_o = 32'h00f62423;
                    6'd44: data_o = 32'h00008067;
                    6'd45: data_o = 32'hfc010113;
                    6'd46: data_o = 32'h02812c23;
                    6'd47: data_o = 32'h10010437;
                    6'd48: data_o = 32'h02912a23;
                    6'd49: data_o = 32'h03312623;
                    6'd50: data_o = 32'h03412423;
                    6'd51: data_o = 32'h03512223;
                    6'd52: data_o = 32'h02440413;
                    6'd53: data_o = 32'hf10004b7;
                    6'd54: data_o = 32'h10010ab7;
                    6'd55: data_o = 32'h01000a37;
                    6'd56: data_o = 32'h000109b7;
                    6'd57: data_o = 32'h03212823;
                    6'd58: data_o = 32'h03612023;
                    6'd59: data_o = 32'h02112e23;
                    6'd60: data_o = 32'h01712e23;
                    6'd61: data_o = 32'hfff50b13;
                    6'd62: data_o = 32'h09440913;
                    6'd63: data_o = 32'h00848493;
                    default: data_o = 32'b0;
                endcase
                14'd19  : case (word_addr[5:0])   // words 1216..1279
                    6'd0 : data_o = 32'h19ca8a93;
                    6'd1 : data_o = 32'hfffa0a13;
                    6'd2 : data_o = 32'hfff98993;
                    6'd3 : data_o = 32'h0100006f;
                    6'd4 : data_o = 32'hfffb0b13;
                    6'd5 : data_o = 32'hfff00793;
                    6'd6 : data_o = 32'h1cfb0663;
                    6'd7 : data_o = 32'h0a442783;
                    6'd8 : data_o = 32'h1c078263;
                    6'd9 : data_o = 32'h00090513;
                    6'd10: data_o = 32'hfffff097;
                    6'd11: data_o = 32'h1d8080e7;
                    6'd12: data_o = 32'h0004a783;
                    6'd13: data_o = 32'h0027f793;
                    6'd14: data_o = 32'h02078c63;
                    6'd15: data_o = 32'hf10006b7;
                    6'd16: data_o = 32'h0046a583;
                    6'd17: data_o = 32'h0004a023;
                    6'd18: data_o = 32'h00042783;
                    6'd19: data_o = 32'h00442703;
                    6'd20: data_o = 32'h03f00613;
                    6'd21: data_o = 32'h40e78733;
                    6'd22: data_o = 32'h1ae66c63;
                    6'd23: data_o = 32'h03f7f713;
                    6'd24: data_o = 32'h00ea8733;
                    6'd25: data_o = 32'h00178793;
                    6'd26: data_o = 32'h00f42023;
                    6'd27: data_o = 32'h00b70023;
                    6'd28: data_o = 32'h0a442783;
                    6'd29: data_o = 32'hfff78793;
                    6'd30: data_o = 32'h0af42223;
                    6'd31: data_o = 32'hf8079ae3;
                    6'd32: data_o = 32'h0b842703;
                    6'd33: data_o = 32'h09042783;
                    6'd34: data_o = 32'h09442b83;
                    6'd35: data_o = 32'h0a842683;
                    6'd36: data_o = 32'h40e787b3;
                    6'd37: data_o = 32'h07800713;
                    6'd38: data_o = 32'h00dbcbb3;
                    6'd39: data_o = 32'h18f76a63;
                    6'd40: data_o = 32'h0c040513;
                    6'd41: data_o = 32'h00000097;
                    6'd42: data_o = 32'hdd0080e7;
                    6'd43: data_o = 32'h0004a783;
                    6'd44: data_o = 32'h0027f793;
                    6'd45: data_o = 32'h04078063;
                    6'd46: data_o = 32'hf1000737;
                    6'd47: data_o = 32'h00472583;
                    6'd48: data_o = 32'h0004a023;
                    6'd49: data_o = 32'h00042683;
                    6'd50: data_o = 32'h00442783;
                    6'd51: data_o = 32'h03f00613;
                    6'd52: data_o = 32'h40f687b3;
                    6'd53: data_o = 32'h16f66e63;
                    6'd54: data_o = 32'h100107b7;
                    6'd55: data_o = 32'h03f6f713;
                    6'd56: data_o = 32'h19c78793;
                    6'd57: data_o = 32'h00168693;
                    6'd58: data_o = 32'h00e787b3;
                    6'd59: data_o = 32'h00d42023;
                    6'd60: data_o = 32'h00b78023;
                    6'd61: data_o = 32'h0c144783;
                    6'd62: data_o = 32'h0ffbf693;
                    6'd63: data_o = 32'h008bd713;
                    default: data_o = 32'b0;
                endcase
                14'd20  : case (word_addr[5:0])   // words 1280..1343
                    6'd0 : data_o = 32'h00869693;
                    6'd1 : data_o = 32'h0ff77713;
                    6'd2 : data_o = 32'h01071713;
                    6'd3 : data_o = 32'h00d7e7b3;
                    6'd4 : data_o = 32'h00e7e7b3;
                    6'd5 : data_o = 32'h010bd713;
                    6'd6 : data_o = 32'h01871713;
                    6'd7 : data_o = 32'h0147f7b3;
                    6'd8 : data_o = 32'h00e7e7b3;
                    6'd9 : data_o = 32'h018bdb93;
                    6'd10: data_o = 32'h00f12023;
                    6'd11: data_o = 32'h01710223;
                    6'd12: data_o = 32'h04100793;
                    6'd13: data_o = 32'h81378633;
                    6'd14: data_o = 32'h00f10423;
                    6'd15: data_o = 32'h00010713;
                    6'd16: data_o = 32'h00910793;
                    6'd17: data_o = 32'h00e10593;
                    6'd18: data_o = 32'h00074683;
                    6'd19: data_o = 32'h00d78023;
                    6'd20: data_o = 32'h80c68633;
                    6'd21: data_o = 32'h00178793;
                    6'd22: data_o = 32'h00170713;
                    6'd23: data_o = 32'hfef596e3;
                    6'd24: data_o = 32'h00c11723;
                    6'd25: data_o = 32'h0004a783;
                    6'd26: data_o = 32'h0027f793;
                    6'd27: data_o = 32'h04078063;
                    6'd28: data_o = 32'hf1000737;
                    6'd29: data_o = 32'h00472583;
                    6'd30: data_o = 32'h0004a023;
                    6'd31: data_o = 32'h00042683;
                    6'd32: data_o = 32'h00442783;
                    6'd33: data_o = 32'h03f00613;
                    6'd34: data_o = 32'h40f687b3;
                    6'd35: data_o = 32'h0af66a63;
                    6'd36: data_o = 32'h100107b7;
                    6'd37: data_o = 32'h03f6f713;
                    6'd38: data_o = 32'h19c78793;
                    6'd39: data_o = 32'h00168693;
                    6'd40: data_o = 32'h00e787b3;
                    6'd41: data_o = 32'h00d42023;
                    6'd42: data_o = 32'h00b78023;
                    6'd43: data_o = 32'h09042783;
                    6'd44: data_o = 32'h0b842683;
                    6'd45: data_o = 32'h07800713;
                    6'd46: data_o = 32'h40d787b3;
                    6'd47: data_o = 32'h06f76263;
                    6'd48: data_o = 32'h00810513;
                    6'd49: data_o = 32'h00000097;
                    6'd50: data_o = 32'hcb0080e7;
                    6'd51: data_o = 32'h0c842783;
                    6'd52: data_o = 32'hfffb0b13;
                    6'd53: data_o = 32'h00178793;
                    6'd54: data_o = 32'h0cf42423;
                    6'd55: data_o = 32'hfff00793;
                    6'd56: data_o = 32'he2fb1ee3;
                    6'd57: data_o = 32'h03c12083;
                    6'd58: data_o = 32'h03812403;
                    6'd59: data_o = 32'h03412483;
                    6'd60: data_o = 32'h03012903;
                    6'd61: data_o = 32'h02c12983;
                    6'd62: data_o = 32'h02812a03;
                    6'd63: data_o = 32'h02412a83;
                    default: data_o = 32'b0;
                endcase
                14'd21  : case (word_addr[5:0])   // words 1344..1407
                    6'd0 : data_o = 32'h02012b03;
                    6'd1 : data_o = 32'h01c12b83;
                    6'd2 : data_o = 32'h04010113;
                    6'd3 : data_o = 32'h00008067;
                    6'd4 : data_o = 32'h00842783;
                    6'd5 : data_o = 32'h00178793;
                    6'd6 : data_o = 32'h00f42423;
                    6'd7 : data_o = 32'he55ff06f;
                    6'd8 : data_o = 32'h0bc42783;
                    6'd9 : data_o = 32'h00178793;
                    6'd10: data_o = 32'h0af42e23;
                    6'd11: data_o = 32'hfa1ff06f;
                    6'd12: data_o = 32'h0bc42783;
                    6'd13: data_o = 32'h00178793;
                    6'd14: data_o = 32'h0af42e23;
                    6'd15: data_o = 32'he71ff06f;
                    6'd16: data_o = 32'h00842783;
                    6'd17: data_o = 32'h00178793;
                    6'd18: data_o = 32'h00f42423;
                    6'd19: data_o = 32'hf61ff06f;
                    6'd20: data_o = 32'h00842783;
                    6'd21: data_o = 32'h00178793;
                    6'd22: data_o = 32'h00f42423;
                    6'd23: data_o = 32'he99ff06f;
                    6'd24: data_o = 32'hfb010113;
                    6'd25: data_o = 32'h04812423;
                    6'd26: data_o = 32'h10010437;
                    6'd27: data_o = 32'h02440413;
                    6'd28: data_o = 32'h0cc42703;
                    6'd29: data_o = 32'h004037b7;
                    6'd30: data_o = 32'hb1c78793;
                    6'd31: data_o = 32'h00e787b3;
                    6'd32: data_o = 32'h03412c23;
                    6'd33: data_o = 32'h0007ca03;
                    6'd34: data_o = 32'h08c42783;
                    6'd35: data_o = 32'h03512a23;
                    6'd36: data_o = 32'h03712623;
                    6'd37: data_o = 32'h04112623;
                    6'd38: data_o = 32'h05212023;
                    6'd39: data_o = 32'h03312e23;
                    6'd40: data_o = 32'h03612823;
                    6'd41: data_o = 32'h0c042a23;
                    6'd42: data_o = 32'h0c042c23;
                    6'd43: data_o = 32'h0d042b83;
                    6'd44: data_o = 32'h000a0a93;
                    6'd45: data_o = 32'h3e078863;
                    6'd46: data_o = 32'h04912223;
                    6'd47: data_o = 32'h03812423;
                    6'd48: data_o = 32'h100114b7;
                    6'd49: data_o = 32'hf1000c37;
                    6'd50: data_o = 32'hf1000b37;
                    6'd51: data_o = 32'h100117b7;
                    6'd52: data_o = 32'h10010937;
                    6'd53: data_o = 32'h100109b7;
                    6'd54: data_o = 32'h03912223;
                    6'd55: data_o = 32'h03a12023;
                    6'd56: data_o = 32'h01b12e23;
                    6'd57: data_o = 32'h19c48493;
                    6'd58: data_o = 32'h9dc78d93;
                    6'd59: data_o = 32'h00000d13;
                    6'd60: data_o = 32'hfff00c93;
                    6'd61: data_o = 32'h008c0c13;
                    6'd62: data_o = 32'h004b0b13;
                    6'd63: data_o = 32'h19c90913;
                    default: data_o = 32'b0;
                endcase
                14'd22  : case (word_addr[5:0])   // words 1408..1471
                    6'd0 : data_o = 32'h00098993;
                    6'd1 : data_o = 32'h000c2783;
                    6'd2 : data_o = 32'h0027f793;
                    6'd3 : data_o = 32'h02078a63;
                    6'd4 : data_o = 32'h000b2583;
                    6'd5 : data_o = 32'h000c2023;
                    6'd6 : data_o = 32'h00042603;
                    6'd7 : data_o = 32'h00442783;
                    6'd8 : data_o = 32'h03f00713;
                    6'd9 : data_o = 32'h40f607b3;
                    6'd10: data_o = 32'h28f76863;
                    6'd11: data_o = 32'h03f67793;
                    6'd12: data_o = 32'h00f907b3;
                    6'd13: data_o = 32'h00160613;
                    6'd14: data_o = 32'h00c42023;
                    6'd15: data_o = 32'h00b78023;
                    6'd16: data_o = 32'h000d8513;
                    6'd17: data_o = 32'hfffff097;
                    6'd18: data_o = 32'h548080e7;
                    6'd19: data_o = 32'h02054063;
                    6'd20: data_o = 32'h00251793;
                    6'd21: data_o = 32'h00a787b3;
                    6'd22: data_o = 32'h00279793;
                    6'd23: data_o = 32'h00f907b3;
                    6'd24: data_o = 32'h3507a583;
                    6'd25: data_o = 32'h0009a603;
                    6'd26: data_o = 32'h22c58063;
                    6'd27: data_o = 32'h240cc263;
                    6'd28: data_o = 32'h002c9793;
                    6'd29: data_o = 32'h019787b3;
                    6'd30: data_o = 32'h00279793;
                    6'd31: data_o = 32'h00f487b3;
                    6'd32: data_o = 32'h00cda583;
                    6'd33: data_o = 32'h84c7a603;
                    6'd34: data_o = 32'h22b66463;
                    6'd35: data_o = 32'h2ec58a63;
                    6'd36: data_o = 32'h08c42783;
                    6'd37: data_o = 32'h001d0d13;
                    6'd38: data_o = 32'h014d8d93;
                    6'd39: data_o = 32'hf6fd64e3;
                    6'd40: data_o = 32'h220b8463;
                    6'd41: data_o = 32'h04412483;
                    6'd42: data_o = 32'h02812c03;
                    6'd43: data_o = 32'h02412c83;
                    6'd44: data_o = 32'h02012d03;
                    6'd45: data_o = 32'h01c12d83;
                    6'd46: data_o = 32'h00000b93;
                    6'd47: data_o = 32'h00000a93;
                    6'd48: data_o = 32'h00000b13;
                    6'd49: data_o = 32'h00000913;
                    6'd50: data_o = 32'h00700793;
                    6'd51: data_o = 32'h00600993;
                    6'd52: data_o = 32'h0f042683;
                    6'd53: data_o = 32'hf1000737;
                    6'd54: data_o = 32'h00870713;
                    6'd55: data_o = 32'h00168693;
                    6'd56: data_o = 32'h0ed42823;
                    6'd57: data_o = 32'h00072683;
                    6'd58: data_o = 32'h0026f693;
                    6'd59: data_o = 32'h04068063;
                    6'd60: data_o = 32'hf10006b7;
                    6'd61: data_o = 32'h0046a503;
                    6'd62: data_o = 32'h00072023;
                    6'd63: data_o = 32'h00042603;
                    default: data_o = 32'b0;
                endcase
                14'd23  : case (word_addr[5:0])   // words 1472..1535
                    6'd0 : data_o = 32'h00442703;
                    6'd1 : data_o = 32'h03f00593;
                    6'd2 : data_o = 32'h40e60733;
                    6'd3 : data_o = 32'h28e5e463;
                    6'd4 : data_o = 32'h10010737;
                    6'd5 : data_o = 32'h03f67693;
                    6'd6 : data_o = 32'h19c70713;
                    6'd7 : data_o = 32'h00160613;
                    6'd8 : data_o = 32'h00d70733;
                    6'd9 : data_o = 32'h00c42023;
                    6'd10: data_o = 32'h00a70023;
                    6'd11: data_o = 32'h0f444703;
                    6'd12: data_o = 32'h004a1a13;
                    6'd13: data_o = 32'h0147e7b3;
                    6'd14: data_o = 32'h00899693;
                    6'd15: data_o = 32'h0ff7f793;
                    6'd16: data_o = 32'h00d76733;
                    6'd17: data_o = 32'h01079793;
                    6'd18: data_o = 32'h01891693;
                    6'd19: data_o = 32'h00f767b3;
                    6'd20: data_o = 32'h00d7e7b3;
                    6'd21: data_o = 32'h00c00513;
                    6'd22: data_o = 32'h00f12023;
                    6'd23: data_o = 32'h01610223;
                    6'd24: data_o = 32'h00000097;
                    6'd25: data_o = 32'hb54080e7;
                    6'd26: data_o = 32'h000106b7;
                    6'd27: data_o = 32'h05600793;
                    6'd28: data_o = 32'hfff68693;
                    6'd29: data_o = 32'h80d786b3;
                    6'd30: data_o = 32'h00f10423;
                    6'd31: data_o = 32'h00010713;
                    6'd32: data_o = 32'h00910793;
                    6'd33: data_o = 32'h00e10593;
                    6'd34: data_o = 32'h00074603;
                    6'd35: data_o = 32'h00c78023;
                    6'd36: data_o = 32'h80d606b3;
                    6'd37: data_o = 32'h00178793;
                    6'd38: data_o = 32'h00170713;
                    6'd39: data_o = 32'hfef596e3;
                    6'd40: data_o = 32'h0f842783;
                    6'd41: data_o = 32'h00d11723;
                    6'd42: data_o = 32'h1a078a63;
                    6'd43: data_o = 32'h100107b7;
                    6'd44: data_o = 32'h0007a783;
                    6'd45: data_o = 32'h0a842e83;
                    6'd46: data_o = 32'h00c15f03;
                    6'd47: data_o = 32'h0fc42603;
                    6'd48: data_o = 32'h10042583;
                    6'd49: data_o = 32'h0ac42e03;
                    6'd50: data_o = 32'h01079793;
                    6'd51: data_o = 32'h01d64633;
                    6'd52: data_o = 32'h10442683;
                    6'd53: data_o = 32'h0b042303;
                    6'd54: data_o = 32'h10842703;
                    6'd55: data_o = 32'h0b442883;
                    6'd56: data_o = 32'h01e7e7b3;
                    6'd57: data_o = 32'h03000eb7;
                    6'd58: data_o = 32'h00812503;
                    6'd59: data_o = 32'h01c5c5b3;
                    6'd60: data_o = 32'h0c842803;
                    6'd61: data_o = 32'h01d7e7b3;
                    6'd62: data_o = 32'h00b7c7b3;
                    6'd63: data_o = 32'h00c12583;
                    default: data_o = 32'b0;
                endcase
                14'd24  : case (word_addr[5:0])   // words 1536..1599
                    6'd0 : data_o = 32'h0066c6b3;
                    6'd1 : data_o = 32'h01174733;
                    6'd2 : data_o = 32'h00a64633;
                    6'd3 : data_o = 32'h0106c6b3;
                    6'd4 : data_o = 32'h00174713;
                    6'd5 : data_o = 32'h08f42c23;
                    6'd6 : data_o = 32'h00c00793;
                    6'd7 : data_o = 32'h0ca42023;
                    6'd8 : data_o = 32'h0cb42223;
                    6'd9 : data_o = 32'h08c42a23;
                    6'd10: data_o = 32'h08d42e23;
                    6'd11: data_o = 32'h0ae42023;
                    6'd12: data_o = 32'h0af42223;
                    6'd13: data_o = 32'h0f442703;
                    6'd14: data_o = 32'h10c42783;
                    6'd15: data_o = 32'h017aeab3;
                    6'd16: data_o = 32'h00170713;
                    6'd17: data_o = 32'h0807f793;
                    6'd18: data_o = 32'h0157e7b3;
                    6'd19: data_o = 32'h0ff77713;
                    6'd20: data_o = 32'h0ee42a23;
                    6'd21: data_o = 32'h10f42623;
                    6'd22: data_o = 32'h04c12083;
                    6'd23: data_o = 32'h04812403;
                    6'd24: data_o = 32'hf0000737;
                    6'd25: data_o = 32'h00f72023;
                    6'd26: data_o = 32'h04012903;
                    6'd27: data_o = 32'h03c12983;
                    6'd28: data_o = 32'h03812a03;
                    6'd29: data_o = 32'h03412a83;
                    6'd30: data_o = 32'h03012b03;
                    6'd31: data_o = 32'h02c12b83;
                    6'd32: data_o = 32'h05010113;
                    6'd33: data_o = 32'h00008067;
                    6'd34: data_o = 32'h0dc42603;
                    6'd35: data_o = 32'h34c7a583;
                    6'd36: data_o = 32'h0049a503;
                    6'd37: data_o = 32'h40b605b3;
                    6'd38: data_o = 32'h00b637b3;
                    6'd39: data_o = 32'h40f00633;
                    6'd40: data_o = 32'hde0798e3;
                    6'd41: data_o = 32'hdc0614e3;
                    6'd42: data_o = 32'hdea5e4e3;
                    6'd43: data_o = 32'hdc0cd2e3;
                    6'd44: data_o = 32'h000d0c93;
                    6'd45: data_o = 32'hdddff06f;
                    6'd46: data_o = 32'h00842783;
                    6'd47: data_o = 32'h00178793;
                    6'd48: data_o = 32'h00f42423;
                    6'd49: data_o = 32'hd7dff06f;
                    6'd50: data_o = 32'h1e0cc263;
                    6'd51: data_o = 32'h002c9913;
                    6'd52: data_o = 32'h01990933;
                    6'd53: data_o = 32'h100117b7;
                    6'd54: data_o = 32'h00291913;
                    6'd55: data_o = 32'h9dc78793;
                    6'd56: data_o = 32'h01278cb3;
                    6'd57: data_o = 32'h000c8513;
                    6'd58: data_o = 32'hfffff097;
                    6'd59: data_o = 32'h2a4080e7;
                    6'd60: data_o = 32'h012484b3;
                    6'd61: data_o = 32'h8404a783;
                    6'd62: data_o = 32'h00050713;
                    6'd63: data_o = 32'h000c8513;
                    default: data_o = 32'b0;
                endcase
                14'd25  : case (word_addr[5:0])   // words 1600..1663
                    6'd0 : data_o = 32'h0077f493;
                    6'd1 : data_o = 32'h00070913;
                    6'd2 : data_o = 32'hfffff097;
                    6'd3 : data_o = 32'h090080e7;
                    6'd4 : data_o = 32'h100107b7;
                    6'd5 : data_o = 32'h00078793;
                    6'd6 : data_o = 32'h0007a583;
                    6'd7 : data_o = 32'h0dc42603;
                    6'd8 : data_o = 32'h0a054e63;
                    6'd9 : data_o = 32'h06000a93;
                    6'd10: data_o = 32'h00000b13;
                    6'd11: data_o = 32'h00000913;
                    6'd12: data_o = 32'h00300993;
                    6'd13: data_o = 32'h000c8513;
                    6'd14: data_o = 32'hfffff097;
                    6'd15: data_o = 32'h440080e7;
                    6'd16: data_o = 32'h0ff4f793;
                    6'd17: data_o = 32'h02812c03;
                    6'd18: data_o = 32'h04412483;
                    6'd19: data_o = 32'h02412c83;
                    6'd20: data_o = 32'h02012d03;
                    6'd21: data_o = 32'h01c12d83;
                    6'd22: data_o = 32'hd79ff06f;
                    6'd23: data_o = 32'h09042783;
                    6'd24: data_o = 32'h0b842683;
                    6'd25: data_o = 32'h07800713;
                    6'd26: data_o = 32'h40d787b3;
                    6'd27: data_o = 32'h16f76063;
                    6'd28: data_o = 32'h00810513;
                    6'd29: data_o = 32'h00000097;
                    6'd30: data_o = 32'h800080e7;
                    6'd31: data_o = 32'heb9ff06f;
                    6'd32: data_o = 32'h010da603;
                    6'd33: data_o = 32'h8507a783;
                    6'd34: data_o = 32'hd0c7f4e3;
                    6'd35: data_o = 32'h000d0c93;
                    6'd36: data_o = 32'hd01ff06f;
                    6'd37: data_o = 32'h00842703;
                    6'd38: data_o = 32'h00170713;
                    6'd39: data_o = 32'h00e42423;
                    6'd40: data_o = 32'hd8dff06f;
                    6'd41: data_o = 32'hd00b9ae3;
                    6'd42: data_o = 32'h00000b93;
                    6'd43: data_o = 32'h000a1c63;
                    6'd44: data_o = 32'h00000b13;
                    6'd45: data_o = 32'h00000913;
                    6'd46: data_o = 32'h00700793;
                    6'd47: data_o = 32'h00500993;
                    6'd48: data_o = 32'hd11ff06f;
                    6'd49: data_o = 32'h02000a93;
                    6'd50: data_o = 32'h00000b13;
                    6'd51: data_o = 32'h00000913;
                    6'd52: data_o = 32'h00700793;
                    6'd53: data_o = 32'h00100993;
                    6'd54: data_o = 32'hcf9ff06f;
                    6'd55: data_o = 32'h08094c63;
                    6'd56: data_o = 32'h00291693;
                    6'd57: data_o = 32'h012686b3;
                    6'd58: data_o = 32'h10010737;
                    6'd59: data_o = 32'h00269693;
                    6'd60: data_o = 32'h19c70713;
                    6'd61: data_o = 32'h00d70733;
                    6'd62: data_o = 32'h35072683;
                    6'd63: data_o = 32'h06b68c63;
                    default: data_o = 32'b0;
                endcase
                14'd26  : case (word_addr[5:0])   // words 1664..1727
                    6'd0 : data_o = 32'h34c72503;
                    6'd1 : data_o = 32'h00169693;
                    6'd2 : data_o = 32'h00159713;
                    6'd3 : data_o = 32'h00e40733;
                    6'd4 : data_o = 32'h00d406b3;
                    6'd5 : data_o = 32'h40a60533;
                    6'd6 : data_o = 32'h0e075703;
                    6'd7 : data_o = 32'h0e06d683;
                    6'd8 : data_o = 32'h04a05863;
                    6'd9 : data_o = 32'h40d70733;
                    6'd10: data_o = 32'h41f75893;
                    6'd11: data_o = 32'h0087a803;
                    6'd12: data_o = 32'h00e8c733;
                    6'd13: data_o = 32'h000586b7;
                    6'd14: data_o = 32'h41170733;
                    6'd15: data_o = 32'he4068693;
                    6'd16: data_o = 32'h02d71333;
                    6'd17: data_o = 32'h030538b3;
                    6'd18: data_o = 32'h02d70733;
                    6'd19: data_o = 32'h03050533;
                    6'd20: data_o = 32'h0068e663;
                    6'd21: data_o = 32'h03131063;
                    6'd22: data_o = 32'h00e57e63;
                    6'd23: data_o = 32'h06000a93;
                    6'd24: data_o = 32'h00000b13;
                    6'd25: data_o = 32'h00000913;
                    6'd26: data_o = 32'h00400993;
                    6'd27: data_o = 32'hec9ff06f;
                    6'd28: data_o = 32'hfed716e3;
                    6'd29: data_o = 32'h00400713;
                    6'd30: data_o = 32'h08e48a63;
                    6'd31: data_o = 32'h00500713;
                    6'd32: data_o = 32'h04e48e63;
                    6'd33: data_o = 32'h069a0263;
                    6'd34: data_o = 32'h001a1713;
                    6'd35: data_o = 32'h00e787b3;
                    6'd36: data_o = 32'h00c7db03;
                    6'd37: data_o = 32'h02000a93;
                    6'd38: data_o = 32'h01000b93;
                    6'd39: data_o = 32'h0ffb7913;
                    6'd40: data_o = 32'h00200993;
                    6'd41: data_o = 32'h008b5b13;
                    6'd42: data_o = 32'he8dff06f;
                    6'd43: data_o = 32'h04412483;
                    6'd44: data_o = 32'h02812c03;
                    6'd45: data_o = 32'h02412c83;
                    6'd46: data_o = 32'h02012d03;
                    6'd47: data_o = 32'h01c12d83;
                    6'd48: data_o = 32'h00000b93;
                    6'd49: data_o = 32'hf00a10e3;
                    6'd50: data_o = 32'hee9ff06f;
                    6'd51: data_o = 32'h0bc42783;
                    6'd52: data_o = 32'h00178793;
                    6'd53: data_o = 32'h0af42e23;
                    6'd54: data_o = 32'hd5dff06f;
                    6'd55: data_o = 32'hffea0713;
                    6'd56: data_o = 32'h00100693;
                    6'd57: data_o = 32'hfae6e2e3;
                    6'd58: data_o = 32'h00149713;
                    6'd59: data_o = 32'h00e787b3;
                    6'd60: data_o = 32'h00c7db03;
                    6'd61: data_o = 32'h00000a93;
                    6'd62: data_o = 32'h01000b93;
                    6'd63: data_o = 32'h0ffb7913;
                    default: data_o = 32'b0;
                endcase
                14'd27  : case (word_addr[5:0])   // words 1728..1791
                    6'd0 : data_o = 32'h00000993;
                    6'd1 : data_o = 32'h008b5b13;
                    6'd2 : data_o = 32'he2dff06f;
                    6'd3 : data_o = 32'h00100713;
                    6'd4 : data_o = 32'hf6ea1ce3;
                    6'd5 : data_o = 32'hfd5ff06f;
                    6'd6 : data_o = 32'hfe010113;
                    6'd7 : data_o = 32'h00812c23;
                    6'd8 : data_o = 32'h10010437;
                    6'd9 : data_o = 32'h02440413;
                    6'd10: data_o = 32'h11042703;
                    6'd11: data_o = 32'h0ff5f593;
                    6'd12: data_o = 32'h00859593;
                    6'd13: data_o = 32'h0ff57513;
                    6'd14: data_o = 32'h00b567b3;
                    6'd15: data_o = 32'h00c00513;
                    6'd16: data_o = 32'h00f11023;
                    6'd17: data_o = 32'h00112e23;
                    6'd18: data_o = 32'h00e10123;
                    6'd19: data_o = 32'h000101a3;
                    6'd20: data_o = 32'h00010223;
                    6'd21: data_o = 32'hfffff097;
                    6'd22: data_o = 32'h760080e7;
                    6'd23: data_o = 32'h000106b7;
                    6'd24: data_o = 32'h04500793;
                    6'd25: data_o = 32'hfff68693;
                    6'd26: data_o = 32'h80d786b3;
                    6'd27: data_o = 32'h00f10423;
                    6'd28: data_o = 32'h00010713;
                    6'd29: data_o = 32'h00910793;
                    6'd30: data_o = 32'h00e10593;
                    6'd31: data_o = 32'h00074603;
                    6'd32: data_o = 32'h00c78023;
                    6'd33: data_o = 32'h80d606b3;
                    6'd34: data_o = 32'h00178793;
                    6'd35: data_o = 32'h00170713;
                    6'd36: data_o = 32'hfeb796e3;
                    6'd37: data_o = 32'h09042783;
                    6'd38: data_o = 32'h0b842603;
                    6'd39: data_o = 32'h00d11723;
                    6'd40: data_o = 32'h07800713;
                    6'd41: data_o = 32'h40c787b3;
                    6'd42: data_o = 32'h02f76463;
                    6'd43: data_o = 32'h00810513;
                    6'd44: data_o = 32'hfffff097;
                    6'd45: data_o = 32'h5c4080e7;
                    6'd46: data_o = 32'h01c12083;
                    6'd47: data_o = 32'h01812403;
                    6'd48: data_o = 32'h100107b7;
                    6'd49: data_o = 32'h0007ac23;
                    6'd50: data_o = 32'h02010113;
                    6'd51: data_o = 32'h00008067;
                    6'd52: data_o = 32'h0bc42783;
                    6'd53: data_o = 32'h01c12083;
                    6'd54: data_o = 32'h00178793;
                    6'd55: data_o = 32'h0af42e23;
                    6'd56: data_o = 32'h01812403;
                    6'd57: data_o = 32'h100107b7;
                    6'd58: data_o = 32'h0007ac23;
                    6'd59: data_o = 32'h02010113;
                    6'd60: data_o = 32'h00008067;
                    6'd61: data_o = 32'hf6010113;
                    6'd62: data_o = 32'h08812c23;
                    6'd63: data_o = 32'hf00007b7;
                    default: data_o = 32'b0;
                endcase
                14'd28  : case (word_addr[5:0])   // words 1792..1855
                    6'd0 : data_o = 32'h08112e23;
                    6'd1 : data_o = 32'h08912a23;
                    6'd2 : data_o = 32'h09212823;
                    6'd3 : data_o = 32'h09312623;
                    6'd4 : data_o = 32'h09412423;
                    6'd5 : data_o = 32'h09512223;
                    6'd6 : data_o = 32'h09612023;
                    6'd7 : data_o = 32'h07712e23;
                    6'd8 : data_o = 32'h07812c23;
                    6'd9 : data_o = 32'h07912a23;
                    6'd10: data_o = 32'h07a12823;
                    6'd11: data_o = 32'h07b12623;
                    6'd12: data_o = 32'h0f000693;
                    6'd13: data_o = 32'hf0000737;
                    6'd14: data_o = 32'h00d7a423;
                    6'd15: data_o = 32'h00472783;
                    6'd16: data_o = 32'h10010437;
                    6'd17: data_o = 32'h0017f713;
                    6'd18: data_o = 32'h6e071463;
                    6'd19: data_o = 32'h02440413;
                    6'd20: data_o = 32'h11842603;
                    6'd21: data_o = 32'h10c42683;
                    6'd22: data_o = 32'h00e7f713;
                    6'd23: data_o = 32'h00375793;
                    6'd24: data_o = 32'h00c7e7b3;
                    6'd25: data_o = 32'h00403837;
                    6'd26: data_o = 32'h0706f693;
                    6'd27: data_o = 32'hb5880c93;
                    6'd28: data_o = 32'h00779793;
                    6'd29: data_o = 32'hffc00d37;
                    6'd30: data_o = 32'h00d7e7b3;
                    6'd31: data_o = 32'h01ac8d33;
                    6'd32: data_o = 32'h402d5d13;
                    6'd33: data_o = 32'h10e42a23;
                    6'd34: data_o = 32'h10f42623;
                    6'd35: data_o = 32'hf0000737;
                    6'd36: data_o = 32'h00f72023;
                    6'd37: data_o = 32'h008d5693;
                    6'd38: data_o = 32'h0ffd7793;
                    6'd39: data_o = 32'h02f12023;
                    6'd40: data_o = 32'h0ff6f793;
                    6'd41: data_o = 32'h02f12223;
                    6'd42: data_o = 32'h100107b7;
                    6'd43: data_o = 32'h00078d13;
                    6'd44: data_o = 32'h004037b7;
                    6'd45: data_o = 32'ha8478793;
                    6'd46: data_o = 32'h02f12423;
                    6'd47: data_o = 32'h100107b7;
                    6'd48: data_o = 32'h15078793;
                    6'd49: data_o = 32'h02f12c23;
                    6'd50: data_o = 32'h100107b7;
                    6'd51: data_o = 32'h12078793;
                    6'd52: data_o = 32'h02f12a23;
                    6'd53: data_o = 32'h100107b7;
                    6'd54: data_o = 32'h0cc78793;
                    6'd55: data_o = 32'h02f12823;
                    6'd56: data_o = 32'h100107b7;
                    6'd57: data_o = 32'h15878793;
                    6'd58: data_o = 32'h10011b37;
                    6'd59: data_o = 32'h02f12e23;
                    6'd60: data_o = 32'h10011c37;
                    6'd61: data_o = 32'h19cb0793;
                    6'd62: data_o = 32'h00f12223;
                    6'd63: data_o = 32'haacc0793;
                    default: data_o = 32'b0;
                endcase
                14'd29  : case (word_addr[5:0])   // words 1856..1919
                    6'd0 : data_o = 32'h00f12c23;
                    6'd1 : data_o = 32'h100107b7;
                    6'd2 : data_o = 32'h00c78793;
                    6'd3 : data_o = 32'h00010637;
                    6'd4 : data_o = 32'h02f12623;
                    6'd5 : data_o = 32'hffe60793;
                    6'd6 : data_o = 32'h00f12023;
                    6'd7 : data_o = 32'h000107b7;
                    6'd8 : data_o = 32'hf1000db7;
                    6'd9 : data_o = 32'hf10004b7;
                    6'd10: data_o = 32'hf0000a37;
                    6'd11: data_o = 32'h100109b7;
                    6'd12: data_o = 32'hfff78793;
                    6'd13: data_o = 32'h19c98993;
                    6'd14: data_o = 32'h008d8d93;
                    6'd15: data_o = 32'h00448493;
                    6'd16: data_o = 32'h03f00913;
                    6'd17: data_o = 32'h00f12e23;
                    6'd18: data_o = 32'h004a0a13;
                    6'd19: data_o = 32'h000da783;
                    6'd20: data_o = 32'h0027f793;
                    6'd21: data_o = 32'h16079e63;
                    6'd22: data_o = 32'h00442c03;
                    6'd23: data_o = 32'h00042b83;
                    6'd24: data_o = 32'h11c42783;
                    6'd25: data_o = 32'h1b7c0063;
                    6'd26: data_o = 32'h001c0693;
                    6'd27: data_o = 32'h03fc7713;
                    6'd28: data_o = 32'h00e98733;
                    6'd29: data_o = 32'h00d42223;
                    6'd30: data_o = 32'h12042023;
                    6'd31: data_o = 32'h00074703;
                    6'd32: data_o = 32'h40078663;
                    6'd33: data_o = 32'h12442683;
                    6'd34: data_o = 32'h00100613;
                    6'd35: data_o = 32'h00168513;
                    6'd36: data_o = 32'h00d405b3;
                    6'd37: data_o = 32'h12a42223;
                    6'd38: data_o = 32'h12e58623;
                    6'd39: data_o = 32'h48c78663;
                    6'd40: data_o = 32'h00200613;
                    6'd41: data_o = 32'h48c78e63;
                    6'd42: data_o = 32'h15042a83;
                    6'd43: data_o = 32'h00300593;
                    6'd44: data_o = 32'hfffa8a93;
                    6'd45: data_o = 32'h4ab78c63;
                    6'd46: data_o = 32'h15542823;
                    6'd47: data_o = 32'h040a9463;
                    6'd48: data_o = 32'hfff68693;
                    6'd49: data_o = 32'h00d406b3;
                    6'd50: data_o = 32'h12d6c783;
                    6'd51: data_o = 32'h12c6c683;
                    6'd52: data_o = 32'h12842703;
                    6'd53: data_o = 32'h00879793;
                    6'd54: data_o = 32'h10042e23;
                    6'd55: data_o = 32'h00d7e7b3;
                    6'd56: data_o = 32'h12c44583;
                    6'd57: data_o = 32'h4ee78c63;
                    6'd58: data_o = 32'h11042783;
                    6'd59: data_o = 32'h0fe00713;
                    6'd60: data_o = 32'h00f76663;
                    6'd61: data_o = 32'h00178793;
                    6'd62: data_o = 32'h10f42823;
                    6'd63: data_o = 32'h018d2783;
                    default: data_o = 32'b0;
                endcase
                14'd30  : case (word_addr[5:0])   // words 1920..1983
                    6'd0 : data_o = 32'h52079063;
                    6'd1 : data_o = 32'h000a2783;
                    6'd2 : data_o = 32'h11442b03;
                    6'd3 : data_o = 32'h00f7fa93;
                    6'd4 : data_o = 32'h055b0663;
                    6'd5 : data_o = 32'h11542a23;
                    6'd6 : data_o = 32'h0017f793;
                    6'd7 : data_o = 32'h001b7b13;
                    6'd8 : data_o = 32'h16078663;
                    6'd9 : data_o = 32'h001ad793;
                    6'd10: data_o = 32'h0037f793;
                    6'd11: data_o = 32'h0cf42623;
                    6'd12: data_o = 32'h360b0e63;
                    6'd13: data_o = 32'h11842783;
                    6'd14: data_o = 32'h003ada93;
                    6'd15: data_o = 32'h00faeab3;
                    6'd16: data_o = 32'h10c42783;
                    6'd17: data_o = 32'h007a9a93;
                    6'd18: data_o = 32'hf0000737;
                    6'd19: data_o = 32'h0707f793;
                    6'd20: data_o = 32'h0157e7b3;
                    6'd21: data_o = 32'h10f42623;
                    6'd22: data_o = 32'h00f72023;
                    6'd23: data_o = 32'h0d842783;
                    6'd24: data_o = 32'h00078863;
                    6'd25: data_o = 32'h317c0263;
                    6'd26: data_o = 32'h020d2783;
                    6'd27: data_o = 32'h16f42a23;
                    6'd28: data_o = 32'h0a442783;
                    6'd29: data_o = 32'h0e079c63;
                    6'd30: data_o = 32'h15c42783;
                    6'd31: data_o = 32'h00078463;
                    6'd32: data_o = 32'h157c0e63;
                    6'd33: data_o = 32'h0b842a83;
                    6'd34: data_o = 32'h09042783;
                    6'd35: data_o = 32'hecfa80e3;
                    6'd36: data_o = 32'h000da783;
                    6'd37: data_o = 32'h0047f793;
                    6'd38: data_o = 32'hea078ae3;
                    6'd39: data_o = 32'h00412703;
                    6'd40: data_o = 32'h07faf793;
                    6'd41: data_o = 32'h001a8a93;
                    6'd42: data_o = 32'h00f707b3;
                    6'd43: data_o = 32'h8907c703;
                    6'd44: data_o = 32'h0b542c23;
                    6'd45: data_o = 32'hf10007b7;
                    6'd46: data_o = 32'h00e7a023;
                    6'd47: data_o = 32'h00300793;
                    6'd48: data_o = 32'h00fda023;
                    6'd49: data_o = 32'h000da783;
                    6'd50: data_o = 32'h0027f793;
                    6'd51: data_o = 32'he80786e3;
                    6'd52: data_o = 32'h0004a703;
                    6'd53: data_o = 32'h000da023;
                    6'd54: data_o = 32'h00042b83;
                    6'd55: data_o = 32'h00442c03;
                    6'd56: data_o = 32'h418b87b3;
                    6'd57: data_o = 32'h08f96c63;
                    6'd58: data_o = 32'h03fbf793;
                    6'd59: data_o = 32'h00f987b3;
                    6'd60: data_o = 32'h001b8b93;
                    6'd61: data_o = 32'h00e78023;
                    6'd62: data_o = 32'h01742023;
                    6'd63: data_o = 32'h11c42783;
                    default: data_o = 32'b0;
                endcase
                14'd31  : case (word_addr[5:0])   // words 1984..2047
                    6'd0 : data_o = 32'he77c14e3;
                    6'd1 : data_o = 32'h12042783;
                    6'd2 : data_o = 32'h00012703;
                    6'd3 : data_o = 32'h00f76663;
                    6'd4 : data_o = 32'h00178793;
                    6'd5 : data_o = 32'h12f42023;
                    6'd6 : data_o = 32'h11c42783;
                    6'd7 : data_o = 32'hee0784e3;
                    6'd8 : data_o = 32'h16c42783;
                    6'd9 : data_o = 32'hee0780e3;
                    6'd10: data_o = 32'h12042703;
                    6'd11: data_o = 32'hece79ce3;
                    6'd12: data_o = 32'h12442583;
                    6'd13: data_o = 32'h10042e23;
                    6'd14: data_o = 32'h00058463;
                    6'd15: data_o = 32'h12c44583;
                    6'd16: data_o = 32'h11042783;
                    6'd17: data_o = 32'h0fe00713;
                    6'd18: data_o = 32'h00f76663;
                    6'd19: data_o = 32'h00178793;
                    6'd20: data_o = 32'h10f42823;
                    6'd21: data_o = 32'h018d2783;
                    6'd22: data_o = 32'hea0786e3;
                    6'd23: data_o = 32'h00500513;
                    6'd24: data_o = 32'h00000097;
                    6'd25: data_o = 32'hbb8080e7;
                    6'd26: data_o = 32'he9dff06f;
                    6'd27: data_o = 32'h00400513;
                    6'd28: data_o = 32'hfffff097;
                    6'd29: data_o = 32'h344080e7;
                    6'd30: data_o = 32'hf01ff06f;
                    6'd31: data_o = 32'h00842783;
                    6'd32: data_o = 32'h00178793;
                    6'd33: data_o = 32'h00f42423;
                    6'd34: data_o = 32'hdd9ff06f;
                    6'd35: data_o = 32'h11842783;
                    6'd36: data_o = 32'h003ada93;
                    6'd37: data_o = 32'h040b0063;
                    6'd38: data_o = 32'h020d2703;
                    6'd39: data_o = 32'h00faeab3;
                    6'd40: data_o = 32'h00100793;
                    6'd41: data_o = 32'h0cf42c23;
                    6'd42: data_o = 32'h16e42a23;
                    6'd43: data_o = 32'h0d542823;
                    6'd44: data_o = 32'he91ff06f;
                    6'd45: data_o = 32'h00812a83;
                    6'd46: data_o = 32'h00c12a03;
                    6'd47: data_o = 32'h01012403;
                    6'd48: data_o = 32'h01412483;
                    6'd49: data_o = 32'h11842783;
                    6'd50: data_o = 32'h003ada93;
                    6'd51: data_o = 32'h001afa93;
                    6'd52: data_o = 32'h16042823;
                    6'd53: data_o = 32'h00faeab3;
                    6'd54: data_o = 32'he69ff06f;
                    6'd55: data_o = 32'h15442783;
                    6'd56: data_o = 32'h01c00693;
                    6'd57: data_o = 32'h15842703;
                    6'd58: data_o = 32'h40fc8633;
                    6'd59: data_o = 32'h32c6d463;
                    6'd60: data_o = 32'h00000613;
                    6'd61: data_o = 32'h04000593;
                    6'd62: data_o = 32'h01c00513;
                    6'd63: data_o = 32'h0007a683;
                    default: data_o = 32'b0;
                endcase
                14'd32  : case (word_addr[5:0])   // words 2048..2111
                    6'd0 : data_o = 32'h80e6a6b3;
                    6'd1 : data_o = 32'h0047a703;
                    6'd2 : data_o = 32'h80d72733;
                    6'd3 : data_o = 32'h0087a683;
                    6'd4 : data_o = 32'h80e6a6b3;
                    6'd5 : data_o = 32'h00c7a703;
                    6'd6 : data_o = 32'h80d72733;
                    6'd7 : data_o = 32'h0107a683;
                    6'd8 : data_o = 32'h80e6a6b3;
                    6'd9 : data_o = 32'h0147a703;
                    6'd10: data_o = 32'h80d72733;
                    6'd11: data_o = 32'h0187a683;
                    6'd12: data_o = 32'h80e6a6b3;
                    6'd13: data_o = 32'h01c7a703;
                    6'd14: data_o = 32'h80d72733;
                    6'd15: data_o = 32'h000da683;
                    6'd16: data_o = 32'h02078793;
                    6'd17: data_o = 32'h00860613;
                    6'd18: data_o = 32'h0026f693;
                    6'd19: data_o = 32'h02068863;
                    6'd20: data_o = 32'h0004a883;
                    6'd21: data_o = 32'h000da023;
                    6'd22: data_o = 32'h00042683;
                    6'd23: data_o = 32'h00442803;
                    6'd24: data_o = 32'h41068833;
                    6'd25: data_o = 32'h0f096a63;
                    6'd26: data_o = 32'h03f6f813;
                    6'd27: data_o = 32'h01098833;
                    6'd28: data_o = 32'h00168693;
                    6'd29: data_o = 32'h00d42023;
                    6'd30: data_o = 32'h01180023;
                    6'd31: data_o = 32'h02b60e63;
                    6'd32: data_o = 32'h40fc86b3;
                    6'd33: data_o = 32'hf6d54ce3;
                    6'd34: data_o = 32'h00078693;
                    6'd35: data_o = 32'h21978863;
                    6'd36: data_o = 32'h40c00633;
                    6'd37: data_o = 32'h00261613;
                    6'd38: data_o = 32'h10060613;
                    6'd39: data_o = 32'h00c787b3;
                    6'd40: data_o = 32'h0080006f;
                    6'd41: data_o = 32'h1f968c63;
                    6'd42: data_o = 32'h0006a603;
                    6'd43: data_o = 32'h00468693;
                    6'd44: data_o = 32'h80e62733;
                    6'd45: data_o = 32'hfed798e3;
                    6'd46: data_o = 32'h14f42a23;
                    6'd47: data_o = 32'h14e42c23;
                    6'd48: data_o = 32'hdd9792e3;
                    6'd49: data_o = 32'h00300693;
                    6'd50: data_o = 32'h04d10423;
                    6'd51: data_o = 32'h02012683;
                    6'd52: data_o = 32'h00875793;
                    6'd53: data_o = 32'h00c00513;
                    6'd54: data_o = 32'h04d104a3;
                    6'd55: data_o = 32'h02412683;
                    6'd56: data_o = 32'h04e105a3;
                    6'd57: data_o = 32'h04f10623;
                    6'd58: data_o = 32'h04d10523;
                    6'd59: data_o = 32'h14042e23;
                    6'd60: data_o = 32'hfffff097;
                    6'd61: data_o = 32'h1c4080e7;
                    6'd62: data_o = 32'h04900793;
                    6'd63: data_o = 32'h01c12703;
                    default: data_o = 32'b0;
                endcase
                14'd33  : case (word_addr[5:0])   // words 2112..2175
                    6'd0 : data_o = 32'h80e78633;
                    6'd1 : data_o = 32'h04f10823;
                    6'd2 : data_o = 32'h04810713;
                    6'd3 : data_o = 32'h05110793;
                    6'd4 : data_o = 32'h00074683;
                    6'd5 : data_o = 32'h00d78023;
                    6'd6 : data_o = 32'h80c68633;
                    6'd7 : data_o = 32'h00178793;
                    6'd8 : data_o = 32'h05610693;
                    6'd9 : data_o = 32'h00170713;
                    6'd10: data_o = 32'hfef694e3;
                    6'd11: data_o = 32'h09042783;
                    6'd12: data_o = 32'h0b842a83;
                    6'd13: data_o = 32'h04c11b23;
                    6'd14: data_o = 32'h07800713;
                    6'd15: data_o = 32'h415786b3;
                    6'd16: data_o = 32'h1cd76263;
                    6'd17: data_o = 32'h05010513;
                    6'd18: data_o = 32'hfffff097;
                    6'd19: data_o = 32'h02c080e7;
                    6'd20: data_o = 32'h09042783;
                    6'd21: data_o = 32'hd39ff06f;
                    6'd22: data_o = 32'h00842683;
                    6'd23: data_o = 32'h00168693;
                    6'd24: data_o = 32'h00d42423;
                    6'd25: data_o = 32'hf19ff06f;
                    6'd26: data_o = 32'h11c42783;
                    6'd27: data_o = 32'hce079ee3;
                    6'd28: data_o = 32'h17442783;
                    6'd29: data_o = 32'hfff78793;
                    6'd30: data_o = 32'h16f42a23;
                    6'd31: data_o = 32'hce079ae3;
                    6'd32: data_o = 32'hfffff097;
                    6'd33: data_o = 32'h3e0080e7;
                    6'd34: data_o = 32'hce9ff06f;
                    6'd35: data_o = 32'h0a500793;
                    6'd36: data_o = 32'hc6f71ae3;
                    6'd37: data_o = 32'h00100793;
                    6'd38: data_o = 32'h10f42e23;
                    6'd39: data_o = 32'h01c12783;
                    6'd40: data_o = 32'h12042223;
                    6'd41: data_o = 32'h12f42423;
                    6'd42: data_o = 32'hc5dff06f;
                    6'd43: data_o = 32'h0d842783;
                    6'd44: data_o = 32'h0c079e63;
                    6'd45: data_o = 32'h17042703;
                    6'd46: data_o = 32'h00100793;
                    6'd47: data_o = 32'h0cf42a23;
                    6'd48: data_o = 32'h08042623;
                    6'd49: data_o = 32'he00700e3;
                    6'd50: data_o = 32'h0dc42603;
                    6'd51: data_o = 32'h01cd2683;
                    6'd52: data_o = 32'h01812503;
                    6'd53: data_o = 32'h01512423;
                    6'd54: data_o = 32'h01412623;
                    6'd55: data_o = 32'h00812823;
                    6'd56: data_o = 32'h00912a23;
                    6'd57: data_o = 32'h000b0413;
                    6'd58: data_o = 32'h00068a93;
                    6'd59: data_o = 32'h00060a13;
                    6'd60: data_o = 32'h00050b13;
                    6'd61: data_o = 32'h00070493;
                    6'd62: data_o = 32'h0100006f;
                    6'd63: data_o = 32'h00140413;
                    default: data_o = 32'b0;
                endcase
                14'd34  : case (word_addr[5:0])   // words 2176..2239
                    6'd0 : data_o = 32'h014b0b13;
                    6'd1 : data_o = 32'hda9408e3;
                    6'd2 : data_o = 32'h00cb2783;
                    6'd3 : data_o = 32'h40fa07b3;
                    6'd4 : data_o = 32'hfefae6e3;
                    6'd5 : data_o = 32'h010b4583;
                    6'd6 : data_o = 32'h000b0513;
                    6'd7 : data_o = 32'hfffff097;
                    6'd8 : data_o = 32'hdd0080e7;
                    6'd9 : data_o = 32'hfd9ff06f;
                    6'd10: data_o = 32'h12842783;
                    6'd11: data_o = 32'h80f70733;
                    6'd12: data_o = 32'h00200793;
                    6'd13: data_o = 32'h12e42423;
                    6'd14: data_o = 32'h10f42e23;
                    6'd15: data_o = 32'hbc9ff06f;
                    6'd16: data_o = 32'h02000793;
                    6'd17: data_o = 32'h06e7e263;
                    6'd18: data_o = 32'h12842683;
                    6'd19: data_o = 32'h80d706b3;
                    6'd20: data_o = 32'h00173793;
                    6'd21: data_o = 32'h00378793;
                    6'd22: data_o = 32'h00270713;
                    6'd23: data_o = 32'h12d42423;
                    6'd24: data_o = 32'h14e42823;
                    6'd25: data_o = 32'h10f42e23;
                    6'd26: data_o = 32'hb9dff06f;
                    6'd27: data_o = 32'h12842783;
                    6'd28: data_o = 32'h80f70733;
                    6'd29: data_o = 32'h12e42423;
                    6'd30: data_o = 32'h15542823;
                    6'd31: data_o = 32'hb8ca94e3;
                    6'd32: data_o = 32'h00400793;
                    6'd33: data_o = 32'h10f42e23;
                    6'd34: data_o = 32'hb7dff06f;
                    6'd35: data_o = 32'hfffff097;
                    6'd36: data_o = 32'h2d4080e7;
                    6'd37: data_o = 32'h11442a83;
                    6'd38: data_o = 32'hf1dff06f;
                    6'd39: data_o = 32'h15942a23;
                    6'd40: data_o = 32'h14e42c23;
                    6'd41: data_o = 32'he21ff06f;
                    6'd42: data_o = 32'h11042783;
                    6'd43: data_o = 32'h10042e23;
                    6'd44: data_o = 32'h0fe00713;
                    6'd45: data_o = 32'h12c44583;
                    6'd46: data_o = 32'h00f76663;
                    6'd47: data_o = 32'h00178793;
                    6'd48: data_o = 32'h10f42823;
                    6'd49: data_o = 32'h018d2783;
                    6'd50: data_o = 32'hb2078ee3;
                    6'd51: data_o = 32'h00200513;
                    6'd52: data_o = 32'h00000097;
                    6'd53: data_o = 32'h848080e7;
                    6'd54: data_o = 32'hc41ff06f;
                    6'd55: data_o = 32'hfbd58793;
                    6'd56: data_o = 32'h0ff7f793;
                    6'd57: data_o = 32'h02500693;
                    6'd58: data_o = 32'h12d44703;
                    6'd59: data_o = 32'h04f6ec63;
                    6'd60: data_o = 32'h02812683;
                    6'd61: data_o = 32'h00279793;
                    6'd62: data_o = 32'h00f687b3;
                    6'd63: data_o = 32'h0007a783;
                    default: data_o = 32'b0;
                endcase
                14'd35  : case (word_addr[5:0])   // words 2240..2303
                    6'd0 : data_o = 32'h00078067;
                    6'd1 : data_o = 32'h0bc42703;
                    6'd2 : data_o = 32'h00170713;
                    6'd3 : data_o = 32'h0ae42e23;
                    6'd4 : data_o = 32'hb7dff06f;
                    6'd5 : data_o = 32'h00078693;
                    6'd6 : data_o = 32'h00000613;
                    6'd7 : data_o = 32'hd71ff06f;
                    6'd8 : data_o = 32'h00100513;
                    6'd9 : data_o = 32'hfffff097;
                    6'd10: data_o = 32'h7f4080e7;
                    6'd11: data_o = 32'hbedff06f;
                    6'd12: data_o = 32'h0017d713;
                    6'd13: data_o = 32'h02440413;
                    6'd14: data_o = 32'h00377713;
                    6'd15: data_o = 32'h0ce42623;
                    6'd16: data_o = 32'h911ff06f;
                    6'd17: data_o = 32'h11042783;
                    6'd18: data_o = 32'h0fe00713;
                    6'd19: data_o = 32'h00f76663;
                    6'd20: data_o = 32'h00178793;
                    6'd21: data_o = 32'h10f42823;
                    6'd22: data_o = 32'h018d2783;
                    6'd23: data_o = 32'hba078ee3;
                    6'd24: data_o = 32'h00300513;
                    6'd25: data_o = 32'hfffff097;
                    6'd26: data_o = 32'h7b4080e7;
                    6'd27: data_o = 32'hbadff06f;
                    6'd28: data_o = 32'h00c00793;
                    6'd29: data_o = 32'h2af71e63;
                    6'd30: data_o = 32'h05010513;
                    6'd31: data_o = 32'h00100793;
                    6'd32: data_o = 32'h12e40593;
                    6'd33: data_o = 32'h00fd2c23;
                    6'd34: data_o = 32'hfffff097;
                    6'd35: data_o = 32'hdac080e7;
                    6'd36: data_o = 32'h05010513;
                    6'd37: data_o = 32'hffffe097;
                    6'd38: data_o = 32'h604080e7;
                    6'd39: data_o = 32'hb6054ee3;
                    6'd40: data_o = 32'h16442703;
                    6'd41: data_o = 32'h00a407b3;
                    6'd42: data_o = 32'h00200693;
                    6'd43: data_o = 32'hfff70713;
                    6'd44: data_o = 32'h00d78623;
                    6'd45: data_o = 32'h16e42223;
                    6'd46: data_o = 32'hb61ff06f;
                    6'd47: data_o = 32'h01100793;
                    6'd48: data_o = 32'h26f71863;
                    6'd49: data_o = 32'h12e40593;
                    6'd50: data_o = 32'h05010513;
                    6'd51: data_o = 32'h00100793;
                    6'd52: data_o = 32'h00fd2c23;
                    6'd53: data_o = 32'hfffff097;
                    6'd54: data_o = 32'hd60080e7;
                    6'd55: data_o = 32'h13c44703;
                    6'd56: data_o = 32'h13b44683;
                    6'd57: data_o = 32'h13d44783;
                    6'd58: data_o = 32'h13e44603;
                    6'd59: data_o = 32'h13a44583;
                    6'd60: data_o = 32'h00871713;
                    6'd61: data_o = 32'h00d76733;
                    6'd62: data_o = 32'h01079793;
                    6'd63: data_o = 32'h00e7e7b3;
                    default: data_o = 32'b0;
                endcase
                14'd36  : case (word_addr[5:0])   // words 2304..2367
                    6'd0 : data_o = 32'h01861613;
                    6'd1 : data_o = 32'h00f66633;
                    6'd2 : data_o = 32'h0075f593;
                    6'd3 : data_o = 32'h05010513;
                    6'd4 : data_o = 32'hfffff097;
                    6'd5 : data_o = 32'h968080e7;
                    6'd6 : data_o = 32'hb01ff06f;
                    6'd7 : data_o = 32'h00400793;
                    6'd8 : data_o = 32'h20f71863;
                    6'd9 : data_o = 32'h13045783;
                    6'd10: data_o = 32'h12e45683;
                    6'd11: data_o = 32'h0dc42703;
                    6'd12: data_o = 32'h01079793;
                    6'd13: data_o = 32'h00100613;
                    6'd14: data_o = 32'h00cd2c23;
                    6'd15: data_o = 32'h00d7e7b3;
                    6'd16: data_o = 32'hacf77ce3;
                    6'd17: data_o = 32'h0cf42e23;
                    6'd18: data_o = 32'had1ff06f;
                    6'd19: data_o = 32'h00e00793;
                    6'd20: data_o = 32'h1ef71063;
                    6'd21: data_o = 32'h12e44783;
                    6'd22: data_o = 32'h12f44703;
                    6'd23: data_o = 32'h00100693;
                    6'd24: data_o = 32'h0077f793;
                    6'd25: data_o = 32'h00fd2023;
                    6'd26: data_o = 32'h03812783;
                    6'd27: data_o = 32'h00177713;
                    6'd28: data_o = 32'h00dd2c23;
                    6'd29: data_o = 32'h10e42c23;
                    6'd30: data_o = 32'h00c00593;
                    6'd31: data_o = 32'h02c12683;
                    6'd32: data_o = 32'h0047d603;
                    6'd33: data_o = 32'h00278793;
                    6'd34: data_o = 32'h015686b3;
                    6'd35: data_o = 32'h00c69023;
                    6'd36: data_o = 32'h002a8a93;
                    6'd37: data_o = 32'hfeba94e3;
                    6'd38: data_o = 32'h11442783;
                    6'd39: data_o = 32'h10c42683;
                    6'd40: data_o = 32'h0037d793;
                    6'd41: data_o = 32'h0017f793;
                    6'd42: data_o = 32'h00e7e7b3;
                    6'd43: data_o = 32'h00779793;
                    6'd44: data_o = 32'h0706f713;
                    6'd45: data_o = 32'h00e7e7b3;
                    6'd46: data_o = 32'h10f42623;
                    6'd47: data_o = 32'hf0000737;
                    6'd48: data_o = 32'h00f72023;
                    6'd49: data_o = 32'ha55ff06f;
                    6'd50: data_o = 32'h00300793;
                    6'd51: data_o = 32'h16f71263;
                    6'd52: data_o = 32'h12e44783;
                    6'd53: data_o = 32'h13044703;
                    6'd54: data_o = 32'h12f44683;
                    6'd55: data_o = 32'h0077f793;
                    6'd56: data_o = 32'h00179793;
                    6'd57: data_o = 32'h00871713;
                    6'd58: data_o = 32'h00d76733;
                    6'd59: data_o = 32'h00f407b3;
                    6'd60: data_o = 32'h00100693;
                    6'd61: data_o = 32'h00dd2c23;
                    6'd62: data_o = 32'h0ee79023;
                    6'd63: data_o = 32'ha1dff06f;
                    default: data_o = 32'b0;
                endcase
                14'd37  : case (word_addr[5:0])   // words 2368..2431
                    6'd0 : data_o = 32'h00d00793;
                    6'd1 : data_o = 32'h12f71663;
                    6'd2 : data_o = 32'h05010513;
                    6'd3 : data_o = 32'h00100793;
                    6'd4 : data_o = 32'h12e40593;
                    6'd5 : data_o = 32'h00fd2c23;
                    6'd6 : data_o = 32'hfffff097;
                    6'd7 : data_o = 32'hc1c080e7;
                    6'd8 : data_o = 32'h05010513;
                    6'd9 : data_o = 32'hffffe097;
                    6'd10: data_o = 32'h474080e7;
                    6'd11: data_o = 32'h9e0556e3;
                    6'd12: data_o = 32'h05412503;
                    6'd13: data_o = 32'h85ebd6b7;
                    6'd14: data_o = 32'ha7768693;
                    6'd15: data_o = 32'h05012783;
                    6'd16: data_o = 32'h02d50533;
                    6'd17: data_o = 32'h9e378737;
                    6'd18: data_o = 32'h05812683;
                    6'd19: data_o = 32'h9b170713;
                    6'd20: data_o = 32'hc2b2be37;
                    6'd21: data_o = 32'he3de0e13;
                    6'd22: data_o = 32'hf1000637;
                    6'd23: data_o = 32'hf1000837;
                    6'd24: data_o = 32'h00860613;
                    6'd25: data_o = 32'h00480813;
                    6'd26: data_o = 32'h02e787b3;
                    6'd27: data_o = 32'h27d4f737;
                    6'd28: data_o = 32'hb2f70713;
                    6'd29: data_o = 32'h03f00893;
                    6'd30: data_o = 32'h00100593;
                    6'd31: data_o = 32'h00800313;
                    6'd32: data_o = 32'h03c686b3;
                    6'd33: data_o = 32'h00a7c7b3;
                    6'd34: data_o = 32'h00d7c7b3;
                    6'd35: data_o = 32'h02e787b3;
                    6'd36: data_o = 32'h01a7d793;
                    6'd37: data_o = 32'h02c0006f;
                    6'd38: data_o = 32'h03f6f513;
                    6'd39: data_o = 32'h00a98533;
                    6'd40: data_o = 32'h00168693;
                    6'd41: data_o = 32'h00d42023;
                    6'd42: data_o = 32'h01c50023;
                    6'd43: data_o = 32'h00e40533;
                    6'd44: data_o = 32'h00c54683;
                    6'd45: data_o = 32'h42b69463;
                    6'd46: data_o = 32'h001a8a93;
                    6'd47: data_o = 32'h946a8ee3;
                    6'd48: data_o = 32'h00062683;
                    6'd49: data_o = 32'h00fa8733;
                    6'd50: data_o = 32'h03f77713;
                    6'd51: data_o = 32'h0026f693;
                    6'd52: data_o = 32'hfc068ee3;
                    6'd53: data_o = 32'h00082e03;
                    6'd54: data_o = 32'h00062023;
                    6'd55: data_o = 32'h00042683;
                    6'd56: data_o = 32'h00442503;
                    6'd57: data_o = 32'h40a68533;
                    6'd58: data_o = 32'hfaa8f8e3;
                    6'd59: data_o = 32'h00842683;
                    6'd60: data_o = 32'h00168693;
                    6'd61: data_o = 32'h00d42423;
                    6'd62: data_o = 32'hfb5ff06f;
                    6'd63: data_o = 32'h02071a63;
                    default: data_o = 32'b0;
                endcase
                14'd38  : case (word_addr[5:0])   // words 2432..2495
                    6'd0 : data_o = 32'h004007b7;
                    6'd1 : data_o = 32'h14f42a23;
                    6'd2 : data_o = 32'h000107b7;
                    6'd3 : data_o = 32'h00100713;
                    6'd4 : data_o = 32'hfff78793;
                    6'd5 : data_o = 32'h00ed2c23;
                    6'd6 : data_o = 32'h14f42c23;
                    6'd7 : data_o = 32'h14e42e23;
                    6'd8 : data_o = 32'h8f9ff06f;
                    6'd9 : data_o = 32'h01000793;
                    6'd10: data_o = 32'h30f70863;
                    6'd11: data_o = 32'h2e070263;
                    6'd12: data_o = 32'h11042783;
                    6'd13: data_o = 32'h0fe00713;
                    6'd14: data_o = 32'h00f76663;
                    6'd15: data_o = 32'h00178793;
                    6'd16: data_o = 32'h10f42823;
                    6'd17: data_o = 32'h018d2783;
                    6'd18: data_o = 32'h8c0788e3;
                    6'd19: data_o = 32'h00400513;
                    6'd20: data_o = 32'hfffff097;
                    6'd21: data_o = 32'h4c8080e7;
                    6'd22: data_o = 32'h8c1ff06f;
                    6'd23: data_o = 32'h00a00793;
                    6'd24: data_o = 32'hfcf718e3;
                    6'd25: data_o = 32'h13044683;
                    6'd26: data_o = 32'h13244703;
                    6'd27: data_o = 32'h13444783;
                    6'd28: data_o = 32'h13344503;
                    6'd29: data_o = 32'h12f44883;
                    6'd30: data_o = 32'h13144803;
                    6'd31: data_o = 32'h12e44583;
                    6'd32: data_o = 32'h13544603;
                    6'd33: data_o = 32'h00869693;
                    6'd34: data_o = 32'h00871713;
                    6'd35: data_o = 32'h00879793;
                    6'd36: data_o = 32'h00a7e7b3;
                    6'd37: data_o = 32'h0116e6b3;
                    6'd38: data_o = 32'h01076733;
                    6'd39: data_o = 32'h00100513;
                    6'd40: data_o = 32'h00fd2423;
                    6'd41: data_o = 32'h00ad2c23;
                    6'd42: data_o = 32'h100107b7;
                    6'd43: data_o = 32'h00dd2e23;
                    6'd44: data_o = 32'h00ed2223;
                    6'd45: data_o = 32'h16b42423;
                    6'd46: data_o = 32'h00078d13;
                    6'd47: data_o = 32'h0ff67793;
                    6'd48: data_o = 32'h26060863;
                    6'd49: data_o = 32'h13645703;
                    6'd50: data_o = 32'h02fd2023;
                    6'd51: data_o = 32'h16e42623;
                    6'd52: data_o = 32'h849ff06f;
                    6'd53: data_o = 32'hf4071ee3;
                    6'd54: data_o = 32'h16044683;
                    6'd55: data_o = 32'h0f045783;
                    6'd56: data_o = 32'h11044703;
                    6'd57: data_o = 32'h16442603;
                    6'd58: data_o = 32'h01069693;
                    6'd59: data_o = 32'h00d7e7b3;
                    6'd60: data_o = 32'h01871713;
                    6'd61: data_o = 32'h00e7e7b3;
                    6'd62: data_o = 32'h00c00513;
                    6'd63: data_o = 32'h00100713;
                    default: data_o = 32'b0;
                endcase
                14'd39  : case (word_addr[5:0])   // words 2496..2559
                    6'd0 : data_o = 32'h04f12423;
                    6'd1 : data_o = 32'h00ed2c23;
                    6'd2 : data_o = 32'h04c10623;
                    6'd3 : data_o = 32'hfffff097;
                    6'd4 : data_o = 32'hba8080e7;
                    6'd5 : data_o = 32'h000107b7;
                    6'd6 : data_o = 32'h05100693;
                    6'd7 : data_o = 32'hfff78793;
                    6'd8 : data_o = 32'h80f687b3;
                    6'd9 : data_o = 32'h00000713;
                    6'd10: data_o = 32'h04d10823;
                    6'd11: data_o = 32'h00500513;
                    6'd12: data_o = 32'h04810693;
                    6'd13: data_o = 32'h0006c603;
                    6'd14: data_o = 32'h00170713;
                    6'd15: data_o = 32'h05010593;
                    6'd16: data_o = 32'h00e585b3;
                    6'd17: data_o = 32'h00c58023;
                    6'd18: data_o = 32'h80f607b3;
                    6'd19: data_o = 32'h00168693;
                    6'd20: data_o = 32'hfea712e3;
                    6'd21: data_o = 32'h09042703;
                    6'd22: data_o = 32'h0b842603;
                    6'd23: data_o = 32'h04f11b23;
                    6'd24: data_o = 32'h07800693;
                    6'd25: data_o = 32'h40c707b3;
                    6'd26: data_o = 32'h26f6e263;
                    6'd27: data_o = 32'h05010513;
                    6'd28: data_o = 32'hfffff097;
                    6'd29: data_o = 32'ha04080e7;
                    6'd30: data_o = 32'hfa0ff06f;
                    6'd31: data_o = 32'h01500793;
                    6'd32: data_o = 32'heaf718e3;
                    6'd33: data_o = 32'h13045a83;
                    6'd34: data_o = 32'h12e45783;
                    6'd35: data_o = 32'h0dc42703;
                    6'd36: data_o = 32'h010a9a93;
                    6'd37: data_o = 32'h00100693;
                    6'd38: data_o = 32'h00faeab3;
                    6'd39: data_o = 32'h00dd2c23;
                    6'd40: data_o = 32'h13245783;
                    6'd41: data_o = 32'h14045583;
                    6'd42: data_o = 32'h14244b03;
                    6'd43: data_o = 32'h15576e63;
                    6'd44: data_o = 32'h000106b7;
                    6'd45: data_o = 32'h0087d713;
                    6'd46: data_o = 32'hfff68693;
                    6'd47: data_o = 32'h80d70733;
                    6'd48: data_o = 32'h0ff7f793;
                    6'd49: data_o = 32'h80e78733;
                    6'd50: data_o = 32'h13440793;
                    6'd51: data_o = 32'h14040613;
                    6'd52: data_o = 32'h0007c683;
                    6'd53: data_o = 32'h80e68733;
                    6'd54: data_o = 32'h00178793;
                    6'd55: data_o = 32'hfef61ae3;
                    6'd56: data_o = 32'hf10007b7;
                    6'd57: data_o = 32'h0087a683;
                    6'd58: data_o = 32'h00878793;
                    6'd59: data_o = 32'h0026f693;
                    6'd60: data_o = 32'h02068c63;
                    6'd61: data_o = 32'hf1000637;
                    6'd62: data_o = 32'h00462503;
                    6'd63: data_o = 32'h0007a023;
                    default: data_o = 32'b0;
                endcase
                14'd40  : case (word_addr[5:0])   // words 2560..2623
                    6'd0 : data_o = 32'h00042783;
                    6'd1 : data_o = 32'h00442683;
                    6'd2 : data_o = 32'h03f00813;
                    6'd3 : data_o = 32'h40d786b3;
                    6'd4 : data_o = 32'h1ad86663;
                    6'd5 : data_o = 32'h03f7f693;
                    6'd6 : data_o = 32'h00d986b3;
                    6'd7 : data_o = 32'h00178793;
                    6'd8 : data_o = 32'h00f42023;
                    6'd9 : data_o = 32'h00a68023;
                    6'd10: data_o = 32'h000107b7;
                    6'd11: data_o = 32'hfff78793;
                    6'd12: data_o = 32'h00f74733;
                    6'd13: data_o = 32'h0ae59e63;
                    6'd14: data_o = 32'h16842783;
                    6'd15: data_o = 32'hecfb6e63;
                    6'd16: data_o = 32'h03c12583;
                    6'd17: data_o = 32'h05010513;
                    6'd18: data_o = 32'hfffff097;
                    6'd19: data_o = 32'h8ec080e7;
                    6'd20: data_o = 32'h0d442783;
                    6'd21: data_o = 32'h1c079263;
                    6'd22: data_o = 32'hf10007b7;
                    6'd23: data_o = 32'h0087a703;
                    6'd24: data_o = 32'h00878793;
                    6'd25: data_o = 32'h00277713;
                    6'd26: data_o = 32'h02070c63;
                    6'd27: data_o = 32'hf10006b7;
                    6'd28: data_o = 32'h0046a603;
                    6'd29: data_o = 32'h0007a023;
                    6'd30: data_o = 32'h00042783;
                    6'd31: data_o = 32'h00442703;
                    6'd32: data_o = 32'h03f00593;
                    6'd33: data_o = 32'h40e78733;
                    6'd34: data_o = 32'h1ae5e263;
                    6'd35: data_o = 32'h03f7f713;
                    6'd36: data_o = 32'h00e98733;
                    6'd37: data_o = 32'h00178793;
                    6'd38: data_o = 32'h00f42023;
                    6'd39: data_o = 32'h00c70023;
                    6'd40: data_o = 32'h17042703;
                    6'd41: data_o = 32'h00800793;
                    6'd42: data_o = 32'h18f70a63;
                    6'd43: data_o = 32'h17042703;
                    6'd44: data_o = 32'h00412683;
                    6'd45: data_o = 32'h00271793;
                    6'd46: data_o = 32'h00e787b3;
                    6'd47: data_o = 32'h00279793;
                    6'd48: data_o = 32'h00f687b3;
                    6'd49: data_o = 32'h05012683;
                    6'd50: data_o = 32'h00170713;
                    6'd51: data_o = 32'h9157ae23;
                    6'd52: data_o = 32'h90d7a823;
                    6'd53: data_o = 32'h05412683;
                    6'd54: data_o = 32'h93678023;
                    6'd55: data_o = 32'h16e42823;
                    6'd56: data_o = 32'h90d7aa23;
                    6'd57: data_o = 32'h05812683;
                    6'd58: data_o = 32'h90d7ac23;
                    6'd59: data_o = 32'he2cff06f;
                    6'd60: data_o = 32'h16042783;
                    6'd61: data_o = 32'h0fe00713;
                    6'd62: data_o = 32'he2f76063;
                    6'd63: data_o = 32'h00178793;
                    default: data_o = 32'b0;
                endcase
                14'd41  : case (word_addr[5:0])   // words 2624..2687
                    6'd0 : data_o = 32'h16f42023;
                    6'd1 : data_o = 32'he14ff06f;
                    6'd2 : data_o = 32'h0d542e23;
                    6'd3 : data_o = 32'hea5ff06f;
                    6'd4 : data_o = 32'h00100793;
                    6'd5 : data_o = 32'h00c00513;
                    6'd6 : data_o = 32'h00fd2c23;
                    6'd7 : data_o = 32'hfffff097;
                    6'd8 : data_o = 32'h998080e7;
                    6'd9 : data_o = 32'h0e042c23;
                    6'd10: data_o = 32'h0c042423;
                    6'd11: data_o = 32'hdecff06f;
                    6'd12: data_o = 32'h00100793;
                    6'd13: data_o = 32'hd91ff06f;
                    6'd14: data_o = 32'h00100a93;
                    6'd15: data_o = 32'h00c00513;
                    6'd16: data_o = 32'h015d2c23;
                    6'd17: data_o = 32'hfffff097;
                    6'd18: data_o = 32'h970080e7;
                    6'd19: data_o = 32'h13845703;
                    6'd20: data_o = 32'h13c45783;
                    6'd21: data_o = 32'h13645583;
                    6'd22: data_o = 32'h13a45603;
                    6'd23: data_o = 32'h13045803;
                    6'd24: data_o = 32'h13445683;
                    6'd25: data_o = 32'h13245503;
                    6'd26: data_o = 32'h12e45883;
                    6'd27: data_o = 32'h01071713;
                    6'd28: data_o = 32'h01079793;
                    6'd29: data_o = 32'h00b76733;
                    6'd30: data_o = 32'h00c7e7b3;
                    6'd31: data_o = 32'h03012583;
                    6'd32: data_o = 32'h03412603;
                    6'd33: data_o = 32'h01081813;
                    6'd34: data_o = 32'h01069693;
                    6'd35: data_o = 32'h00a6e6b3;
                    6'd36: data_o = 32'h01186833;
                    6'd37: data_o = 32'h05010513;
                    6'd38: data_o = 32'h0f542c23;
                    6'd39: data_o = 32'h0c042423;
                    6'd40: data_o = 32'h0f042e23;
                    6'd41: data_o = 32'h10d42023;
                    6'd42: data_o = 32'h10e42223;
                    6'd43: data_o = 32'h10f42423;
                    6'd44: data_o = 32'hffffe097;
                    6'd45: data_o = 32'hbdc080e7;
                    6'd46: data_o = 32'hd60ff06f;
                    6'd47: data_o = 32'h00842783;
                    6'd48: data_o = 32'h00178793;
                    6'd49: data_o = 32'h00f42423;
                    6'd50: data_o = 32'he61ff06f;
                    6'd51: data_o = 32'h0bc42783;
                    6'd52: data_o = 32'h00178793;
                    6'd53: data_o = 32'h0af42e23;
                    6'd54: data_o = 32'hd40ff06f;
                    6'd55: data_o = 32'h16442683;
                    6'd56: data_o = 32'h00171793;
                    6'd57: data_o = 32'h00e787b3;
                    6'd58: data_o = 32'h00168713;
                    6'd59: data_o = 32'h05012683;
                    6'd60: data_o = 32'h00279793;
                    6'd61: data_o = 32'h00f987b3;
                    6'd62: data_o = 32'h04d7a023;
                    6'd63: data_o = 32'h05412683;
                    default: data_o = 32'b0;
                endcase
                14'd42  : case (word_addr[5:0])   // words 2688..2751
                    6'd0 : data_o = 32'h00b50623;
                    6'd1 : data_o = 32'h16e42223;
                    6'd2 : data_o = 32'h04d7a223;
                    6'd3 : data_o = 32'h05812683;
                    6'd4 : data_o = 32'h04d7a423;
                    6'd5 : data_o = 32'hd04ff06f;
                    6'd6 : data_o = 32'h000b0593;
                    6'd7 : data_o = 32'h05010513;
                    6'd8 : data_o = 32'hffffe097;
                    6'd9 : data_o = 32'h5cc080e7;
                    6'd10: data_o = 32'hcf0ff06f;
                    6'd11: data_o = 32'h00842783;
                    6'd12: data_o = 32'h00178793;
                    6'd13: data_o = 32'h00f42423;
                    6'd14: data_o = 32'he69ff06f;
                    6'd15: data_o = 32'h00412703;
                    6'd16: data_o = 32'h01812783;
                    6'd17: data_o = 32'h99c70713;
                    6'd18: data_o = 32'h0147a803;
                    6'd19: data_o = 32'h0187a503;
                    6'd20: data_o = 32'h01c7a583;
                    6'd21: data_o = 32'h0207a603;
                    6'd22: data_o = 32'h0247a683;
                    6'd23: data_o = 32'h0107a023;
                    6'd24: data_o = 32'h00a7a223;
                    6'd25: data_o = 32'h00b7a423;
                    6'd26: data_o = 32'h00c7a623;
                    6'd27: data_o = 32'h00d7a823;
                    6'd28: data_o = 32'h01478793;
                    6'd29: data_o = 32'hfcf71ae3;
                    6'd30: data_o = 32'h00700793;
                    6'd31: data_o = 32'h16f42823;
                    6'd32: data_o = 32'he2dff06f;
                    6'd33: data_o = 32'h0040244c;
                    6'd34: data_o = 32'h00402344;
                    6'd35: data_o = 32'h00402344;
                    6'd36: data_o = 32'h00402344;
                    6'd37: data_o = 32'h004024c8;
                    6'd38: data_o = 32'h00402500;
                    6'd39: data_o = 32'h004025fc;
                    6'd40: data_o = 32'h00402344;
                    6'd41: data_o = 32'h00402624;
                    6'd42: data_o = 32'h00402344;
                    6'd43: data_o = 32'h00402344;
                    6'd44: data_o = 32'h00402344;
                    6'd45: data_o = 32'h00402344;
                    6'd46: data_o = 32'h0040265c;
                    6'd47: data_o = 32'h004026d4;
                    6'd48: data_o = 32'h0040277c;
                    6'd49: data_o = 32'h004023bc;
                    6'd50: data_o = 32'h0040241c;
                    6'd51: data_o = 32'h00402344;
                    6'd52: data_o = 32'h00402344;
                    6'd53: data_o = 32'h00402344;
                    6'd54: data_o = 32'h00402344;
                    6'd55: data_o = 32'h00402344;
                    6'd56: data_o = 32'h00402344;
                    6'd57: data_o = 32'h00402344;
                    6'd58: data_o = 32'h00402344;
                    6'd59: data_o = 32'h00402344;
                    6'd60: data_o = 32'h00402344;
                    6'd61: data_o = 32'h00402344;
                    6'd62: data_o = 32'h00402344;
                    6'd63: data_o = 32'h00402344;
                    default: data_o = 32'b0;
                endcase
                14'd43  : case (word_addr[5:0])   // words 2752..2815
                    6'd0 : data_o = 32'h00402344;
                    6'd1 : data_o = 32'h00402344;
                    6'd2 : data_o = 32'h00402344;
                    6'd3 : data_o = 32'h00402344;
                    6'd4 : data_o = 32'h00402344;
                    6'd5 : data_o = 32'h00402344;
                    6'd6 : data_o = 32'h00402370;
                    6'd7 : data_o = 32'h00030201;
                    6'd8 : data_o = 32'h33323130;
                    6'd9 : data_o = 32'h37363534;
                    6'd10: data_o = 32'h62613938;
                    6'd11: data_o = 32'h66656463;
                    6'd12: data_o = 32'h00000000;
                    6'd13: data_o = 32'h00000001;
                    6'd14: data_o = 32'h00000bb8;
                    6'd15: data_o = 32'h000000fa;
                    6'd16: data_o = 32'h00fa0000;
                    6'd17: data_o = 32'h02ee01f4;
                    6'd18: data_o = 32'h017c0082;
                    6'd19: data_o = 32'h00000001;
                    6'd20: data_o = 32'h000001f4;
                    6'd21: data_o = 32'h00000040;
                    default: data_o = 32'b0;
                endcase
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



//  ---------- INLCUDED BLOCK: uart  ---------- 
// ============================================================================
// uart.v - Serial Controller (Stage 3 Block Guide §2). Memory-mapped at
// 0xF1000000 (peripheral slot SLOT = 1). 8-N-1, LSB first, full duplex.
//
//   offset 0x0  TXDATA   RW  [7:0] byte sent when TRANSMIT is set
//   offset 0x4  RXDATA   R   [7:0] last byte received
//   offset 0x8  CONTROL      bit 0 TRANSMIT (W, one-cycle pulse, reads 0)
//                            bit 1 RXDONE   (set by the receiver; write 0 clears,
//                                            write 1 has no effect)
//                            bit 2 TXDONE   (R, transmitter idle; resets to 1)
//   anything else in the slot reads 0 and ignores writes (no aliasing)
//
// Frame: start (0), D0..D7, one stop (1) = 10 bit-times of CLKS_PER_BIT clocks.
// CLKS_PER_BIT = round(CLK_FREQ_HZ / BAUD_RATE); CLK_FREQ_HZ must equal the
// clock actually driving clk_i (30303030 for the 33 ns ASIC constraint).
//
// Design decisions:
//   * TRANSMIT starts a frame only while the transmitter is idle; a TRANSMIT
//     written while busy is ignored. TXDATA is copied into the shift register
//     when the frame starts, so writing TXDATA mid-frame is safe.
//   * TXDONE clears on the edge that starts a frame and sets when the stop bit
//     has been fully sent. Software writes to it have no effect.
//   * RXDONE: a reception completing in the same cycle as a software clear
//     wins, so a byte is never lost silently.
//   * "No oversampling": rx_i passes a 2-flip-flop synchroniser; the start edge
//     is detected at the system clock rate, re-checked at mid-start (glitch
//     rejection), then each bit is sampled once, at mid-bit.
//   * A frame whose stop bit reads 0 (framing error, break) is dropped. The
//     receiver arms on a falling EDGE, so a line held low cannot start another
//     frame until it has returned high: no phantom bytes from a break or from
//     rx_i held low at reset.
//   * Overrun: a new byte overwrites RXDATA; RXDONE stays set.
//   * Counters run only while a frame is in flight: no toggling when idle.
//
// Bus ports are the Stage 3 peripheral contract; reads have no
// side effects. CLKS_PER_BIT must be at least 4.
// ============================================================================
module uart #(
    parameter [3:0] SLOT        = 4'd1,       // 0xF1000000
    parameter       CLK_FREQ_HZ = 30303030,   // 33 ns ASIC clock
    parameter       BAUD_RATE   = 115200
) (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire [31:0] bus_addr_i,
    input  wire [31:0] bus_wdata_i,
    input  wire        bus_we_i,
    input  wire [3:0]  bus_bw_i,
    input  wire [31:0] bus_rdata_i,
    output wire [31:0] bus_rdata_o,
    output wire        tx_o,
    input  wire        rx_i
);
    localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;
    localparam integer CW           = (CLKS_PER_BIT <= 2) ? 1 : $clog2(CLKS_PER_BIT);
    localparam [CW-1:0] BIT_LAST    = CLKS_PER_BIT - 1;
    localparam [CW-1:0] HALF_LAST   = HALF_BIT - 1;

    localparam [3:0] REGION      = 4'hF;
    localparam [1:0] OFF_TXDATA  = 2'd0,
                     OFF_RXDATA  = 2'd1,
                     OFF_CONTROL = 2'd2;

    localparam [1:0] TX_IDLE = 2'd0, TX_START = 2'd1, TX_DATA = 2'd2, TX_STOP = 2'd3;
    localparam [1:0] RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;

    // ---------------- Bus decode (the same four lines in every peripheral) --
    wire       hit     = (bus_addr_i[31:28] == REGION) && (bus_addr_i[27:24] == SLOT) &&
                         (bus_addr_i[23:4] == 20'b0);
    wire [1:0] off     = bus_addr_i[3:2];
    wire [3:0] wr_lane = {4{bus_we_i & hit}} & bus_bw_i;

    // Every field lives in byte lane 0.
    wire wr_txdata  = wr_lane[0] & (off == OFF_TXDATA);
    wire wr_control = wr_lane[0] & (off == OFF_CONTROL);

    // ---------------- Programmer-visible registers --------------------------
    reg [7:0] txdata, rxdata;
    reg       transmit, rxdone, txdone;

    // ---------------- Transmitter -------------------------------------------
    reg [1:0]    tx_state;
    reg [CW-1:0] tx_cnt;
    reg [2:0]    tx_bit;
    reg [7:0]    tx_shift;
    reg          tx_q;
    wire         tx_tick = (tx_cnt == {CW{1'b0}});

    always @(posedge clk_i) begin
        if (rst_i) begin
            tx_state <= TX_IDLE;
            tx_cnt   <= {CW{1'b0}};
            tx_bit   <= 3'd0;
            tx_shift <= 8'd0;
            tx_q     <= 1'b1;               // line idles high
            txdone   <= 1'b1;               // idle: ready for the first byte
        end else begin
            case (tx_state)
                TX_IDLE: if (transmit) begin
                    tx_shift <= txdata;
                    tx_cnt   <= BIT_LAST;
                    tx_q     <= 1'b0;       // start bit
                    txdone   <= 1'b0;
                    tx_state <= TX_START;
                end
                TX_START: if (tx_tick) begin
                    tx_cnt   <= BIT_LAST;
                    tx_q     <= tx_shift[0];  // D0
                    tx_bit   <= 3'd0;
                    tx_state <= TX_DATA;
                end else tx_cnt <= tx_cnt - 1'b1;
                TX_DATA: if (tx_tick) begin
                    tx_cnt <= BIT_LAST;
                    if (tx_bit == 3'd7) begin
                        tx_q     <= 1'b1;   // stop bit
                        tx_state <= TX_STOP;
                    end else begin
                        tx_q     <= tx_shift[1];
                        tx_shift <= {1'b0, tx_shift[7:1]};
                        tx_bit   <= tx_bit + 1'b1;
                    end
                end else tx_cnt <= tx_cnt - 1'b1;
                TX_STOP: if (tx_tick) begin
                    txdone   <= 1'b1;
                    tx_state <= TX_IDLE;
                end else tx_cnt <= tx_cnt - 1'b1;
                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    assign tx_o = tx_q;

    // ---------------- Receiver ----------------------------------------------
    reg          rx_sync1, rx_sync2, rx_prev;
    reg [1:0]    rx_state;
    reg [CW-1:0] rx_cnt;
    reg [2:0]    rx_bit;
    reg [7:0]    rx_shift;
    wire         rx_tick = (rx_cnt == {CW{1'b0}});
    wire         rx_fall = rx_prev & ~rx_sync2;
    wire         rx_done = (rx_state == RX_STOP) & rx_tick & rx_sync2;

    always @(posedge clk_i) begin
        if (rst_i) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
            rx_prev  <= 1'b1;
            rx_state <= RX_IDLE;
            rx_cnt   <= {CW{1'b0}};
            rx_bit   <= 3'd0;
            rx_shift <= 8'd0;
        end else begin
            rx_sync1 <= rx_i;
            rx_sync2 <= rx_sync1;
            rx_prev  <= rx_sync2;
            case (rx_state)
                RX_IDLE: if (rx_fall) begin
                    rx_cnt   <= HALF_LAST;  // to mid-start
                    rx_state <= RX_START;
                end
                RX_START: if (rx_tick) begin
                    if (!rx_sync2) begin    // still low at mid-start: real start bit
                        rx_cnt   <= BIT_LAST;
                        rx_bit   <= 3'd0;
                        rx_state <= RX_DATA;
                    end else
                        rx_state <= RX_IDLE; // glitch
                end else rx_cnt <= rx_cnt - 1'b1;
                RX_DATA: if (rx_tick) begin
                    rx_shift <= {rx_sync2, rx_shift[7:1]};
                    rx_cnt   <= BIT_LAST;
                    if (rx_bit == 3'd7) rx_state <= RX_STOP;
                    else                rx_bit   <= rx_bit + 1'b1;
                end else rx_cnt <= rx_cnt - 1'b1;
                RX_STOP: if (rx_tick)
                    rx_state <= RX_IDLE;    // rx_done fires here if the stop bit is 1
                else rx_cnt <= rx_cnt - 1'b1;
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // ---------------- Register updates --------------------------------------
    always @(posedge clk_i) begin
        if (rst_i) begin
            txdata   <= 8'd0;
            rxdata   <= 8'd0;
            transmit <= 1'b0;
            rxdone   <= 1'b0;
        end else begin
            if (wr_txdata) txdata <= bus_wdata_i[7:0];
            transmit <= wr_control & bus_wdata_i[0];   // cleared the cycle after
            if (rx_done) rxdata <= rx_shift;
            rxdone <= rx_done | (rxdone & ~(wr_control & ~bus_wdata_i[1]));
        end
    end

    // ---------------- Read-back chain ---------------------------------------
    reg [31:0] rdata_local;
    always @(*) begin
        case (off)
            OFF_TXDATA:  rdata_local = {24'b0, txdata};
            OFF_RXDATA:  rdata_local = {24'b0, rxdata};
            OFF_CONTROL: rdata_local = {29'b0, txdone, rxdone, transmit};
            default:     rdata_local = 32'b0;
        endcase
    end

    assign bus_rdata_o = bus_rdata_i | (hit ? rdata_local : 32'b0);
endmodule



//  ---------- INLCUDED BLOCK: gpio  ---------- 
// ============================================================================
// gpio.v - PIN Controller (Stage 3 Block Guide §1). Memory-mapped at
// 0xF0000000 (peripheral slot SLOT = 0).
//
//   offset 0x0  DATAOUT  RW  level driven on pins configured as outputs
//   offset 0x4  DATAIN   R   level on pins configured as inputs
//   offset 0x8  DATADIR  RW  per-pin direction, 0 = input, 1 = output
//   anything else in the slot reads 0 and ignores writes (no aliasing)
//
// Figure 1 is split so each target realises the tri-state natively:
// gpio_oe = DATADIR enables the pad driver and gpio_o = DATAOUT is the level
// it drives; the tri-state itself is the ChipInventor Inout Pin (ASIC top),
// never inside this block, because FPGA fabric has no internal tri-states.
//
// Design decisions:
//   * Reset: all pins inputs, DATAOUT = 0 - nothing drives a pad out of reset.
//   * Inputs pass a 2-flip-flop synchroniser (sync1 -> sync2) before use;
//     sync2 is Figure 1's DATAIN flip-flop.
//   * DATAIN reads 0 for a pin configured as output: Figure 1's input buffer is
//     enabled by ~DATADIR, so an output pin's level never reaches DATAIN.
//   * Writes honour byte enables: bit b of a register is written only when
//     bus_bw_i[b/8] is set. With N_PINS <= 8 every field is in byte lane 0.
//   * Reserved bits read 0.
//
// Bus ports are the Stage 3 peripheral contract, identical in every
// peripheral; reads have no side effects.
// ============================================================================
module gpio #(
    parameter [3:0] SLOT   = 4'd0, // 0xF0000000
    parameter       N_PINS = 8     // 1..32
) (
    input  wire              clk_i,
    input  wire              rst_i,
    input  wire [31:0]       bus_addr_i,
    input  wire [31:0]       bus_wdata_i,
    input  wire              bus_we_i,
    input  wire [3:0]        bus_bw_i,
    input  wire [31:0]       bus_rdata_i,
    output wire [31:0]       bus_rdata_o,
    output wire [N_PINS-1:0] gpio_o,
    output wire [N_PINS-1:0] gpio_oe,
    input  wire [N_PINS-1:0] gpio_i
);
    localparam [3:0] REGION      = 4'hF;
    localparam [1:0] OFF_DATAOUT = 2'd0,
                     OFF_DATAIN  = 2'd1,
                     OFF_DATADIR = 2'd2;

    // ---------------- Bus decode (the same four lines in every peripheral) --
    wire       hit     = (bus_addr_i[31:28] == REGION) && (bus_addr_i[27:24] == SLOT) &&
                         (bus_addr_i[23:4] == 20'b0);
    wire [1:0] off     = bus_addr_i[3:2];
    wire [3:0] wr_lane = {4{bus_we_i & hit}} & bus_bw_i;

    // Per-bit write enable over a 32-bit register, from the byte lanes.
    wire [31:0]       lane_bits = {{8{wr_lane[3]}}, {8{wr_lane[2]}}, {8{wr_lane[1]}}, {8{wr_lane[0]}}};
    wire [N_PINS-1:0] wr_dataout = (off == OFF_DATAOUT) ? lane_bits[N_PINS-1:0] : {N_PINS{1'b0}};
    wire [N_PINS-1:0] wr_datadir = (off == OFF_DATADIR) ? lane_bits[N_PINS-1:0] : {N_PINS{1'b0}};
    wire [N_PINS-1:0] wdata      = bus_wdata_i[N_PINS-1:0];

    // ---------------- Registers --------------------------------------------
    reg [N_PINS-1:0] dataout, datadir;
    reg [N_PINS-1:0] sync1, sync2;

    always @(posedge clk_i) begin
        if (rst_i) begin
            dataout <= {N_PINS{1'b0}};
            datadir <= {N_PINS{1'b0}};   // all inputs
            sync1   <= {N_PINS{1'b0}};
            sync2   <= {N_PINS{1'b0}};
        end else begin
            dataout <= (dataout & ~wr_dataout) | (wdata & wr_dataout);
            datadir <= (datadir & ~wr_datadir) | (wdata & wr_datadir);
            sync1   <= gpio_i;
            sync2   <= sync1;
        end
    end

    wire [N_PINS-1:0] datain = sync2 & ~datadir;

    assign gpio_o  = dataout;
    assign gpio_oe = datadir;

    // ---------------- Read-back chain ---------------------------------------
    reg [31:0] rdata_local;
    always @(*) begin
        rdata_local = 32'b0;
        case (off)
            OFF_DATAOUT: rdata_local[N_PINS-1:0] = dataout;
            OFF_DATAIN:  rdata_local[N_PINS-1:0] = datain;
            OFF_DATADIR: rdata_local[N_PINS-1:0] = datadir;
            default:     rdata_local = 32'b0;
        endcase
    end

    assign bus_rdata_o = bus_rdata_i | (hit ? rdata_local : 32'b0);
endmodule



//  ---------- INLCUDED BLOCK: gpio_bits  ---------- 
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



// ---------- INCLUDED IP: rvbl2_soc ---------- 


// Automatically generated by ChipInventor Cloud EDA Tool - 3.15
// Careful: this file (hdl.v) will be automatically replaced
// when you ask tool to generate top Verilog code by clicking
// at BLOCKS button.

module rvbl2_soc (

  input wire clk_i,
  input wire rst_i,
  output wire [7:0] gpio_o,
  output wire [7:0] gpio_oe,
  output wire tx_o,
  output wire [31:0] imem_addr_o,
  output wire imem_oe_o,
  input wire [7:0] gpio_i,
  input wire rx_i,
  input wire [31:0] imem_rdata_i

);

//Internal Wires
 wire [31:0] w_1;
 wire [31:0] w_2;
 wire w_3;
 wire [31:0] w_4;
 wire [31:0] w_5;
 wire w_9;
 wire [31:0] w_10;
 wire w_18;
 wire w_19;
 wire [3:0] w_20;
 wire [31:0] w_21;
 wire [31:0] w_22;
 wire [31:0] w_23;
 wire [4:0] w_24;
 wire [4:0] w_25;
 wire [4:0] w_26;
 wire [31:0] w_28;
 wire [31:0] w_29;
 wire w_30;
 wire [31:0] w_31;
 wire [31:0] w_35;
 wire w_41;
 wire [31:0] w_42;
 wire w_43;
 wire [31:0] w_44;
 wire [2:0] w_45;
 wire w_46;
 wire [3:0] w_47;
 wire [31:0] w_51;
 wire [31:0] w_53;
 wire w_55;
 wire [31:0] w_56;
 wire [31:0] w_57;
 wire [3:0] w_58;
 wire [2:0] w_61;
 wire w_62;
 wire w_65;
 wire w_66;
 wire w_67;
 wire [31:0] w_68;
 wire w_69;
 wire [3:0] w_71;
 wire [31:0] w_73;
 wire [31:0] w_74;

//Interface Assigns
assign imem_addr_o[31:0] = w_10;

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
         .z (w_10),
         .a (w_5),
         .b (w_2),
         .s (w_9)
     );

dmem #(.DMEM_WORDS(2048)) blk3660_7 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .address_i (w_10),
         .we_i (w_18),
         .oe_i (w_19),
         .bw_i (w_20),
         .data_i (w_21),
         .data_o (w_22)
     );

ir_fields blk3663_9 (
         .ir (w_23),
         .rs1_addr (w_24),
         .rs2_addr (w_25),
         .rd_addr (w_26)
     );

immediate_generator blk3662_10 (
         .ir (w_23),
         .imm (w_28)
     );

register_file blk3672_11 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .rs1_addr (w_24),
         .rs2_addr (w_25),
         .rd_addr (w_26),
         .rd_data (w_29),
         .reg_write (w_30),
         .rs1_data (w_31),
         .rs2_data (w_35)
     );

mux2_32 blk3669_12 (
         .a (w_31),
         .b (w_5),
         .s (w_41),
         .z (w_42)
     );

mux2_32 blk3669_13 (
         .b (w_28),
         .a (w_35),
         .s (w_43),
         .z (w_44)
     );

branch_comparator blk3657_14 (
         .rs1_data (w_31),
         .rs2_data (w_35),
         .funct3 (w_45),
         .branch_taken (w_46)
     );

alu blk3656_15 (
         .result (w_2),
         .a (w_42),
         .b (w_44),
         .alu_op (w_47)
     );

multiplier blk3666_16 (
         .rs1_data (w_31),
         .rs2_data (w_35),
         .funct3 (w_45),
         .result (w_51)
     );

crc_unit blk3659_17 (
         .rs1_data (w_31),
         .rs2_data (w_35),
         .funct3 (w_45),
         .result (w_53)
     );

lsu blk3665_18 (
         .store_data_o (w_21),
         .rs2_data (w_35),
         .alu_result (w_2),
         .op_size (w_45),
         .is_valid_store (w_55),
         .mem_data_o (w_56),
         .core_data_i (w_57),
         .byte_write_o (w_58)
     );

wb_mux_32 blk3673_19 (
         .pc_plus_4 (w_1),
         .wb_data (w_29),
         .alu_result (w_2),
         .mult_result (w_51),
         .crc_result (w_53),
         .lsu_load_data (w_57),
         .wb_src_sel (w_61)
     );

ir_reg blk3664_23 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .ir (w_23),
         .ir_write (w_62),
         .imem_data (w_56)
     );

pc_reg blk3671_24 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .pc_next (w_4),
         .pc (w_5),
         .pc_write (w_65)
     );

control_unit blk3658_25 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .pc_src_sel (w_3),
         .addr_src_sel (w_9),
         .reg_write (w_30),
         .alu_src_a_sel (w_41),
         .alu_src_b_sel (w_43),
         .op_size (w_45),
         .branch_taken (w_46),
         .alu_op (w_47),
         .is_valid_store (w_55),
         .wb_src_sel (w_61),
         .ir_write (w_62),
         .ir (w_23),
         .pc_write (w_65),
         .we_o (w_66),
         .oe_o (w_67)
     );

address_decoder blk3655_29 (
         .imem_oe_o (imem_oe_o),
         .imem_rdata (imem_rdata_i[31:0]),
         .address_i (w_10),
         .dmem_we_o (w_18),
         .dmem_oe_o (w_19),
         .dmem_bw_o (w_20),
         .dmem_rdata (w_22),
         .data_o (w_56),
         .bw_i (w_58),
         .we_i (w_66),
         .oe_i (w_67),
         .periph_rdata_i (w_68),
         .periph_we_o (w_69),
         .periph_bw_o (w_71),
         .periph_chain_o (w_73)
     );

uart #(.CLK_FREQ_HZ(30303030), .BAUD_RATE(115200)) blk4681_30 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .tx_o (tx_o),
         .rx_i (rx_i),
         .bus_addr_i (w_10),
         .bus_wdata_i (w_21),
         .bus_rdata_o (w_68),
         .bus_we_i (w_69),
         .bus_bw_i (w_71),
         .bus_rdata_i (w_74)
     );

gpio #(.N_PINS(8)) blk4682_31 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .gpio_o (gpio_o[7:0]),
         .gpio_oe (gpio_oe[7:0]),
         .gpio_i (gpio_i[7:0]),
         .bus_addr_i (w_10),
         .bus_wdata_i (w_21),
         .bus_we_i (w_69),
         .bus_bw_i (w_71),
         .bus_rdata_i (w_73),
         .bus_rdata_o (w_74)
     );


endmodule



// Automatically generated by ChipInventor Cloud EDA Tool - 3.15
// Careful: this file (hdl.v) will be automatically replaced
// when you ask tool to generate top Verilog code by clicking
// at BLOCKS button.

module top (

  input wire rx_i,
  inout pins_io_2,
  inout pins_io_3,
  inout pins_io_4,
  inout pins_io_5,
  inout pins_io_6,
  inout pins_io_1,
  inout pins_io_7,
  inout pins_io_0,
  output wire tx_o,
  input wire clk_i,
  input wire rst_i

);

//Internal Wires
 wire [7:0] w_1;
 wire [31:0] w_2;
 wire [7:0] w_3;
 wire [7:0] w_4;
 wire [31:0] w_5;
 wire w_6;
 wire w_7;
 wire w_8;
 wire w_9;
 wire w_10;
 wire w_11;
 wire w_12;
 wire w_13;
 wire w_14;
 wire w_15;
 wire w_16;
 wire w_17;
 wire w_18;
 wire w_19;
 wire w_20;
 wire w_21;
 wire w_22;

//Interface Assigns
	assign pins_io_2 = w_7 ? w_8 : 1'bZ ;
	assign pins_io_3 = w_9 ? w_10 : 1'bZ ;
	assign pins_io_4 = w_11 ? w_12 : 1'bZ ;
	assign pins_io_5 = w_13 ? w_14 : 1'bZ ;
	assign pins_io_6 = w_15 ? w_16 : 1'bZ ;
	assign pins_io_1 = w_17 ? w_18 : 1'bZ ;
	assign pins_io_7 = w_19 ? w_20 : 1'bZ ;
	assign pins_io_0 = w_21 ? w_22 : 1'bZ ;

//Instances of Modules
rvbl2_soc blkProj15670_1 (
         .rx_i (rx_i),
         .tx_o (tx_o),
         .clk_i (clk_i),
         .rst_i (rst_i),
         .gpio_i (w_1),
         .imem_rdata_i (w_2),
         .gpio_o (w_3),
         .gpio_oe (w_4),
         .imem_addr_o (w_5),
         .imem_oe_o (w_6)
     );

gpio_bits blk4683_3 (
         .p2_i (pins_io_2),
         .p3_i (pins_io_3),
         .p4_i (pins_io_4),
         .p5_i (pins_io_5),
         .p6_i (pins_io_6),
         .p1_i (pins_io_1),
         .p7_i (pins_io_7),
         .p0_i (pins_io_0),
         .gpio_i (w_1),
         .gpio_o (w_3),
         .gpio_oe (w_4),
         .d2_o (w_7),
         .c2_o (w_8),
         .d3_o (w_9),
         .c3_o (w_10),
         .d4_o (w_11),
         .c4_o (w_12),
         .d5_o (w_13),
         .c5_o (w_14),
         .d6_o (w_15),
         .c6_o (w_16),
         .d1_o (w_17),
         .c1_o (w_18),
         .d7_o (w_19),
         .c7_o (w_20),
         .d0_o (w_21),
         .c0_o (w_22)
     );

imem blk3661_21 (
         .data_o (w_2),
         .address_i (w_5),
         .oe_i (w_6)
     );


endmodule
