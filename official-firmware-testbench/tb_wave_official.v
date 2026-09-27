`timescale 1ns/1ps
// ============================================================================
// tb_wave_official.v - a SHORT run of the official GPIO and UART test firmware,
// made for a clean waveform. Use it with imem_official.v in the imem block.
//
// What happens, in order (about 11,800 clock cycles, 0.39 ms):
//   1. P3-P0 = 0xA before reset ends. The firmware copies it: P7-P4 = 0xA.
//   2. The byte 0x30 goes into rx_i; the chip sends 0x30 back on tx_o.
//   3. P3-P0 changes to 0x5. The firmware reads P3-P0 only after an echo, so
//      P7-P4 still shows 0xA ...
//   4. ... until the byte 0x55 is echoed. Then P7-P4 = 0x5.
//
// The waveform holds only the 8 signals of the module `probe`, named so the
// viewer's alphabetical order reads top to bottom: clk, gpio_in_P3_P0,
// gpio_out_P7_P4, rst, uart_rx_byte (the byte being sent), uart_rx_i,
// uart_tx_byte (the byte read back), uart_tx_o.
// Pass: "[PASS] GPIO and UART waveform run completed successfully".
// ============================================================================
module probe (
    input       clk,
    input [3:0] gpio_in_P3_P0,   // set by the testbench
    input [3:0] gpio_out_P7_P4,  // driven by the chip
    input       rst,
    input [7:0] uart_rx_byte,    // the byte being sent into rx_i
    input       uart_rx_i,       // the chip's rx_i
    input [7:0] uart_tx_byte,    // the byte just read from tx_o
    input       uart_tx_o        // the chip's tx_o
);
endmodule

module testbench;
    localparam integer NB = 263;          // clock cycles per UART bit (115,200 bps)

    reg clk = 1'b0, rst = 1'b1;
    always #16.5 clk = ~clk;              // 30.303 MHz

    reg  [3:0] gpio_in = 4'h0;
    reg        uart_rx = 1'b1;
    wire       uart_tx;
    reg  [7:0] rx_byte = 8'h00, tx_byte = 8'h00;
    wire p0, p1, p2, p3, p4, p5, p6, p7;
    assign {p3, p2, p1, p0} = gpio_in;
    assign (weak0, weak1) p4 = 1'b0;
    assign (weak0, weak1) p5 = 1'b0;
    assign (weak0, weak1) p6 = 1'b0;
    assign (weak0, weak1) p7 = 1'b0;
    wire [3:0] gpio_out = {p7, p6, p5, p4};

    top dut (
        .clk_i(clk), .rst_i(rst),
        .pins_io_0(p0), .pins_io_1(p1), .pins_io_2(p2), .pins_io_3(p3),
        .pins_io_4(p4), .pins_io_5(p5), .pins_io_6(p6), .pins_io_7(p7),
        .tx_o(uart_tx), .rx_i(uart_rx));

    probe waveform (.clk(clk), .gpio_in_P3_P0(gpio_in), .gpio_out_P7_P4(gpio_out), .rst(rst),
                    .uart_rx_byte(rx_byte), .uart_rx_i(uart_rx), .uart_tx_byte(tx_byte), .uart_tx_o(uart_tx));
    initial begin
        $dumpfile("testbench.vcd");
        $dumpvars(1, waveform);
    end

    task uart_send(input [7:0] b);
        integer j;
        begin
            rx_byte = b;
            uart_rx = 1'b0; repeat (NB) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin uart_rx = b[j]; repeat (NB) @(posedge clk); end
            uart_rx = 1'b1; repeat (NB) @(posedge clk);
        end
    endtask

    task uart_receive;
        integer j;
        reg [7:0] b;
        begin
            @(negedge uart_tx);
            repeat (NB / 2) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin repeat (NB) @(posedge clk); b[j] = uart_tx; end
            repeat (NB) @(posedge clk);
            tx_byte = b;
        end
    endtask

    integer fail = 0;
    task echo(input [7:0] b);
        begin
            fork uart_send(b); uart_receive; join
            if (tx_byte === b) $display("[PASS] UART: RX = 0x%h, TX = 0x%h", b, tx_byte);
            else begin fail = fail + 1; $display("[FAIL] UART: RX = 0x%h, TX = 0x%h", b, tx_byte); end
        end
    endtask
    task gpio_check(input [3:0] v);
        begin
            if (gpio_out === v) $display("[PASS] GPIO: P3-P0 = 0x%h, P7-P4 = 0x%h", gpio_in, gpio_out);
            else begin fail = fail + 1; $display("[FAIL] GPIO: expected P7-P4 = 0x%h, got 0x%h", v, gpio_out); end
        end
    endtask

    initial begin
        gpio_in = 4'hA;                   // 1. present before the firmware first reads it
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (200) @(posedge clk);
        gpio_check(4'hA);
        repeat (300) @(posedge clk);
        echo(8'h30);                      // 2. the echo
        repeat (300) @(posedge clk);
        gpio_in = 4'h5;                   // 3. new value: not copied yet
        repeat (600) @(posedge clk);
        gpio_check(4'hA);
        echo(8'h55);                      // 4. after this echo it is copied
        repeat (300) @(posedge clk);
        gpio_check(4'h5);
        if (fail == 0) $display("[PASS] GPIO and UART waveform run completed successfully");
        else           $display("[FAIL] %0d check(s) failed", fail);
        $finish;
    end
endmodule
