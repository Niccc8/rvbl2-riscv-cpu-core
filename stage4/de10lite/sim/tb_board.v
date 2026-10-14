// ============================================================================
// tb_board.v - the whole DE10-Lite board in simulation (lanex_board: the chip,
// its ROM and every fabric block), driven like the real desk lane: switches,
// KEY1, the ultrasonic sensor over the lane (an HC-SR04 model), and a laptop
// on the host link.
//
// Stimulus: a text file (+stim=...), one command per line, written by
// check_board.py:
//   S <hex>          set SW9..0
//   K <0|1>          KEY1 released / pressed
//   U <mm>           the height of what is under the sensor (0: the bare floor)
//   Y <n>            wait for n more ultrasonic readings
//   Z <0|1>          the sensor unplugged / plugged in
//   G <0|1> <seed>   a noisy sensor off / on (see the HC-SR04 model)
//   W <n>            wait n board milliseconds
//   M                wait until the board is in lane mode, then 5 ms more
//   N                wait until the board shows the chip's ID at boot, then 5 ms more
//   V                wait for the chip's next 'V' record, then 6 ms more
//   I                wait for the chip's next 'I' record, then 6 ms more
//   Q                wait until the channel into the chip is quiet
//   T                wait until tour mode has finished
//   X <n> <b>...     the laptop sends n bytes (hex)
//   R                KEY0: the board resets (as the 20 ms-filtered KEY0 does)
//   F <0|1>          fault injection: the chip's UART output silenced / restored
//   D <tag>          log a snapshot of the displays, LEDs and lamps
//   E                end
//
// Log (+log=...), every event with its clock cycle, for the golden model:
//   R c              the chip leaves reset (a new run: the model starts afresh)
//   P c v            P3:P0 as the chip's pins now read (hex)
//   B c bb           a byte the chip received (decoded from its rx line)
//   C c bb           a byte the chip sent (decoded from its tx line)
//   T c bb           a byte the laptop received (decoded from GPIO[1])
//   H c hex48 ledr lamps mode  every change of the displays, LEDs or lamps (mode 0 boot, 1 lane, 2 tour)
//   F c v            the fault injection's state
//   D c tag hex48 ledr lamps dec_ms   lamps = {buzzer, closed, red, white, green};
//                    dec_ms = the decision display's remaining time
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_board;
    parameter integer CLK_HZ   = 31250000;
    parameter integer BAUD     = 115200;
    parameter integer TICK_DIV = 100;          // a board millisecond, in core clocks (scaled)
    parameter integer SONAR_PERIOD = 50000;    // core clocks between ultrasonic readings (scaled)
    parameter integer FLOOR_MM = 150;          // the sensor's height above the floor
    localparam integer CPB = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer HOST_CPB = CPB + CPB / 100;   // the laptop's UART runs 1 % slow

    reg clk = 1'b0;
    always #16 clk = ~clk;                     // 32 ns ~ 31.25 MHz (only cycles matter)
    reg        rst = 1'b1;
    reg [9:0]  sw = 10'd0;
    reg        key1_n = 1'b1, host_rx = 1'b1;
    wire       host_tx, trig;
    reg        echo = 1'b0;
    wire [47:0] hex_n;
    wire [9:0]  ledr;
    wire       g, w, r, c, bz, bt;

    lanex_board #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .TICK_DIV(TICK_DIV), .SONAR_PERIOD(SONAR_PERIOD)) dut (
        .clk(clk), .rst(rst), .sw(sw), .key1_n(key1_n), .sonar_echo(echo), .sonar_trig(trig),
        .host_rx(host_rx), .host_tx(host_tx), .hex_n(hex_n), .ledr(ledr),
        .lamp_green(g), .lamp_white(w), .lamp_red(r), .lamp_closed(c), .buzzer(bz), .buzzer_tone(bt));

    // ---- the passive buzzer's tone: only while the buzzer sounds, and every half period
    // exactly CLK_HZ/4800 clocks while it does (a beep starts with a full high half) ----
    localparam integer TONE_HALF = CLK_HZ / 4800;
    wire    bon = bz ^ dut.swd[6];             // the buzzer sounds (whatever SW6's polarity)
    reg     bt_q = 1'b0, bon_q = 1'b0;
    integer tone_run = 0, tone_halves = 0, tone_bad = 0;
    always @(posedge clk) begin
        bt_q <= bt; bon_q <= bon;
        if (bt && !bon) tone_bad <= tone_bad + 1;                         // a tone in silence
        if (bon && bon_q && bt != bt_q) begin                             // a half period ended
            tone_halves <= tone_halves + 1;
            if (tone_run != TONE_HALF) tone_bad <= tone_bad + 1;
        end
        if (bon && bon_q && tone_run > TONE_HALF) tone_bad <= tone_bad + 1; // stuck while it sounds
        tone_run <= (bt != bt_q) ? 1 : tone_run + 1;
    end

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    integer lf;

    // ---- the log -------------------------------------------------------------
    reg       chip_rst_q = 1'b1;
    reg [3:0] pins_q = 4'd0;
    always @(posedge clk) begin
        chip_rst_q <= dut.chip_rst;
        if (chip_rst_q && !dut.chip_rst) $fwrite(lf, "R %0d\n", cyc);
        pins_q <= dut.chip_pins_in;
        if (!dut.chip_rst && dut.chip_pins_in !== pins_q) $fwrite(lf, "P %0d %x\n", cyc, dut.chip_pins_in);
    end
    // every change a person could see: the 6 digits, the 10 LEDs, the 5 outside outputs
    reg [47:0] hex_q = 48'd0;
    reg [9:0]  ledr_q = 10'd0;
    reg [4:0]  lamps_q = 5'd0;
    always @(posedge clk) begin
        hex_q <= hex_n; ledr_q <= ledr; lamps_q <= {bz, c, r, w, g};
        if (hex_n !== hex_q || ledr !== ledr_q || {bz, c, r, w, g} !== lamps_q)
            $fwrite(lf, "H %0d %012x %03x %02x %0d\n", cyc, hex_n, ledr, {bz, c, r, w, g}, dut.mode);
    end

    // UART monitors on the chip's rx and tx lines and on the laptop's line
    uart_mon #(.CPB(CPB), .TAG("B")) m_rx   (.clk(clk), .line(dut.chip_rx), .cyc(cyc));
    uart_mon #(.CPB(CPB), .TAG("C")) m_tx   (.clk(clk), .line(dut.chip_tx), .cyc(cyc));
    uart_mon #(.CPB(CPB), .TAG("T")) m_host (.clk(clk), .line(host_tx),     .cyc(cyc));

    // ---- the ultrasonic sensor: an HC-SR04 ----------------------------------
    // After each trigger it sends its burst, then holds Echo high for the round
    // trip: mm x 2 / 343 m/s. Unplugged, the FPGA's weak pull-up holds Echo high.
    // Noisy (G 1): what a real one does on a desk, every reading drawn at random -
    //   +/-3 mm of jitter, always;
    //   7 %: it misses the nearest echo and hears a farther one (a footing, the
    //        table's edge), 12-30 mm past the floor - in bursts of 1-3 readings;
    //   3 %: a stray near echo (a post), 40-60 % of the way down;
    //   2 %: no echo at all; 2 %: Echo held 38 ms (the HC-SR04's own time-out);
    //   5 %: 1-3 spikes of 1-40 clocks on the Echo wire before the echo, 3 %: a
    //        1-25 clock drop-out while it is high (the long wire picks things up).
    integer obj_mm = 0;                        // the height of what is under the sensor
    reg     plugged = 1'b1;
    integer readings = 0, echo_cyc, d_mm, burst = 0, nspk, q;
    reg     noisy = 1'b0;
    reg [31:0] rs = 32'h2545F491;
    function automatic [31:0] xs(input [31:0] x);  // xorshift32
        reg [31:0] y;
        begin y = x ^ (x << 13); y = y ^ (y >> 17); xs = y ^ (y << 5); end
    endfunction
    task automatic roll(output integer v, input integer n);   // 0 .. n-1
        begin rs = xs(rs); v = rs % n; end
    endtask
    initial begin
        #2;
        forever begin
            @(negedge trig);
            readings = readings + 1;
            if (plugged) begin
                echo = 1'b0;
                d_mm = FLOOR_MM - obj_mm;
                if (noisy) begin
                    roll(q, 7); d_mm = d_mm + q - 3;                       // jitter
                    roll(q, 100);
                    if (burst > 0) begin burst = burst - 1; roll(q, 19); d_mm = FLOOR_MM + 12 + q; q = 200; end
                    if (q < 7) begin roll(burst, 3); roll(q, 19); d_mm = FLOOR_MM + 12 + q; end
                    else if (q < 10) begin roll(q, 21); d_mm = FLOOR_MM * (40 + q) / 100; end
                    else if (q < 12) d_mm = -1;                             // no echo
                    else if (q < 14) d_mm = -2;                             // the 38 ms time-out
                    roll(q, 100);
                    if (q < 5) begin                                        // spikes before the echo
                        roll(nspk, 3);
                        repeat (nspk + 1) begin
                            roll(q, CLK_HZ / 8000); repeat (q + 1) @(posedge clk);
                            roll(q, 40); echo = 1'b1; repeat (q + 1) @(posedge clk); echo = 1'b0;
                        end
                    end
                end
                repeat (CLK_HZ / 2000) @(posedge clk);          // 0.5 ms: the 40 kHz burst
                if (d_mm == -2) begin
                    echo = 1'b1; repeat (CLK_HZ / 1000 * 38) @(posedge clk); echo = 1'b0;
                end else if (d_mm >= 0) begin
                    echo_cyc = d_mm * 2 * (CLK_HZ / 1000) / 343;
                    echo = 1'b1;
                    roll(q, 100);
                    if (noisy && q < 3) begin                               // a drop-out while high
                        roll(q, echo_cyc / 2 + 1); repeat (q + 1) @(posedge clk);
                        echo = 1'b0; roll(q, 25); repeat (q + 1) @(posedge clk); echo = 1'b1;
                        repeat (echo_cyc / 2) @(posedge clk);
                    end else repeat (echo_cyc) @(posedge clk);
                    echo = 1'b0;
                end
            end
        end
    end

    // ---- helpers -------------------------------------------------------------
    task automatic wait_ms(input integer n);
        integer i;
        for (i = 0; i < n; i = i + 1) @(posedge dut.tick);
    endtask
    task automatic host_send(input [7:0] b);
        integer i;
        begin
            host_rx = 1'b0; repeat (HOST_CPB) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin host_rx = b[i]; repeat (HOST_CPB) @(posedge clk); end
            host_rx = 1'b1; repeat (HOST_CPB) @(posedge clk);
        end
    endtask
    task automatic wait_rec(input [7:0] kind);
        begin
            @(posedge clk);
            while (!(dut.rec_valid && dut.rec[7:0] == kind)) @(posedge clk);
            wait_ms(6);
        end
    endtask

    // ---- the stimulus ----------------------------------------------------------
    reg [8*256-1:0] stim, logname;
    reg [8*64-1:0]  tag;
    integer sf, n, v, i, k;
    reg running;
    reg [7:0] cmd;
    // watchdog: no command may take more than 40 board seconds plus 20 M clocks (the
    // UART and settle times do not shrink with TICK_DIV): a missed event ends the run.
    // Y counts readings, whose period does not shrink either: each reading is progress.
    integer guard = 0;
    reg     trig_q = 1'b0;
    always @(posedge clk) begin
        trig_q <= trig;
        guard <= (cmd == "Y" && trig_q && !trig) ? 0 : guard + 1;
        if (guard == 40000 * TICK_DIV + 20000000) begin
            $fwrite(lf, "TIMEOUT %0d command '%c'\n", cyc, cmd);
            $fclose(lf);
            $display("tb_board: TIMEOUT at cycle %0d in command '%c'", cyc, cmd);
            $finish;
        end
    end
    initial begin
        if (!$value$plusargs("stim=%s", stim)) begin $display("FATAL no +stim"); $finish; end
        if (!$value$plusargs("log=%s", logname)) logname = "board.log";
        sf = $fopen(stim, "r");
        lf = $fopen(logname, "w");
        if (sf == 0 || lf == 0) begin $display("FATAL cannot open the stimulus or the log"); $finish; end
        $fwrite(lf, "# tb_board CLK_HZ %0d BAUD %0d TICK_DIV %0d\n", CLK_HZ, BAUD, TICK_DIV);
        repeat (20) @(posedge clk);
        rst = 1'b0;
        running = 1'b1;
        while (running) begin
            n = $fscanf(sf, " %c", cmd);
            guard = 0;
            if (n != 1) cmd = "E";
            case (cmd)
                "S": begin n = $fscanf(sf, " %h", v); sw = v[9:0]; end
                "K": begin n = $fscanf(sf, " %d", v); key1_n = !v; end
                "U": begin n = $fscanf(sf, " %d", v); obj_mm = v; end
                "Y": begin n = $fscanf(sf, " %d", v); k = readings + v; while (readings < k) @(posedge clk); end
                "Z": begin n = $fscanf(sf, " %d", v); plugged = v[0]; echo = !v[0]; end
                "G": begin n = $fscanf(sf, " %d %d", v, k); noisy = v[0]; rs = k + 32'h9E3779B9; end
                "R": begin rst = 1'b1; repeat (100) @(posedge clk); rst = 1'b0; end
                "F": begin
                         n = $fscanf(sf, " %d", v);
                         $fwrite(lf, "F %0d %0d\n", cyc, v);
                         if (v[0]) force dut.chip_tx = 1'b1; else release dut.chip_tx;
                     end
                "W": begin n = $fscanf(sf, " %d", v); wait_ms(v); end
                "M": begin while (dut.mode != 2'd1) @(posedge clk); wait_ms(5); end
                "N": begin while (!(dut.mode == 2'd0 && dut.bphase == 2'd2)) @(posedge clk); wait_ms(5); end
                "V": wait_rec(8'h56);
                "I": wait_rec(8'h49);
                "Q": begin @(posedge clk); while (!dut.quiet) @(posedge clk); end
                "T": begin while (!dut.tr_done) @(posedge clk); wait_ms(3); end
                "X": begin
                         n = $fscanf(sf, " %d", k);
                         for (i = 0; i < k; i = i + 1) begin n = $fscanf(sf, " %h", v); host_send(v[7:0]); end
                     end
                "D": begin
                         n = $fscanf(sf, " %s", tag);
                         $fwrite(lf, "D %0d %0s %012x %03x %02x %0d\n", cyc, tag, hex_n, ledr, {bz, c, r, w, g}, dut.dec_ms);
                     end
                "E": begin
                         $fwrite(lf, "TONE %0d %0d\n", tone_halves, tone_bad);
                         $fwrite(lf, "END %0d\n", cyc);
                         $fclose(lf);
                         $display("tb_board: done at cycle %0d", cyc);
                         running = 1'b0;
                     end
                default: begin $display("FATAL bad command '%c'", cmd); running = 1'b0; end
            endcase
            if (running) $fflush(lf);
        end
        $finish;
    end
endmodule

// A UART monitor: a byte is logged at its stop bit, as "<TAG> cycle hex"
module uart_mon #(parameter integer CPB = 271, parameter [7:0] TAG = "B") (
    input wire clk, line,
    input wire [31:0] cyc
);
    integer i;
    reg [7:0] b;
    initial begin
        #1;
        forever begin
            @(negedge line);
            repeat (CPB / 2) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                repeat (CPB) @(posedge clk);
                b[i] = line;
            end
            repeat (CPB) @(posedge clk);
            $fwrite(tb_board.lf, "%c %0d %02x\n", TAG, cyc, b);
        end
    end
endmodule

`default_nettype wire
