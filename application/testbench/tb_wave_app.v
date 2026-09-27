`timescale 1ns/1ps
// ============================================================================
// tb_wave_app.v - ONE vehicle through LaneX, made for a clean waveform. Use it
// with the application ROM (chipinventor/app/imem_app.v) in the imem block.
// The UART runs at the chip's real 115,200 bps.
//
// What happens, in order (about 110,000 clock cycles, 3.65 ms):
//   1. A car enters the read zone: P0 = 1 (class code P2:P1 = 00, a car).
//   2. The RFID reader sends one tag read into rx_i: a 26-byte frame
//      A5 52 15 ... F5 (start byte, type 'R', length 21, the read, CRC-16).
//   3. The car leaves: P0 = 0.
//   4. The chip decides: CHARGED, class 1, RM 2.50. It lights P4 (charged)
//      and sends the 8-byte record 56 00 00 11 FA 00 3C 7B on tx_o.
//
// The waveform holds only the 11 signals of the module `probe` (the viewer
// sorts them alphabetically): car_class_P2_P1, car_present_P0, clk,
// lamp_alarm_P6, lamp_camera_P5, lamp_charged_P4, record_from_tx_o (the last
// 8-byte record read), rst, uart_rx_byte (the byte being sent), uart_rx_i,
// uart_tx_o.
// Pass: "[PASS] LaneX vehicle waveform run completed successfully".
// ============================================================================
module probe (
    input  [1:0] car_class_P2_P1,     // from the vehicle classifier: 00 = car
    input        car_present_P0,      // a vehicle is in the read zone
    input        clk,
    input        lamp_alarm_P6,
    input        lamp_camera_P5,
    input        lamp_charged_P4,
    input [63:0] record_from_tx_o,    // the last complete 8-byte record the chip sent
    input        rst,
    input  [7:0] uart_rx_byte,        // the byte being sent into rx_i
    input        uart_rx_i,           // from the RFID reader
    input        uart_tx_o            // to the toll back end
);
endmodule

module testbench;
    localparam integer NB = 263;          // clock cycles per UART bit (115,200 bps)

    reg clk = 1'b0, rst = 1'b1;
    always #16.5 clk = ~clk;              // 30.303 MHz

    reg        car_present = 1'b0;
    reg  [1:0] car_class = 2'b00;
    reg        uart_rx = 1'b1;
    wire       uart_tx;
    reg  [7:0] rx_byte = 8'h00;
    reg [63:0] record = 64'h0;
    wire p0, p1, p2, p3, p4, p5, p6, p7;
    assign p0 = car_present;
    assign {p2, p1} = car_class;
    assign p3 = 1'b0;                     // lane open
    assign (weak0, weak1) p4 = 1'b0;
    assign (weak0, weak1) p5 = 1'b0;
    assign (weak0, weak1) p6 = 1'b0;
    assign (weak0, weak1) p7 = 1'b0;

    top dut (
        .clk_i(clk), .rst_i(rst),
        .pins_io_0(p0), .pins_io_1(p1), .pins_io_2(p2), .pins_io_3(p3),
        .pins_io_4(p4), .pins_io_5(p5), .pins_io_6(p6), .pins_io_7(p7),
        .tx_o(uart_tx), .rx_i(uart_rx));

    probe waveform (.car_class_P2_P1(car_class), .car_present_P0(car_present), .clk(clk),
                    .lamp_alarm_P6(p6), .lamp_camera_P5(p5), .lamp_charged_P4(p4),
                    .record_from_tx_o(record), .rst(rst), .uart_rx_byte(rx_byte),
                    .uart_rx_i(uart_rx), .uart_tx_o(uart_tx));
    initial begin
        $dumpfile("testbench.vcd");
        $dumpvars(1, waveform);
    end

    // one tag read of a class-1 car tag (the frame of emulator-preview line 1)
    reg [7:0] frame [0:25];
    initial begin
        frame[0]  = 8'hA5; frame[1]  = 8'h52; frame[2]  = 8'h15; frame[3]  = 8'h30;
        frame[4]  = 8'h75; frame[5]  = 8'h00; frame[6]  = 8'h00; frame[7]  = 8'h00;
        frame[8]  = 8'h30; frame[9]  = 8'h19; frame[10] = 8'h51; frame[11] = 8'h80;
        frame[12] = 8'hF3; frame[13] = 8'h83; frame[14] = 8'hA5; frame[15] = 8'hDC;
        frame[16] = 8'hF3; frame[17] = 8'h1A; frame[18] = 8'hE2; frame[19] = 8'h39;
        frame[20] = 8'hE5; frame[21] = 8'hCC; frame[22] = 8'h6E; frame[23] = 8'h5A;
        frame[24] = 8'h92; frame[25] = 8'hF5;
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

    // the toll back end: read 8 bytes from tx_o, first byte first
    integer nbytes = 0;
    reg [63:0] shift = 64'h0;
    reg [7:0]  b;
    integer    k;
    always begin
        @(negedge uart_tx);
        if (rst === 1'b0) begin
            repeat (NB / 2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin repeat (NB) @(posedge clk); b[k] = uart_tx; end
            repeat (NB) @(posedge clk);
            shift = {shift[55:0], b};
            nbytes = nbytes + 1;
            if (nbytes % 8 == 0) record = shift;
        end
    end

    integer i, t;
    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3000) @(posedge clk);             // the firmware starts
        car_class = 2'b00; car_present = 1'b1;    // 1. a car arrives
        repeat (1500) @(posedge clk);
        for (i = 0; i < 26; i = i + 1) uart_send(frame[i]);   // 2. its tag is read
        repeat (1500) @(posedge clk);
        car_present = 1'b0;                        // 3. it leaves
        t = 0;
        while (nbytes < 8 && t < 200000) begin @(posedge clk); t = t + 1; end
        repeat (2000) @(posedge clk);
        if (record === 64'h56000011FA003C7B && p4 === 1'b1 && p5 === 1'b0 && p6 === 1'b0) begin
            $display("[PASS] record 56 00 00 11 FA 00 3C 7B: vehicle #0 CHARGED, class 1, RM 2.50");
            $display("[PASS] lamps: P4 charged on, P5 camera off, P6 alarm off");
            $display("[PASS] LaneX vehicle waveform run completed successfully");
        end else begin
            $display("[FAIL] record %h, lamps P6-P4 = %b%b%b", record, p6, p5, p4);
        end
        $finish;
    end
endmodule
