`timescale 1ns/1ps
// ============================================================================
// tb_official_firmware.v - the OFFICIAL FIRMWARE TESTBENCH (Stage 3 brief §3)
//
// Runs the organisers' GPIO and UART test firmware (firmware/main.s, loaded by
// imem_official.v) on our chip `top`, touching only its pins, and checks the
// responses the organisers' README asks for:
//
//   GPIO   0xA applied to P3-P0   ->  0xA on P7-P4   (DATAOUT = 0xA0)
//   UART   0x30 sent into rx_i    ->  0x30 back on tx_o
//
// then the same for all 16 values of P3-P0, each paired with a different byte
// (0x00, 0xFF, alternating bits, single bits), in the firmware's own order:
// copy P3-P0 to P7-P4, wait for a byte, echo it, repeat. A new P3-P0 value is
// therefore copied only after the next echo.
//
// Every wait has a timeout that prints a clear [FAIL] line. The waveform
// (testbench.vcd) holds clock, reset, P3-P0, P7-P4, rx_i, tx_o and the byte
// just sent and received.
//
// Clock 30.303 MHz (33 ns, the chip's clock); UART 115200 bps 8-N-1, so one
// bit is 263 clock cycles. The module is named `testbench` because the
// ChipInventor simulator runs the module of that name.
// Pass: "[PASS] GPIO and UART firmware test completed successfully".
// ============================================================================
module testbench;
    localparam integer NB      = 263;      // clock cycles per UART bit (30303030 / 115200)
    localparam integer TIMEOUT = 20000;    // cycles allowed for any one response

    reg clk = 1'b0, rst = 1'b1;
    always #16.5 clk = ~clk;
    integer cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    // ---- the chip's pins -----------------------------------------------
    reg  [3:0] gpio_in  = 4'h0;            // what the testbench applies to P3-P0
    reg        uart_rx  = 1'b1;            // the chip's rx_i (idles high)
    wire       uart_tx;                    // the chip's tx_o
    wire p0, p1, p2, p3, p4, p5, p6, p7;
    assign p0 = gpio_in[0];
    assign p1 = gpio_in[1];
    assign p2 = gpio_in[2];
    assign p3 = gpio_in[3];
    assign (weak0, weak1) p4 = 1'b0;       // outputs: a weak pull only, so an
    assign (weak0, weak1) p5 = 1'b0;       // undriven pin reads 0, never z
    assign (weak0, weak1) p6 = 1'b0;
    assign (weak0, weak1) p7 = 1'b0;
    wire [3:0] gpio_out = {p7, p6, p5, p4}; // what the chip drives on P7-P4

    top dut (
        .clk_i(clk), .rst_i(rst),
        .pins_io_0(p0), .pins_io_1(p1), .pins_io_2(p2), .pins_io_3(p3),
        .pins_io_4(p4), .pins_io_5(p5), .pins_io_6(p6), .pins_io_7(p7),
        .tx_o(uart_tx), .rx_i(uart_rx));

    // ---- waveform --------------------------------------------------------
    reg [7:0] rx_byte = 8'h00;             // last byte sent into rx_i
    reg [7:0] tx_byte = 8'h00;             // last byte read from tx_o
    initial begin
        $dumpfile("testbench.vcd");
        $dumpvars(1, testbench);           // the pins and these bytes only
    end

    integer pass = 0, fail = 0;

    // Send one byte into rx_i: start bit, 8 data bits LSB first, stop bit.
    task uart_send(input [7:0] b);
        integer j;
        begin
            rx_byte = b;
            uart_rx = 1'b0; repeat (NB) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin uart_rx = b[j]; repeat (NB) @(posedge clk); end
            uart_rx = 1'b1; repeat (NB) @(posedge clk);
        end
    endtask

    // Receive one byte from tx_o, sampling each bit in its middle.
    task uart_receive(output [7:0] b, output ok);
        integer j, t;
        begin
            ok = 1'b0; t = 0;
            while (uart_tx !== 1'b0 && t < TIMEOUT) begin @(posedge clk); t = t + 1; end
            if (t < TIMEOUT) begin
                repeat (NB / 2) @(posedge clk);                  // middle of the start bit
                for (j = 0; j < 8; j = j + 1) begin repeat (NB) @(posedge clk); b[j] = uart_tx; end
                repeat (NB) @(posedge clk);                      // stop bit
                ok = (uart_tx === 1'b1);
                tx_byte = b;
            end
        end
    endtask

    // Wait until P7-P4 shows v.
    task gpio_expect(input [3:0] v, output ok);
        integer t;
        begin
            t = 0;
            while (gpio_out !== v && t < TIMEOUT) begin @(posedge clk); t = t + 1; end
            ok = (gpio_out === v);
        end
    endtask

    // Upper-case hex digits, as in the organisers' example log.
    function [7:0] hx(input [3:0] v);
        hx = (v < 10) ? ("0" + v) : ("A" + v - 10);
    endfunction

    // P7-P4 must show g. Prints the organisers' GPIO log line.
    task check_gpio(input [3:0] g);
        reg ok;
        begin
            gpio_expect(g, ok);
            if (ok) begin
                pass = pass + 1;
                $display("[PASS] GPIO: P3-P0 = 0x%s, P7-P4 = 0x%s   (cycle %0d)", hx(g), hx(gpio_out), cycles);
            end else begin
                fail = fail + 1;
                $display("[FAIL] GPIO: P3-P0 = 0x%s, expected P7-P4 = 0x%s, got 0x%s after %0d cycles",
                         hx(g), hx(g), hx(gpio_out), TIMEOUT);
            end
        end
    endtask

    // Byte b into rx_i must come back on tx_o. Prints the organisers' UART log line.
    task check_uart(input [7:0] b);
        reg ok;
        reg [7:0] got;
        begin
            fork
                uart_send(b);
                uart_receive(got, ok);
            join
            if (ok && got === b) begin
                pass = pass + 1;
                $display("[PASS] UART: RX = 0x%s%s, TX = 0x%s%s   (cycle %0d)",
                         hx(b[7:4]), hx(b[3:0]), hx(got[7:4]), hx(got[3:0]), cycles);
            end else begin
                fail = fail + 1;
                if (ok) $display("[FAIL] UART: RX = 0x%s%s, TX = 0x%s%s",
                                 hx(b[7:4]), hx(b[3:0]), hx(got[7:4]), hx(got[3:0]));
                else    $display("[FAIL] UART: RX = 0x%s%s, no valid byte on tx_o within %0d cycles",
                                 hx(b[7:4]), hx(b[3:0]), TIMEOUT);
            end
        end
    endtask

    integer k;
    reg [7:0] bytes [0:15];
    initial begin
        bytes[0]  = 8'h00; bytes[1]  = 8'hFF; bytes[2]  = 8'h55; bytes[3]  = 8'hAA;
        bytes[4]  = 8'h01; bytes[5]  = 8'h80; bytes[6]  = 8'h7E; bytes[7]  = 8'h81;
        bytes[8]  = 8'h0F; bytes[9]  = 8'hF0; bytes[10] = 8'h3C; bytes[11] = 8'hC3;
        bytes[12] = 8'h96; bytes[13] = 8'h69; bytes[14] = 8'h5A; bytes[15] = 8'hA5;

        $display("============================================================");
        $display(" Official Stage 3 GPIO and UART test firmware on RVBL-2");
        $display(" clock 30.303 MHz, UART 115200 bps (%0d cycles per bit)", NB);
        $display("============================================================");

        // The organisers' test: 0xA is on P3-P0 before the firmware first reads it.
        gpio_in = 4'hA;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        check_gpio(4'hA);
        check_uart(8'h30);

        // Then every value of P3-P0, each with a different byte. The firmware
        // reads P3-P0 again only after an echo, so the new value is applied,
        // a byte is echoed, and then P7-P4 must follow.
        $display("-- all 16 GPIO values, each with a different UART byte --");
        for (k = 0; k < 16; k = k + 1) begin
            gpio_in = k[3:0];
            check_uart(bytes[k]);
            check_gpio(k[3:0]);
        end

        $display("============================================================");
        $display("==== tb_official_firmware: %0d passed, %0d failed, %0d cycles ====", pass, fail, cycles);
        if (fail == 0) $display("[PASS] GPIO and UART firmware test completed successfully");
        else           $display("[FAIL] GPIO and UART firmware test: %0d check(s) failed", fail);
        $finish;
    end

    // Overall watchdog: the firmware must never stall the test.
    initial begin
        #(33.0 * 1000000);
        $display("[FAIL] timeout: the test did not finish within 1,000,000 cycles");
        $finish;
    end
endmodule
