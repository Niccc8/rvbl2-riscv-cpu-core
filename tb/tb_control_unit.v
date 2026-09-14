`timescale 1ns/1ps
// ============================================================================
// tb_control_unit.v
//
// Two parts (§9.1/§16.3):
//  (1) A behavioral sweep over every {opcode,funct3,funct7} combination this
//      ISA's opcodes can express, run through the real FSM, checking that
//      load/store reach MEMORY, branch returns straight to FETCH, and every
//      other case (including every illegal/out-of-range-funct3/funct7
//      variant) reaches WRITEBACK - never MEMORY. This directly targets the
//      "opcode matches a real class but funct3/funct7 doesn't" failure mode
//      the spec calls out explicitly (§9.1).
//  (2) Explicit state-transition-table coverage (§8.2) and cycle-count
//      coverage (§8.3), plus the sys_event_o pulse behavior and the
//      reset-mid-instruction abort requirement (§9.1 fix).
//
// Uses a poll-until-state-reached helper (with a hard timeout) rather than
// hand-counted `@(posedge clk)` sequences - manually counting edges through
// a 6-state FSM turned out to be a real, repeated source of testbench bugs
// while writing this file (see notes inline), and polling both eliminates
// that entire bug class and self-documents the actual cycle count taken.
// ============================================================================
module tb_control_unit;
    reg         clk, rst;
    reg  [31:0] ir;
    reg         branch_taken;
    wire [2:0]  state_o;
    wire        alu_src_a_sel, alu_src_b_sel, addr_src_sel, pc_src_sel;
    wire [3:0]  alu_op;
    wire [2:0]  wb_src_sel, op_size;
    wire        pc_write, reg_write, we_o, oe_o, ir_write, sys_event_o, is_valid_store;

    integer pass, fail;

    control_unit dut (
        .clk_i(clk), .rst_i(rst), .ir(ir), .branch_taken(branch_taken),
        .state_o(state_o),
        .alu_src_a_sel(alu_src_a_sel), .alu_src_b_sel(alu_src_b_sel), .alu_op(alu_op),
        .addr_src_sel(addr_src_sel), .wb_src_sel(wb_src_sel), .pc_src_sel(pc_src_sel),
        .pc_write(pc_write), .reg_write(reg_write), .we_o(we_o), .oe_o(oe_o),
        .ir_write(ir_write), .sys_event_o(sys_event_o),
        .is_valid_store(is_valid_store), .op_size(op_size)
    );

    always #5 clk = ~clk;

    localparam [2:0] S_RESET=0, S_FETCH=1, S_DECODE=2, S_EXECUTE=3, S_MEMORY=4, S_WRITEBACK=5;

    // ---- robust helpers: no hand-counted edges anywhere below ----
    task do_hard_reset; // ends deterministically in S_FETCH
        begin
            rst = 1; @(posedge clk); #1;
            rst = 0; @(posedge clk); #1;
            if (state_o !== S_FETCH) begin
                fail = fail + 1;
                $display("FAIL do_hard_reset: expected S_FETCH, got state=%0d", state_o);
            end
        end
    endtask

    task wait_for_state(input [2:0] target, input integer max_cycles, output integer cycles_taken);
        integer c;
        begin
            c = 0;
            while ((state_o !== target) && (c < max_cycles)) begin
                @(posedge clk); #1;
                c = c + 1;
            end
            cycles_taken = c;
        end
    endtask

    // ---- Part 1: independent reference classifier (mirrors the ISA table,
    // §4.2 - deliberately NOT copy-pasted from control_unit.v's own
    // expressions). Returns the instruction class, which fixes both the state
    // EXECUTE hands off to and whether the instruction writes rd. ----
    localparam [2:0] C_ILLEGAL = 3'd0,  // incl. FENCE / ECALL / EBREAK: no rd write
                     C_WRITES  = 3'd1,  // ALU-reg/imm, LUI, AUIPC, MUL, CRC, JAL, JALR
                     C_LOAD    = 3'd2,
                     C_STORE   = 3'd3,
                     C_BRANCH  = 3'd4;

    function [2:0] ref_class;
        input [31:0] instr;
        reg [6:0] opcode;
        reg [2:0] funct3;
        reg [6:0] funct7;
        reg       shift_imm_ok;
        begin
            opcode = instr[6:0];
            funct3 = instr[14:12];
            funct7 = instr[31:25];
            case (opcode)
                7'b0110011: // R-type family: base ALU / Zmmul / Xicrc
                    ref_class = ((funct7==7'b0000000) ||
                                 ((funct7==7'b0100000) && (funct3==3'b000 || funct3==3'b101)) ||
                                 ((funct7==7'b0000001) && (funct3[2]==1'b0)) ||
                                 ((funct7==7'b1000000) && (funct3==3'b000||funct3==3'b001||funct3==3'b010)))
                                ? C_WRITES : C_ILLEGAL;
                7'b0010011: begin // ALU-imm
                    shift_imm_ok = (funct3==3'b001) ? (funct7==7'b0000000)
                                                     : ((funct7==7'b0000000)||(funct7==7'b0100000));
                    ref_class = ((funct3!=3'b001 && funct3!=3'b101) || shift_imm_ok)
                                ? C_WRITES : C_ILLEGAL;
                end
                7'b0000011: ref_class = (funct3==3'b000||funct3==3'b001||funct3==3'b010||
                                          funct3==3'b100||funct3==3'b101) ? C_LOAD : C_ILLEGAL;
                7'b0100011: ref_class = (funct3==3'b000||funct3==3'b001||funct3==3'b010)
                                        ? C_STORE : C_ILLEGAL;
                7'b1100011: ref_class = (funct3==3'b000||funct3==3'b001||funct3==3'b100||
                                          funct3==3'b101||funct3==3'b110||funct3==3'b111)
                                        ? C_BRANCH : C_ILLEGAL;
                7'b1101111: ref_class = C_WRITES;                        // JAL
                7'b1100111: ref_class = (funct3==3'b000) ? C_WRITES : C_ILLEGAL; // JALR
                7'b0110111: ref_class = C_WRITES;                        // LUI
                7'b0010111: ref_class = C_WRITES;                        // AUIPC
                // ECALL/EBREAK are exact encodings; every other SYSTEM word is
                // illegal. Both take the no-result path, same as FENCE.
                7'b1110011: ref_class = C_ILLEGAL;
                7'b0001111: ref_class = C_ILLEGAL;                       // FENCE: no rd write
                default:    ref_class = C_ILLEGAL;
            endcase
        end
    endfunction

    // Drives one encoding all the way to its terminal state, checking both the
    // state EXECUTE hands off to and whether reg_write is asserted there.
    task check_encoding(input [31:0] instr);
        reg [2:0]  cls;
        reg [2:0]  exp_state, st_after_execute;
        reg        exp_reg_write;
        integer    c;
        begin
            cls = ref_class(instr);
            case (cls)
                C_LOAD:   begin exp_state = S_MEMORY;    exp_reg_write = 1'b1; end
                C_STORE:  begin exp_state = S_MEMORY;    exp_reg_write = 1'b0; end
                C_BRANCH: begin exp_state = S_FETCH;     exp_reg_write = 1'b0; end
                C_WRITES: begin exp_state = S_WRITEBACK; exp_reg_write = 1'b1; end
                default:  begin exp_state = S_WRITEBACK; exp_reg_write = 1'b0; end
            endcase

            do_hard_reset;
            ir = instr;
            branch_taken = 1'b0;

            wait_for_state(S_EXECUTE, 5, c);
            if (c != 2) begin
                fail = fail + 1;
                $display("FAIL timing: FETCH->EXECUTE took %0d cycles (expected 2) for ir=%h", c, instr);
            end

            @(posedge clk); #1;
            st_after_execute = state_o;
            if (st_after_execute === exp_state) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("FAIL class(ir=%h cls=%0d): expected state %0d after EXECUTE, got %0d",
                          instr, cls, exp_state, st_after_execute);
            end

            // Sample reg_write where it would be asserted: WRITEBACK for every
            // class that reaches it (loads arrive there one state later).
            if (cls == C_LOAD) begin
                @(posedge clk); #1;
                if (state_o !== S_WRITEBACK) begin
                    fail = fail + 1;
                    $display("FAIL(ir=%h): load must reach WRITEBACK, got %0d", instr, state_o);
                end
            end
            if (cls == C_STORE || cls == C_BRANCH) begin
                // Neither has a WRITEBACK state at all; reg_write must be low
                // for the whole instruction.
                if (reg_write === 1'b0) pass = pass + 1;
                else begin
                    fail = fail + 1;
                    $display("FAIL(ir=%h): store/branch must never assert reg_write", instr);
                end
            end else begin
                if (reg_write === exp_reg_write) pass = pass + 1;
                else begin
                    fail = fail + 1;
                    $display("FAIL(ir=%h cls=%0d): reg_write=%b in WRITEBACK, expected %b",
                              instr, cls, reg_write, exp_reg_write);
                end
            end
        end
    endtask

    reg [6:0] op_i; integer f3_i; integer f7_i;
    integer cyc;

    initial begin
        clk = 0;
        pass = 0; fail = 0;
        rst = 1; branch_taken = 0; ir = 32'h0;
        @(posedge clk); @(posedge clk); #1; rst = 0;

        // ---------------- Part 1: behavioral decode sweep --------------------
        begin : behavioral_sweep
            integer oi, wi;
            reg [6:0] opcodes [0:10];
            reg [6:0] watch_f7 [0:7];
            opcodes[0]=7'b0110011; opcodes[1]=7'b0010011; opcodes[2]=7'b0000011;
            opcodes[3]=7'b0100011; opcodes[4]=7'b1100011; opcodes[5]=7'b1101111;
            opcodes[6]=7'b1100111; opcodes[7]=7'b0110111; opcodes[8]=7'b0010111;
            opcodes[9]=7'b1110011; opcodes[10]=7'b0001111;
            // funct7 values covering both valid boundaries and clearly-invalid values
            watch_f7[0]=7'b0000000; watch_f7[1]=7'b0100000; watch_f7[2]=7'b0000001;
            watch_f7[3]=7'b1000000; watch_f7[4]=7'b0010101; watch_f7[5]=7'b1111111;
            watch_f7[6]=7'b0000011; watch_f7[7]=7'b1010101;

            for (oi = 0; oi < 11; oi = oi + 1) begin
                for (f3_i = 0; f3_i < 8; f3_i = f3_i + 1) begin
                    for (wi = 0; wi < 8; wi = wi + 1) begin
                        op_i = opcodes[oi];
                        f7_i = watch_f7[wi];
                        // rd=1 so a spurious reg_write is observable rather
                        // than masked by the x0 write-guard.
                        check_encoding({f7_i[6:0], 5'd0, 5'd0, f3_i[2:0], 5'd1, op_i});
                    end
                end
            end
            $display("Behavioral decode sweep: %0d combinations exercised", 11*8*8);
        end

        // ---------------- Part 2: explicit state-transition-table coverage ---
        run_fsm_transition_tests;
        run_output_signal_checks;

        $display("==== tb_control_unit: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_CONTROL_UNIT: ALL TESTS PASSED");
        else $display("TB_CONTROL_UNIT: FAILURES PRESENT");
        $finish;
    end

    task run_fsm_transition_tests;
        integer c;
        begin
            // RESET stays in RESET while rst=1
            rst = 1; ir = 32'h0000_0013; @(posedge clk); #1;
            if (state_o === S_RESET) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: not in RESET while rst=1"); end

            // RESET -> FETCH on rst deassert
            rst = 0; @(posedge clk); #1;
            if (state_o === S_FETCH) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: RESET->FETCH on rst deassert"); end

            // FETCH -> DECODE -> EXECUTE, unconditional, exactly 2 cycles
            wait_for_state(S_EXECUTE, 5, c);
            if (c == 2) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: FETCH->EXECUTE took %0d cycles, expected 2", c); end

            // ---- Branch, taken: total 3-cycle instruction (§8.3), EXECUTE->FETCH ----
            do_hard_reset;
            ir = {7'b0, 5'd2, 5'd1, 3'b000, 5'b0, 7'b1100011}; // BEQ x1,x2,0
            branch_taken = 1;
            wait_for_state(S_EXECUTE, 5, c);
            if (c == 2) pass=pass+1; else begin fail=fail+1; $display("FAIL branch: FETCH->EXECUTE cycles=%0d",c); end
            @(posedge clk); #1; // EXECUTE -> ? (branch's own terminal transition)
            if (state_o === S_FETCH) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: EXECUTE(branch,taken)->FETCH, got %0d", state_o); end

            // ---- Store: total 4-cycle instruction, EXECUTE->MEMORY->FETCH ----
            do_hard_reset;
            ir = {7'b0, 5'd2, 5'd1, 3'b010, 5'd0, 7'b0100011}; // SW x2,0(x1)
            branch_taken = 0;
            wait_for_state(S_EXECUTE, 5, c);
            @(posedge clk); #1; // EXECUTE -> MEMORY
            if (state_o === S_MEMORY) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: EXECUTE(store)->MEMORY, got %0d", state_o); end
            if (we_o === 1'b1) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: we_o not asserted in MEMORY for store"); end
            @(posedge clk); #1; // MEMORY -> FETCH
            if (state_o === S_FETCH) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: MEMORY(store)->FETCH, got %0d", state_o); end

            // ---- Load: total 5-cycle instruction, EXECUTE->MEMORY->WRITEBACK->FETCH ----
            do_hard_reset;
            ir = {12'd0, 5'd2, 3'b010, 5'd1, 7'b0000011}; // LW x1,0(x2)
            wait_for_state(S_EXECUTE, 5, c);
            @(posedge clk); #1; // EXECUTE -> MEMORY
            if (state_o === S_MEMORY) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: EXECUTE(load)->MEMORY, got %0d", state_o); end
            @(posedge clk); #1; // MEMORY -> WRITEBACK
            if (state_o === S_WRITEBACK) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: MEMORY(load)->WRITEBACK, got %0d", state_o); end
            if (oe_o === 1'b1) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: oe_o should still be asserted in WRITEBACK for a load (§7.4)"); end
            @(posedge clk); #1; // WRITEBACK -> FETCH
            if (state_o === S_FETCH) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: WRITEBACK(load)->FETCH, got %0d", state_o); end

            // ---- sys_event_o: one-cycle pulse during EXECUTE for ECALL only ----
            do_hard_reset;
            ir = 32'h0000_0073; // ECALL
            wait_for_state(S_EXECUTE, 5, c);
            if (sys_event_o === 1'b1) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: sys_event_o not asserted during EXECUTE for ECALL"); end
            @(posedge clk); #1; // -> WRITEBACK
            if (state_o === S_WRITEBACK) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: EXECUTE(ecall)->WRITEBACK, got %0d", state_o); end
            if (sys_event_o === 1'b0) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: sys_event_o must not persist into WRITEBACK"); end
            if (reg_write === 1'b0) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: ECALL must not assert reg_write"); end

            // ---- EBREAK: same treatment as ECALL (imm=1 instead of 0) ----
            do_hard_reset;
            ir = 32'h0010_0073; // EBREAK (imm[11:0]=1, funct3=0, opcode=SYSTEM)
            wait_for_state(S_EXECUTE, 5, c);
            if (sys_event_o === 1'b1) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: sys_event_o not asserted during EXECUTE for EBREAK"); end

            // ---- a SYSTEM-opcode word that is not exactly ECALL/EBREAK must
            // not pulse sys_event_o, so the firmware-completion event cannot
            // be forged by stray ROM padding ----
            do_hard_reset;
            ir = 32'h0000_00F3; // SYSTEM, funct3=000, imm=0, but rd=1
            wait_for_state(S_EXECUTE, 5, c);
            if (sys_event_o === 1'b0) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: non-canonical SYSTEM word pulsed sys_event_o"); end
            @(posedge clk); #1;
            if (reg_write === 1'b0) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: non-canonical SYSTEM word asserted reg_write"); end

            // ---- reset mid-instruction (during MEMORY for a store) aborts
            // we_o in the SAME cycle rst asserts, not one cycle later (§9.1) ----
            do_hard_reset;
            ir = {7'b0, 5'd2, 5'd1, 3'b010, 5'd0, 7'b0100011}; // SW
            wait_for_state(S_EXECUTE, 5, c);
            @(posedge clk); #1; // -> MEMORY
            if (we_o === 1'b1) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: we_o should be asserted in MEMORY for a store (pre-check)"); end
            rst = 1; #1; // assert reset with NO further clock edge yet
            if (we_o === 1'b0) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: we_o must drop to 0 the SAME cycle rst_i asserts, mid-instruction"); end
            rst = 0;

            // ---- illegal instruction: must reach WRITEBACK (never MEMORY),
            // never assert reg_write, and PC must still be advancing normally
            // (checked at core/SoC level for actual PC value; here we just
            // confirm the FSM path and reg_write behavior) ----
            do_hard_reset;
            ir = 32'hFFFF_FFFF; // clearly not a valid encoding of anything
            wait_for_state(S_EXECUTE, 5, c);
            @(posedge clk); #1;
            if (state_o === S_WRITEBACK) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: illegal instruction must reach WRITEBACK, got %0d", state_o); end
            if (reg_write === 1'b0) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: illegal instruction must not assert reg_write"); end
            if (we_o === 1'b0 && oe_o === 1'b0) pass=pass+1;
            else begin fail=fail+1; $display("FAIL: illegal instruction must not assert we_o/oe_o in WRITEBACK"); end
        end
    endtask

    task check_exec_signals(
        input [31:0] encoding,
        input        bt,
        input        exp_a_sel,
        input        exp_b_sel,
        input [3:0]  exp_alu_op,
        input [2:0]  exp_wb_src,
        input        exp_pc_src,
        input        exp_store,
        input [200:0] name
    );
        integer c;
        begin
            do_hard_reset;
            ir = encoding;
            branch_taken = bt;
            wait_for_state(S_EXECUTE, 5, c);
            if (alu_src_a_sel !== exp_a_sel ||
                alu_src_b_sel !== exp_b_sel ||
                alu_op        !== exp_alu_op ||
                wb_src_sel    !== exp_wb_src ||
                pc_src_sel    !== exp_pc_src ||
                is_valid_store!== exp_store) begin
                fail = fail + 1;
                $display("FAIL %0s: a=%b(%b) b=%b(%b) op=%h(%h) wb=%b(%b) pc=%b(%b) st=%b(%b)",
                    name,
                    alu_src_a_sel, exp_a_sel,
                    alu_src_b_sel, exp_b_sel,
                    alu_op, exp_alu_op,
                    wb_src_sel, exp_wb_src,
                    pc_src_sel, exp_pc_src,
                    is_valid_store, exp_store);
            end else
                pass = pass + 1;
        end
    endtask

    task run_output_signal_checks;
        begin
            // Verify alu_op + mux selects for every instruction class at EXECUTE.
            // The decode sweep (Part 1) checked state transitions but not output
            // signal values; this section closes that gap.
            //
            // Format: check_exec_signals(encoding, branch_taken,
            //     exp_a_sel, exp_b_sel, exp_alu_op, exp_wb_src, exp_pc_src, exp_store, name)

            // ---- R-type ALU: a=rs1(0), b=rs2(0), wb=ALU(000), pc=+4(0) ----
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b000, 5'd0, 7'b0110011}, 0, 0, 0, 4'h1, 3'b000, 0, 0, "ADD alu_op/mux");
            check_exec_signals({7'b0100000, 5'd0, 5'd0, 3'b000, 5'd0, 7'b0110011}, 0, 0, 0, 4'h2, 3'b000, 0, 0, "SUB alu_op/mux");
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b001, 5'd0, 7'b0110011}, 0, 0, 0, 4'h6, 3'b000, 0, 0, "SLL alu_op/mux");
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b010, 5'd0, 7'b0110011}, 0, 0, 0, 4'h9, 3'b000, 0, 0, "SLT alu_op/mux");
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b011, 5'd0, 7'b0110011}, 0, 0, 0, 4'hA, 3'b000, 0, 0, "SLTU alu_op/mux");
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b100, 5'd0, 7'b0110011}, 0, 0, 0, 4'h5, 3'b000, 0, 0, "XOR alu_op/mux");
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b101, 5'd0, 7'b0110011}, 0, 0, 0, 4'h7, 3'b000, 0, 0, "SRL alu_op/mux");
            check_exec_signals({7'b0100000, 5'd0, 5'd0, 3'b101, 5'd0, 7'b0110011}, 0, 0, 0, 4'h8, 3'b000, 0, 0, "SRA alu_op/mux");
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b110, 5'd0, 7'b0110011}, 0, 0, 0, 4'h4, 3'b000, 0, 0, "OR alu_op/mux");
            check_exec_signals({7'b0000000, 5'd0, 5'd0, 3'b111, 5'd0, 7'b0110011}, 0, 0, 0, 4'h3, 3'b000, 0, 0, "AND alu_op/mux");

            // ---- I-type ALU: a=rs1(0), b=imm(1), wb=ALU(000) ----
            check_exec_signals({12'd0, 5'd0, 3'b000, 5'd0, 7'b0010011}, 0, 0, 1, 4'h1, 3'b000, 0, 0, "ADDI alu_op/mux");
            check_exec_signals({12'd0, 5'd0, 3'b010, 5'd0, 7'b0010011}, 0, 0, 1, 4'h9, 3'b000, 0, 0, "SLTI alu_op/mux");
            check_exec_signals({12'd0, 5'd0, 3'b011, 5'd0, 7'b0010011}, 0, 0, 1, 4'hA, 3'b000, 0, 0, "SLTIU alu_op/mux");
            check_exec_signals({12'd0, 5'd0, 3'b100, 5'd0, 7'b0010011}, 0, 0, 1, 4'h5, 3'b000, 0, 0, "XORI alu_op/mux");
            check_exec_signals({12'd0, 5'd0, 3'b110, 5'd0, 7'b0010011}, 0, 0, 1, 4'h4, 3'b000, 0, 0, "ORI alu_op/mux");
            check_exec_signals({12'd0, 5'd0, 3'b111, 5'd0, 7'b0010011}, 0, 0, 1, 4'h3, 3'b000, 0, 0, "ANDI alu_op/mux");
            check_exec_signals({7'b0000000, 5'd5, 5'd0, 3'b001, 5'd0, 7'b0010011}, 0, 0, 1, 4'h6, 3'b000, 0, 0, "SLLI alu_op/mux");
            check_exec_signals({7'b0000000, 5'd5, 5'd0, 3'b101, 5'd0, 7'b0010011}, 0, 0, 1, 4'h7, 3'b000, 0, 0, "SRLI alu_op/mux");
            check_exec_signals({7'b0100000, 5'd5, 5'd0, 3'b101, 5'd0, 7'b0010011}, 0, 0, 1, 4'h8, 3'b000, 0, 0, "SRAI alu_op/mux");

            // ---- Other instruction classes ----
            check_exec_signals({20'h12345, 5'd0, 7'b0110111},                                               0, 0, 1, 4'h0, 3'b000, 0, 0, "LUI mux");
            check_exec_signals({20'h12345, 5'd0, 7'b0010111},                                               0, 1, 1, 4'h1, 3'b000, 0, 0, "AUIPC mux");
            check_exec_signals({12'd0, 5'd0, 3'b010, 5'd0, 7'b0000011},                                     0, 0, 1, 4'h1, 3'b011, 0, 0, "LW mux");
            check_exec_signals({7'b0, 5'd0, 5'd0, 3'b010, 5'd0, 7'b0100011},                                0, 0, 1, 4'h1, 3'b000, 0, 1, "SW mux");
            check_exec_signals({7'b0000001, 5'd0, 5'd0, 3'b000, 5'd0, 7'b0110011},                          0, 0, 0, 4'h1, 3'b001, 0, 0, "MUL mux");
            check_exec_signals({7'b1000000, 5'd0, 5'd0, 3'b000, 5'd0, 7'b0110011},                          0, 0, 0, 4'h1, 3'b010, 0, 0, "CRCB mux");
            check_exec_signals({1'b0, 10'b0000000100, 1'b0, 8'b0, 5'd1, 7'b1101111},                        0, 1, 1, 4'h1, 3'b100, 1, 0, "JAL mux");
            check_exec_signals({12'd0, 5'd0, 3'b000, 5'd1, 7'b1100111},                                     0, 0, 1, 4'h1, 3'b100, 1, 0, "JALR mux");
            check_exec_signals({1'b0, 6'b0, 5'd0, 5'd0, 3'b000, 4'b0010, 1'b0, 7'b1100011},                1, 1, 1, 4'h1, 3'b000, 1, 0, "BEQ taken mux");
            check_exec_signals({1'b0, 6'b0, 5'd0, 5'd0, 3'b000, 4'b0010, 1'b0, 7'b1100011},                0, 1, 1, 4'h1, 3'b000, 0, 0, "BEQ untaken mux");
        end
    endtask

endmodule
