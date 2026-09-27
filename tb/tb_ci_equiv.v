`timescale 1ns/1ps
// ============================================================================
// tb_ci_equiv.v - the ChipInventor mirror (chipinventor/ci_top.v, two canvas
// projects) against this repository's hierarchical Stage 3 design (rtl/),
// cycle for cycle, on every program either of them runs.
//
// The two are built differently: rtl/top.v keeps riscv_core, inline muxes,
// a $readmemh ROM and the brief's inout [7:0] pins_io; ci_top.v is the canvas
// structure - flat SoC project, mux blocks, ir_fields, a case-ROM, gpio_bits
// and eight 1-bit Inout Pins written as the platform writes them. This proves
// they are the same machine, pin for pin.
//
// Seven phases, each entered by writing the PC during reset, with the same
// stimulus applied to both chips:
//   official firmware and the supplementary program (Phase 2 code)
//   gpio_listing, gpio_fixed  pin 0 toggled by the testbench
//   echo_listing, echo_fixed  "Hello, RVBL-2!" sent into rx_i
//   periph_regress            each chip's tx_o looped to its own rx_i,
//                             pins 7:4 driven 1010
//
// Compared every cycle: FSM state, PC, IR, all 32 GPRs, the memory
// transaction (address, store data, strobes), tx_o, gpio_o, gpio_oe and the
// level on all eight pins. Every pin also has a weak pull, identical on both
// chips, driven by bit n of a free-running counter: it flips, so a pin that
// floats and a pin that drives can never look alike (a fixed pull hides a C/D
// swap on an Inout Pin), and it differs per pin, so two crossed pad inputs
// show up in any DATAIN the software reads.
//
// Both UARTs run at 16 clocks per bit for speed: rtl/ by its top parameters,
// the mirror by defparam on its uart instance. The divisor logic itself is
// verified at the real 263 by tb_uart.v and by the platform testbench.
//
// Built by scripts/run_all.sh:
//   python chipinventor/scripts/make_ref.py --src rtl --prefix s3ref_ \
//          --out build/s3ref_renamed.v
//   iverilog ... -Ptb_ci_equiv.ROM_WORDS=<words in rom_image.hex> \
//          chipinventor/blocks/*.v (not imem_mock) chipinventor/ci_top.v \
//          build/s3ref_renamed.v tb/tb_ci_equiv.v
// ============================================================================
module tb_ci_equiv;
    parameter ROM_WORDS = 1445;
    localparam [31:0] SUPP_BASE = 32'h00400800;
    localparam [31:0] GPIO_LISTING = 32'h00401000, GPIO_FIXED = 32'h00401100,
                      ECHO_LISTING = 32'h00401200, ECHO_FIXED = 32'h00401300,
                      PERIPH_REGRESS = 32'h00401400;
    localparam        NUM_CHECKS = 24;
    localparam [31:0] DONE_MARK  = 32'h600D_C0DE;
    localparam real   CLK_NS = 10.0;
    localparam integer NB    = 16;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---------------- Shared stimulus --------------------------------------
    reg  [7:0] tb_oe = 0, tb_val = 0;
    reg  [7:0] pull = 0;
    reg        rx_drv = 1, loopback = 0;

    // ---------------- The ChipInventor mirror -------------------------------
    wire [7:0] pins_c;
    wire       tx_c;
    wire       rx_c = loopback ? tx_c : rx_drv;
    top dut_ci (
        .clk_i(clk), .rst_i(rst),
        .pins_io_0(pins_c[0]), .pins_io_1(pins_c[1]), .pins_io_2(pins_c[2]), .pins_io_3(pins_c[3]),
        .pins_io_4(pins_c[4]), .pins_io_5(pins_c[5]), .pins_io_6(pins_c[6]), .pins_io_7(pins_c[7]),
        .tx_o(tx_c), .rx_i(rx_c));
    defparam dut_ci.u_soc.u_uart.CLK_FREQ_HZ = 1600000;
    defparam dut_ci.u_soc.u_uart.BAUD_RATE   = 100000;

    // ---------------- The hierarchical design (rtl/, renamed s3ref_*) ------
    wire [7:0] pins_r;
    wire       tx_r;
    wire       rx_r = loopback ? tx_r : rx_drv;
    s3ref_top #(.IMEM_WORDS(ROM_WORDS), .DMEM_WORDS(2048),
                .IMEM_INIT_FILE("chipinventor/build/rom_image.hex"),
                .UART_CLK_FREQ_HZ(1600000), .UART_BAUD_RATE(100000)) dut_ref (
        .clk_i(clk), .rst_i(rst), .pins_io(pins_r), .tx_o(tx_r), .rx_i(rx_r));

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : g_pin
            assign pins_c[g] = tb_oe[g] ? tb_val[g] : 1'bz;
            assign pins_r[g] = tb_oe[g] ? tb_val[g] : 1'bz;
            assign (weak0, weak1) pins_c[g] = pull[g];
            assign (weak0, weak1) pins_r[g] = pull[g];
        end
    endgenerate

    integer pass = 0, fail = 0, shown = 0, cyc, i;
    reg [8*24-1:0] phase;

    task cmp(input [31:0] a, input [31:0] b, input [8*20-1:0] what);
        begin
            if (a === b) pass = pass + 1;
            else begin
                fail = fail + 1;
                if (shown < 20) begin
                    shown = shown + 1;
                    $display("DIVERGE %0s cyc=%0d %0s: ci=%h rtl=%h", phase, cyc, what, a, b);
                end
            end
        end
    endtask

    // Every cycle, while out of reset: the complete visible state of both.
    always @(posedge clk) if (!rst) begin : compare
        #1;
        cmp({29'b0, dut_ci.u_soc.u_ctrl.state}, {29'b0, dut_ref.u_core.u_ctrl.state}, "state");
        cmp(dut_ci.u_soc.u_pc.pc, dut_ref.u_core.u_pc.pc, "pc");
        cmp(dut_ci.u_soc.u_ir.ir, dut_ref.u_core.u_ir.ir, "ir");
        cmp(dut_ci.u_soc.core_address, dut_ref.core_address, "address");
        cmp(dut_ci.u_soc.core_store_data, dut_ref.core_store_data, "store_data");
        cmp({26'b0, dut_ci.u_soc.core_bw, dut_ci.u_soc.core_we, dut_ci.u_soc.core_oe},
            {26'b0, dut_ref.core_bw, dut_ref.core_we, dut_ref.core_oe}, "bw/we/oe");
        for (i = 0; i < 32; i = i + 1)
            cmp(dut_ci.u_soc.u_rf.regs[i], dut_ref.u_core.u_rf.regs[i], "gpr");
        cmp({31'b0, tx_c}, {31'b0, tx_r}, "tx_o");
        cmp({16'b0, dut_ci.gpio_oe, dut_ci.gpio_o}, {16'b0, dut_ref.gpio_oe, dut_ref.gpio_o}, "gpio_oe/o");
        cmp({24'b0, pins_c}, {24'b0, pins_r}, "pins");
    end
    always @(posedge clk) pull <= pull + 8'd1;

    task enter(input [31:0] entry, input [8*24-1:0] label, input lb, input [7:0] oe, input [7:0] val);
        begin
            rst = 1; phase = label;
            loopback = lb; rx_drv = 1; tb_oe = oe; tb_val = val;
            repeat (3) @(posedge clk); #2;
            for (i = 0; i < 2048; i = i + 1) begin
                dut_ci.u_soc.u_dmem.mem[i] = 32'b0;
                dut_ref.u_dmem.mem[i] = 32'b0;
            end
            if (entry !== 32'b0) begin
                dut_ci.u_soc.u_pc.pc   = entry;
                dut_ref.u_core.u_pc.pc = entry;
            end
            cyc = 0;
            rst = 0;
        end
    endtask
    task run(input integer n);
        begin repeat (n) begin @(posedge clk); cyc = cyc + 1; end #2; end
    endtask
    task send(input [7:0] data);
        integer k;
        begin
            rx_drv = 0; #(NB * CLK_NS);
            for (k = 0; k < 8; k = k + 1) begin rx_drv = data[k]; #(NB * CLK_NS); end
            rx_drv = 1; #(NB * CLK_NS);
        end
    endtask

    reg [8*14-1:0] msg;
    integer n, before;

    initial begin
        msg = "Hello, RVBL-2!";
        if (dut_ci.u_soc.u_uart.CLKS_PER_BIT != NB || dut_ref.u_uart.CLKS_PER_BIT != NB) begin
            $display("FAIL both UARTs must run at %0d clocks per bit (ci %0d, rtl %0d)",
                     NB, dut_ci.u_soc.u_uart.CLKS_PER_BIT, dut_ref.u_uart.CLKS_PER_BIT);
            fail = fail + 1;
        end

        enter(32'h0, "official firmware", 0, 8'h00, 8'h00);
        run(5000);
        enter(SUPP_BASE, "supplementary", 0, 8'h00, 8'h00);
        run(5000);

        enter(GPIO_LISTING, "gpio_listing", 0, 8'h01, 8'h00);
        for (n = 0; n < 20; n = n + 1) begin tb_val[0] = n[0]; run(150); end
        enter(GPIO_FIXED, "gpio_fixed", 0, 8'h01, 8'h00);
        for (n = 0; n < 20; n = n + 1) begin tb_val[0] = n[0]; run(150); end

        enter(ECHO_LISTING, "echo_listing", 0, 8'h00, 8'h00);
        run(20);
        for (n = 0; n < 14; n = n + 1) begin send(msg[(13 - n) * 8 +: 8]); #(2 * NB * CLK_NS); end
        run(400);
        enter(ECHO_FIXED, "echo_fixed", 0, 8'h00, 8'h00);
        run(20);
        for (n = 0; n < 14; n = n + 1) begin send(msg[(13 - n) * 8 +: 8]); #(2 * NB * CLK_NS); end
        run(400);

        enter(PERIPH_REGRESS, "periph_regress", 1, 8'hF0, 8'hA0);
        run(8000);
        // The programs must actually have done their work, or equal-but-idle
        // would pass: periph_regress's marker and checks on both chips.
        cmp(dut_ci.u_soc.u_dmem.mem[NUM_CHECKS], DONE_MARK, "ci done mark");
        cmp(dut_ref.u_dmem.mem[NUM_CHECKS], DONE_MARK, "rtl done mark");
        before = 0;
        for (n = 0; n < NUM_CHECKS; n = n + 1)
            if (dut_ci.u_soc.u_dmem.mem[n] !== 0 || dut_ref.u_dmem.mem[n] !== 0) before = before + 1;
        cmp(before, 0, "periph_regress checks");

        rst = 1; #20;
        $display("==== tb_ci_equiv: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_CI_EQUIV: ALL TESTS PASSED (ci_top matches rtl/ on all 7 programs)");
        else           $display("TB_CI_EQUIV: FAILURES PRESENT");
        $finish;
    end
endmodule
