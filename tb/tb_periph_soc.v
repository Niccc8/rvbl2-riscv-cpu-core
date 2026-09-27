`timescale 1ns/1ps
// ============================================================================
// tb_periph_soc.v - Stage 3 SoC integration (spec §10.2): the core runs real
// programs against the GPIO and UART through the full memory system.
//
//   S1 GPIO listing (Block Guide §1.3.2), LITERAL: DATADIR = 0x02, P1 stays low
//   S2 GPIO listing completed with slli: P1 follows P0 within a bounded latency
//   S3 echo listing (§2.3.3), LITERAL: every byte received, nothing transmitted
//   S4 echo completed with TRANSMIT: a true echo, byte-exact, with gaps and
//      back-to-back at 0, +2 and -2 % baud error; and at the real ASIC divisor
//   S5 periph_regress.s: 24 self-checked register behaviours, tx_o looped back
//
// Every test also runs two continuous monitors:
//   * contention: the testbench and the SoC never drive the same pin, and a
//     pin the SoC does not enable is never driven by it
//   * phantom bytes: the far-end decoder flags any malformed frame on tx_o
//
// Programs are assembled by scripts/run_all.sh into build/stage3/*.hex and
// loaded into the ROM at run time, so one elaboration runs them all.
// ============================================================================
module tb_periph_soc;
    localparam real CLK_NS  = 10.0;
    localparam integer NB   = 16;                  // fast SoC: clocks per bit
    localparam integer NR   = 263;                 // real SoC: 30303030 Hz / 115200
    localparam integer NUM_CHECKS = 24;            // periph_regress.s
    localparam [31:0]  DONE_MARK  = 32'h600D_C0DE;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---------------- DUTs ---------------------------------------------------
    wire [7:0] pins;
    reg  [7:0] tb_oe = 0, tb_val = 0;
    reg        rx_drv = 1, loopback = 0;
    wire       tx;
    wire       rx = loopback ? tx : rx_drv;

    top #(.IMEM_WORDS(512), .DMEM_WORDS(2048), .IMEM_INIT_FILE(""),
          .UART_CLK_FREQ_HZ(1600000), .UART_BAUD_RATE(100000)) dut (
        .clk_i(clk), .rst_i(rst), .pins_io(pins), .tx_o(tx), .rx_i(rx));

    // The real divisor, for one echo run.
    wire [7:0] pins_r;
    reg        rx_r = 1;
    wire       tx_r;
    top #(.IMEM_WORDS(512), .DMEM_WORDS(2048), .IMEM_INIT_FILE("")) dut_r (
        .clk_i(clk), .rst_i(rst), .pins_io(pins_r), .tx_o(tx_r), .rx_i(rx_r));

    // Pin model: the testbench drives a pin only where tb_oe is set; every
    // other pin has a weak pull-down, so an undriven input reads 0, never z.
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : g_pin
            assign pins[g] = tb_oe[g] ? tb_val[g] : 1'bz;
            pulldown (pins[g]);
            pulldown (pins_r[g]);
        end
    endgenerate

    integer pass = 0, fail = 0, i, j;
    integer contention = 0, misdrive = 0, frame_errs = 0;
    reg [31:0] v;

    task check(input [31:0] got, input [31:0] exp, input [8*80-1:0] name);
        begin
            if (got === exp) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL %0s: got %h expected %h", name, got, exp); end
        end
    endtask

    // ---------------- Monitors ------------------------------------------------
    always @(posedge clk) if (!rst) begin : pin_monitor
        integer p;   // private: the test sequence has its own loop variables
        for (p = 0; p < 8; p = p + 1) begin
            if (dut.gpio_oe[p] && tb_oe[p]) contention = contention + 1;
            if (!tb_oe[p] && pins[p] !== (dut.gpio_oe[p] ? dut.gpio_o[p] : 1'b0)) misdrive = misdrive + 1;
        end
    end

    // Far-end decoder on tx_o: records every frame and flags bad stop bits.
    reg [7:0] cap [0:127];
    integer   ncap = 0;
    always begin : tx_decoder
        integer k; reg [7:0] d;
        @(negedge tx);
        if (!rst) begin
            #(NB * CLK_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin d[k] = tx; #(NB * CLK_NS); end
            if (tx !== 1'b1) frame_errs = frame_errs + 1;
            cap[ncap] = d; ncap = ncap + 1;
        end
    end
    reg [7:0] cap_r [0:127];
    integer   ncap_r = 0;
    always begin : tx_decoder_real
        integer k; reg [7:0] d;
        @(negedge tx_r);
        if (!rst) begin
            #(NR * CLK_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin d[k] = tx_r; #(NR * CLK_NS); end
            if (tx_r !== 1'b1) frame_errs = frame_errs + 1;
            cap_r[ncap_r] = d; ncap_r = ncap_r + 1;
        end
    end

    // RXDONE must be clear whenever a new byte completes, i.e. software kept
    // up and nothing was overrun.
    integer overruns = 0;
    always @(posedge clk) if (!rst && dut.u_uart.rx_done && dut.u_uart.rxdone) overruns = overruns + 1;
    always @(posedge clk) if (!rst && dut_r.u_uart.rx_done && dut_r.u_uart.rxdone) overruns = overruns + 1;

    // ---------------- Harness -------------------------------------------------
    task load(input [8*64-1:0] hexfile);
        begin
            rst = 1; loopback = 0; rx_drv = 1; rx_r = 1; tb_oe = 0; tb_val = 0;
            repeat (3) @(posedge clk); #1;
            for (i = 0; i < 512; i = i + 1) begin dut.u_imem.rom[i] = 0; dut_r.u_imem.rom[i] = 0; end
            for (i = 0; i < 2048; i = i + 1) begin dut.u_dmem.mem[i] = 0; dut_r.u_dmem.mem[i] = 0; end
            $readmemh(hexfile, dut.u_imem.rom);
            $readmemh(hexfile, dut_r.u_imem.rom);
            ncap = 0; ncap_r = 0; overruns = 0;
        end
    endtask
    task run(input integer clks); begin rst = 0; repeat (clks) @(posedge clk); #1; end endtask

    task send(input [7:0] data, input real bit_ns, input integer real_dut);
        integer k;
        begin
            if (real_dut) rx_r = 0; else rx_drv = 0; #(bit_ns);
            for (k = 0; k < 8; k = k + 1) begin
                if (real_dut) rx_r = data[k]; else rx_drv = data[k]; #(bit_ns);
            end
            if (real_dut) rx_r = 1; else rx_drv = 1; #(bit_ns);
        end
    endtask

    reg [8*16-1:0] msg;
    localparam integer MSG_LEN = 14;
    function [7:0] ch(input integer n);   // n-th character of "Hello, RVBL-2!"
        begin ch = msg[(MSG_LEN - 1 - n) * 8 +: 8]; end
    endfunction

    // Echo one message and compare what comes back on tx_o.
    //
    // Back-to-back streams run only at the real divisor. With TXDONE set after
    // the stop bit and TRANSMIT ignored while busy (Block Guide §2.2.3), each
    // echoed byte costs one frame plus the program's ~25-cycle reaction, so the
    // echo falls behind a back-to-back sender by 25 cycles per byte. At N=263
    // that is under 1 % of a frame; at N=16 it is 16 % and overruns within a
    // few bytes - a property of the register interface, not of the RTL.
    task echo_run(input integer real_dut, input real err, input integer gap_bits,
                  input [8*56-1:0] name);
        integer n, t, nbit, got, ok;
        begin
            load("build/stage3/echo_fixed.hex"); rst = 0;
            nbit = real_dut ? NR : NB;
            repeat (20) @(posedge clk);
            for (n = 0; n < MSG_LEN; n = n + 1) begin
                send(ch(n), nbit * CLK_NS * (1.0 + err), real_dut);
                #(gap_bits * nbit * CLK_NS);
            end
            t = 0; got = 0;
            while (got < MSG_LEN && t < 3 * 10 * nbit) begin
                @(posedge clk); t = t + 1; got = real_dut ? ncap_r : ncap;
            end
            repeat (2 * 10 * nbit) @(posedge clk);
            ok = ((real_dut ? ncap_r : ncap) == MSG_LEN);
            for (n = 0; n < MSG_LEN; n = n + 1)
                if ((real_dut ? cap_r[n] : cap[n]) !== ch(n)) ok = 0;
            check(ok, 1, name);
            check(overruns, 0, "S4 no byte overrun during the echo");
        end
    endtask

    initial begin
        msg = "Hello, RVBL-2!";

        // ---------------- S1: GPIO listing, literal ----------------------------
        load("build/stage3/gpio_listing.hex");
        tb_oe = 8'h01;                          // the testbench drives P0 only
        run(200);
        check({24'b0, dut.u_gpio.datadir}, 32'h02, "S1 DATADIR = 0x02 (P0 input, P1 output)");
        v = 0;
        for (i = 0; i < 20; i = i + 1) begin
            tb_val[0] = i[0];
            for (j = 0; j < 150; j = j + 1) begin @(posedge clk); #1 if (pins[1] !== 1'b0) v = v + 1; end
            if (dut.u_gpio.dataout[0] !== tb_val[0]) v = v + 1000; // proves the loop really runs
        end
        check(v, 0, "S1 literal listing: P1 stays low while P0 toggles; DATAOUT[0] tracks P0");
        check({24'b0, dut.gpio_oe}, 32'h02, "S1 only P1 is ever driven");

        // ---------------- S2: GPIO listing completed ---------------------------
        load("build/stage3/gpio_fixed.hex");
        tb_oe = 8'h01;
        run(200);
        v = 0;
        for (i = 0; i < 20; i = i + 1) begin : s2_toggle
            integer lat;
            tb_val[0] = ~tb_val[0];
            lat = 0;
            while (pins[1] !== tb_val[0] && lat < 100) begin @(posedge clk); #1 lat = lat + 1; end
            if (lat > 45) v = v + 1;
            for (j = 0; j < 100; j = j + 1) begin @(posedge clk); #1 if (pins[1] !== tb_val[0]) v = v + 1; end
        end
        check(v, 0, "S2 completed listing: P1 follows P0 within 45 clocks and holds");

        // ---------------- S3: echo listing, literal ----------------------------
        load("build/stage3/echo_listing.hex");
        run(20);
        v = 0;
        fork
            for (i = 0; i < MSG_LEN; i = i + 1) begin send(ch(i), NB * CLK_NS, 0); #(2 * NB * CLK_NS); end
            begin : watch_tx
                for (j = 0; j < MSG_LEN * 12 * NB; j = j + 1) begin @(posedge clk); if (tx !== 1'b1) v = v + 1; end
            end
        join
        repeat (200) @(posedge clk);
        check(v, 0, "S3 literal echo: tx_o never leaves idle (TRANSMIT never set)");
        check({24'b0, dut.u_uart.txdata}, {24'b0, ch(MSG_LEN - 1)}, "S3 literal echo: TXDATA holds the last byte");
        check({31'b0, dut.u_uart.rxdone}, 0, "S3 literal echo: software consumed every byte");
        check(overruns, 0, "S3 literal echo: no byte overrun");

        // ---------------- S4: echo completed ----------------------------------
        echo_run(0,  0.00, 2, "S4 echo N=16, 0 % error, 2-bit gaps");
        echo_run(0,  0.02, 2, "S4 echo N=16, far end 2 % slow, 2-bit gaps");
        echo_run(0, -0.02, 2, "S4 echo N=16, far end 2 % fast, 2-bit gaps");
        echo_run(1,  0.00, 0, "S4 echo N=263 (115200 bps @ 30.303 MHz), back-to-back");
        echo_run(1,  0.02, 0, "S4 echo N=263, far end 2 % slow, back-to-back");
        echo_run(1, -0.02, 0, "S4 echo N=263, far end 2 % fast, back-to-back");

        // ---------------- S5: register semantics from software ------------------
        load("build/stage3/periph_regress.hex");
        loopback = 1; tb_oe = 8'hF0; tb_val = 8'hA0;
        rst = 0;
        i = 0;
        while (dut.u_dmem.mem[NUM_CHECKS] !== DONE_MARK && i < 60000) begin @(posedge clk); i = i + 1; end
        check(dut.u_dmem.mem[NUM_CHECKS], DONE_MARK, "S5 periph_regress ran to its end marker");
        v = 0;
        for (i = 0; i < NUM_CHECKS; i = i + 1)
            if (dut.u_dmem.mem[i] !== 0) begin
                v = v + 1;
                $display("FAIL S5 check %0d: actual ^ expected = %h", i + 1, dut.u_dmem.mem[i]);
            end
        check(v, 0, "S5 all 24 register checks pass");

        // ---------------- Continuous monitors -----------------------------------
        check(contention, 0, "monitor: the SoC never drove a pin the testbench drove");
        check(misdrive, 0, "monitor: every pin shows exactly its enabled driver (Figure 1)");
        check(frame_errs, 0, "monitor: every frame on tx_o had a valid stop bit");

        $display("==== tb_periph_soc: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_PERIPH_SOC: ALL TESTS PASSED");
        else           $display("TB_PERIPH_SOC: FAILURES PRESENT");
        $finish;
    end
endmodule
