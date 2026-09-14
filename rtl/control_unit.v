// ============================================================================
// control_unit.v - Central FSM. Decodes instruction class from `ir` (full
// {opcode,funct3,funct7} tuple matching, not opcode alone - §9.1), sequences
// the 6 states, and generates every datapath control signal.
//
// States (§8.1): RESET, FETCH, DECODE, EXECUTE, MEMORY, WRITEBACK.
// Cycle counts (§8.3): branch=3, store=4, ALU/mul/crc/jump/fence/
// ecall/ebreak/illegal=4, load=5.
//
// Every combinational output is gated by rst_i directly (not only via the
// state register having reached RESET) so an in-flight operation is
// aborted the same cycle reset asserts, not one cycle later (§9.1 fix).
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
    (* keep *) output wire sys_event_o,

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
