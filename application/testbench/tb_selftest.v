`timescale 1ns/1ps
// ============================================================================
// tb_selftest.v - runs the firmware self-test (application/firmware/selftest,
// built by `make APP=selftest`) on rtl/top.v and checks what it does at the
// chip's pins: the HAL, the UART and GPIO drivers, Xicrc, multiply, division,
// and Chaskey-12 against its reference vectors.
//
// The testbench is the program's outside world:
//   * a UART receiver on tx_o that records every byte (and any framing error);
//   * a UART transmitter on rx_i that answers the program's "READY\n" with
//     'r' and then the little-endian word 0x12345678;
//   * pins 3:0 driven to 1010, pins 7:4 left to the chip, weak pull-downs on
//     all eight so an undriven pin reads 0.
// It stops when the core pulses sys_event_o (crt0's ECALL after main returns)
// or at a timeout, then checks the transcript and the pins.
//
// The UART runs at 16 clocks per bit (top's UART parameters) for speed; the
// divisor at the real 263 is covered by tb_uart.v and the platform testbench.
//
// Build (scripts/run_all.sh does this):
//   make -C application/firmware APP=selftest
//   iverilog -g2005 -o build/tb_selftest.vvp rtl/*.v application/testbench/tb_selftest.v
// ============================================================================
module tb_selftest;
    parameter HEX       = "application/firmware/out/selftest/firmware.hex";
    parameter TIMEOUT   = 2000000;
    localparam integer NB = 16;              // clocks per UART bit

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire [7:0] pins;
    wire       tx;
    reg        rx = 1;
    assign pins[3:0] = 4'b1010;
    genvar g;
    generate for (g = 0; g < 8; g = g + 1) begin : g_pull
        assign (weak0, weak1) pins[g] = 1'b0;
    end endgenerate

    top #(.IMEM_WORDS(4096), .DMEM_WORDS(2048), .IMEM_INIT_FILE(HEX),
          .UART_CLK_FREQ_HZ(1600000), .UART_BAUD_RATE(100000)) dut (
        .clk_i(clk), .rst_i(rst), .pins_io(pins), .tx_o(tx), .rx_i(rx));

    integer pass = 0, fail = 0;
    task chk(input ok, input [8*48-1:0] what);
        begin
            if (ok) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL %0s", what); end
        end
    endtask

    // ---------------- UART receiver on tx_o --------------------------------
    reg [7:0] rxbuf [0:4095];
    integer   nrx = 0, frame_err = 0, k;
    reg [7:0] b;
    always begin
        @(negedge tx);
        repeat (NB / 2) @(posedge clk);
        if (tx !== 1'b0) frame_err = frame_err + 1;          // false start
        for (k = 0; k < 8; k = k + 1) begin
            repeat (NB) @(posedge clk);
            b[k] = tx;
        end
        repeat (NB) @(posedge clk);
        if (tx !== 1'b1) frame_err = frame_err + 1;          // bad stop bit
        rxbuf[nrx] = b;
        nrx = nrx + 1;
    end

    // ---------------- UART transmitter on rx_i -----------------------------
    task send(input [7:0] d);
        integer j;
        begin
            rx = 0; repeat (NB) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin rx = d[j]; repeat (NB) @(posedge clk); end
            rx = 1; repeat (2 * NB) @(posedge clk);
        end
    endtask

    function [7:0] hexch(input [3:0] v);
        hexch = (v > 9) ? 8'd55 + v : 8'd48 + v;
    endfunction

    function ends_with_ready(input integer n);
        ends_with_ready = n >= 6 && rxbuf[n-6] == "R" && rxbuf[n-5] == "E" && rxbuf[n-4] == "A"
                       && rxbuf[n-3] == "D" && rxbuf[n-2] == "Y" && rxbuf[n-1] == 8'h0A;
    endfunction

    // ---------------- Sequence ---------------------------------------------
    reg     event_seen = 0;
    integer cycles = 0, ready_at = -1, i, j2, nfail_words;
    reg [8*80-1:0] line;
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (dut.sys_event_o) event_seen = 1;
    end

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        wait (ends_with_ready(nrx) || cycles > TIMEOUT);
        ready_at = nrx;
        if (ready_at > 0) begin
            send("r");
            send(8'h78); send(8'h56); send(8'h34); send(8'h12);
        end
        wait (event_seen || cycles > TIMEOUT);
        repeat (4 * NB * 10) @(posedge clk);   // let a last frame finish

        // Transcript, one line at a time.
        $display("---- transcript (%0d bytes) ----", nrx);
        j2 = 0; line = 0;
        for (i = 0; i < nrx; i = i + 1) begin
            if (rxbuf[i] == 8'h0A || i == nrx - 1) begin
                $display("  %0s", line);
                line = 0;
            end else if (rxbuf[i] >= 8'h20 && rxbuf[i] < 8'h7F) line = {line[8*79-1:0], rxbuf[i]};
            else line = {line[8*76-1:0], "<", hexch(rxbuf[i][7:4]), hexch(rxbuf[i][3:0]), ">"};
        end
        $display("--------------------------------");

        chk(cycles <= TIMEOUT, "finished before the timeout");
        chk(event_seen, "main() returned (sys_event_o pulsed)");
        chk(frame_err == 0, "no UART framing errors");
        chk(ready_at > 0, "program reached READY");
        // Byte echo, then the word inverted, little-endian, then newline.
        chk(nrx >= ready_at + 6, "UART replies present");
        chk(rxbuf[ready_at] == "R", "byte echo 'r' -> 'R'");
        chk({rxbuf[ready_at+4], rxbuf[ready_at+3], rxbuf[ready_at+2], rxbuf[ready_at+1]} == 32'hEDCBA987,
            "u32 read LE, inverted, written LE");
        // No group reported FAIL, and the verdict line is PASS.
        nfail_words = 0;
        for (i = 0; i + 3 < nrx; i = i + 1)
            if (rxbuf[i] == "F" && rxbuf[i+1] == "A" && rxbuf[i+2] == "I" && rxbuf[i+3] == "L")
                nfail_words = nfail_words + 1;
        chk(nfail_words == 0, "no group reported FAIL");
        j2 = 0;
        for (i = 0; i + 13 < nrx; i = i + 1)
            if (rxbuf[i] == "S" && rxbuf[i+1] == "E" && rxbuf[i+2] == "L" && rxbuf[i+9] == "P"
                && rxbuf[i+10] == "A" && rxbuf[i+11] == "S" && rxbuf[i+12] == "S") j2 = 1;
        chk(j2 == 1, "verdict line SELFTEST PASS");
        // GPIO: the program copied pins 3:0 (1010) to pins 7:4 and drives them.
        chk(pins === 8'b1010_1010, "pins 7:4 = copy of pins 3:0");
        chk(dut.gpio_oe === 8'hF0, "DATADIR = F0");

        $display("==== tb_selftest: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_SELFTEST: ALL TESTS PASSED");
        else           $display("TB_SELFTEST: FAILURES PRESENT");
        $finish;
    end
endmodule
