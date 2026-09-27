`timescale 1ns/1ps
// ============================================================================
// tb_app.v - the Stage 3 application (the toll lane controller firmware) on
// rtl/top.v, checked byte for byte against the golden model.
//
// lane_model.py (the golden model, beside this file) writes two files per scenario:
//   <name>.stim  B <hex bytes>   send bytes over rx_i back to back, then the
//                                host's inter-frame gap (GAP_BITS)
//                N <hex bytes>   the same with no gap after (the next line
//                                continues on the next bit)
//                G <hex>         set pins 3:0 (presence, class code, lane),
//                                then settle: SETTLE_FALL clocks when a car
//                                leaves, SETTLE_RISE otherwise
//                W <decimal>     idle that many clocks
//                E               end
//   <name>.exp   R <16 hex> <pp> one 8-byte record the chip must transmit,
//                                and, for a vehicle record, pins 7:4 just
//                                after that vehicle left (pp; ff = not one)
// The testbench plays the stimulus, captures tx_o, and requires the exact
// record sequence; pins 7:4 are compared SETTLE clocks after each car leaves
// (P0 falls), because records trail the cars by a byte-time each.
//
// The UART runs at the ASIC's real rate: 30.303 MHz / 115200 bps = 263 clocks
// per bit, 2,630 per byte. That matters: the UART holds one received byte, so
// the firmware must always collect a byte within one byte-time. The testbench
// measures the longest time RXDONE stays set and counts overruns (a byte
// completing while the previous one is still unread); both are reported and
// an overrun fails the run.
//
// Build: make -C application/firmware; python application/testbench/lane_model.py
//        iverilog -g2005 -o build/tb_app.vvp rtl/*.v application/testbench/tb_app.v
//        vvp build/tb_app.vvp +STIM=build/lane/directed.stim +EXP=build/lane/directed.exp
// ============================================================================
module tb_app;
    parameter HEX      = "application/firmware/out/lane/firmware.hex";
    parameter CLK_HZ   = 30303030;
    parameter BAUD     = 115200;
    localparam integer NB = (CLK_HZ + BAUD / 2) / BAUD;   // clocks per bit
    parameter GAP_BITS = 20;       // idle after each frame (the host's inter-frame gap)
    // Settle after a pin change. A leaving car is decided once the line has
    // been quiet for the exit hold-off (64 loop iterations) - after the parser
    // has dropped any half-received frame (48 iterations) - so the fall's
    // settle covers both; an arrival is handled at once, and its settle only
    // has to cover the parser timeout.
    parameter SETTLE_FALL = 30000;
    parameter SETTLE_RISE = 16000;
    parameter TIMEOUT  = 400000000;

    reg clk = 0, rst = 1;
    always #16.5 clk = ~clk;

    wire [7:0] pins;
    wire       tx;
    reg        rx = 1;
    reg  [3:0] pin_in = 4'h0;
    assign pins[3:0] = pin_in;
    genvar g;
    generate for (g = 4; g < 8; g = g + 1) begin : g_pull
        assign (weak0, weak1) pins[g] = 1'b0;
    end endgenerate

    top #(.IMEM_WORDS(4096), .DMEM_WORDS(2048), .IMEM_INIT_FILE(HEX),
          .UART_CLK_FREQ_HZ(CLK_HZ), .UART_BAUD_RATE(BAUD)) dut (
        .clk_i(clk), .rst_i(rst), .pins_io(pins), .tx_o(tx), .rx_i(rx));

    integer pass = 0, fail = 0, shown = 0;
    task chk(input ok, input [8*64-1:0] what);
        begin
            if (ok) pass = pass + 1;
            else begin
                fail = fail + 1;
                if (shown < 25) begin shown = shown + 1; $display("FAIL %0s", what); end
            end
        end
    endtask

    // ---------------- expected records --------------------------------------
    reg [63:0] exp_rec [0:8191];
    reg [7:0]  exp_pin [0:8191];
    reg [7:0]  veh_pin [0:8191];      // pins 7:4 the model shows after each vehicle
    integer    n_exp = 0, n_veh = 0, vi = 0;

    // ---------------- receiver on tx_o --------------------------------------
    reg [7:0] rbuf [0:7];
    integer   nb = 0, n_rec = 0, frame_err = 0, k;
    integer   n_v = 0, n_a = 0, n_e = 0, n_q = 0, n_i = 0, t_ident = -1, att_lat = -1;
    reg [7:0] b;
    reg [63:0] got;
    always begin
        @(negedge tx);
        repeat (NB / 2) @(posedge clk);
        if (tx !== 1'b0) frame_err = frame_err + 1;
        for (k = 0; k < 8; k = k + 1) begin repeat (NB) @(posedge clk); b[k] = tx; end
        repeat (NB) @(posedge clk);
        if (tx !== 1'b1) frame_err = frame_err + 1;
        rbuf[nb] = b;
        nb = nb + 1;
        if (nb == 8) begin
            nb = 0;
            got = {rbuf[0], rbuf[1], rbuf[2], rbuf[3], rbuf[4], rbuf[5], rbuf[6], rbuf[7]};
            case (rbuf[0])
                8'h56: n_v = n_v + 1;
                8'h41: n_a = n_a + 1;
                8'h45: n_e = n_e + 1;
                8'h51: n_q = n_q + 1;
                8'h49: begin n_i = n_i + 1; if (t_ident >= 0) att_lat = cycles - t_ident; end
            endcase
            if (n_rec >= n_exp) chk(0, "more records than expected");
            else begin
                if (got !== exp_rec[n_rec]) begin
                    chk(0, "record mismatch");
                    if (shown < 25) $display("     record %0d: got %h expected %h", n_rec, got, exp_rec[n_rec]);
                end else pass = pass + 1;
            end
            n_rec = n_rec + 1;
        end
    end

    // ---------------- exit latency: car leaves (P0 falls) -> its record starts
    integer t_fall = -1, exit_lat = 0, max_exit = 0;
    always @(negedge pin_in[0]) if ($time > 0) t_fall = cycles;   // not power-up's x -> 0
    always @(negedge tx) if (t_fall >= 0) begin
        exit_lat = cycles - t_fall;
        if (exit_lat > max_exit) max_exit = exit_lat;
        t_fall = -1;
    end

    // ---------------- UART monitors: overrun and service latency ------------
    integer overruns = 0, lat = 0, max_lat = 0;
    always @(posedge clk) if (!rst) begin
        if (dut.u_uart.rx_done && dut.u_uart.rxdone) overruns = overruns + 1;
        if (dut.u_uart.rxdone) begin
            lat = lat + 1;
            if (lat > max_lat) max_lat = lat;
            if (lat == 10 * NB)
                $display("  NOTE byte unread for a whole byte-time: frame %0d, pin change %0d, pc %h",
                         frames, gpios, dut.u_core.u_pc.pc);
        end else lat = 0;
    end

    // ---------------- stimulus ----------------------------------------------
    task send_byte(input [7:0] d);
        integer j;
        begin
            rx = 0; repeat (NB) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin rx = d[j]; repeat (NB) @(posedge clk); end
            rx = 1; repeat (NB) @(posedge clk);
        end
    endtask

    reg [8*80-1:0] stim_file, exp_file;
    reg [8*200-1:0] hexs;
    integer fd, r, nbytes, i, cycles = 0, frames = 0, gpios = 0, wcyc;
    reg [7:0] cmd;
    reg [63:0] rec;
    reg [7:0]  pp;
    reg [7:0]  by;
    reg [3:0]  gv, prev_in;

    function [3:0] hexval(input [7:0] ch);
        hexval = (ch >= "a") ? ch - "a" + 10 : (ch >= "A") ? ch - "A" + 10 : ch - "0";
    endfunction

    always @(posedge clk) cycles = cycles + 1;

    // Boot time: reset release to the firmware's first DATADIR write (main()).
    integer boot = -1, rel = 0;
    always @(posedge clk) begin
        if (rst) rel = cycles;
        else if (boot < 0 && dut.gpio_oe === 8'hF0) boot = cycles - rel;
    end

    initial begin
        if (!$value$plusargs("STIM=%s", stim_file)) stim_file = "build/lane/directed.stim";
        if (!$value$plusargs("EXP=%s", exp_file))   exp_file  = "build/lane/directed.exp";
        fd = $fopen(exp_file, "r");
        if (fd == 0) begin $display("FAIL cannot open %0s", exp_file); $finish; end
        r = $fscanf(fd, "%c", cmd);
        while (cmd != "E") begin
            r = $fscanf(fd, " %h %h\n", rec, pp);
            exp_rec[n_exp] = rec; exp_pin[n_exp] = pp; n_exp = n_exp + 1;
            if (pp != 8'hFF) begin veh_pin[n_veh] = pp; n_veh = n_veh + 1; end
            r = $fscanf(fd, "%c", cmd);
        end
        $fclose(fd);

        repeat (5) @(posedge clk);
        rst = 0;
        repeat (2000) @(posedge clk);

        fd = $fopen(stim_file, "r");
        if (fd == 0) begin $display("FAIL cannot open %0s", stim_file); $finish; end
        r = $fscanf(fd, "%c", cmd);
        while (cmd != "E") begin
            if (cmd == "W") begin
                r = $fscanf(fd, " %d\n", wcyc);
                repeat (wcyc) @(posedge clk);
            end else if (cmd == "G") begin
                r = $fscanf(fd, " %h\n", gv);
                prev_in = pin_in;
                pin_in = gv;
                gpios = gpios + 1;
                if (prev_in[0] && !gv[0]) repeat (SETTLE_FALL) @(posedge clk);
                else                      repeat (SETTLE_RISE) @(posedge clk);
                if (prev_in[0] && !gv[0]) begin          // a car has just left
                    if (vi >= n_veh) chk(0, "more vehicles than the model");
                    else if (pins[7:4] !== veh_pin[vi][7:4]) begin
                        chk(0, "pins 7:4 after a vehicle leaves");
                        if (shown < 25) $display("     vehicle %0d: pins %b, model %b", vi, pins[7:4], veh_pin[vi][7:4]);
                    end else pass = pass + 1;
                    vi = vi + 1;
                end
            end else begin
                r = $fscanf(fd, " %s\n", hexs);
                // hexs holds the characters right-aligned; walk from the left
                nbytes = 0;
                for (i = 199; i >= 1; i = i - 1)
                    if (hexs[8*i +: 8] != 0 && nbytes == 0) nbytes = (i + 1) / 2;
                for (i = nbytes - 1; i >= 0; i = i - 1) begin
                    by = {hexval(hexs[8*(2*i+1) +: 8]), hexval(hexs[8*(2*i) +: 8])};
                    send_byte(by);
                end
                frames = frames + 1;
                // an 'I' frame (A5 49 00 crc): time its answer from here
                if (nbytes == 5 && hexs[8*7 +: 8] == "4" && hexs[8*6 +: 8] == "9") t_ident = cycles;
                if (cmd == "B") repeat (GAP_BITS * NB) @(posedge clk);
            end
            r = $fscanf(fd, "%c", cmd);
        end
        $fclose(fd);

        // drain: let every queued record leave the chip
        repeat (40 * 10 * NB) @(posedge clk);

        chk(n_rec == n_exp, "record count equals the model's");
        chk(vi == n_veh, "every vehicle's pins were checked");
        chk(frame_err == 0, "no framing errors on tx_o");
        chk(overruns == 0, "no UART receive overrun (firmware kept up)");
        chk(nb == 0, "no partial record left over");
        chk(boot >= 0 && boot < 2000, "firmware ready before the first byte (2000 cycles)");
        $display("  %0d frames, %0d pin changes, %0d records, %0d cycles; boot %0d cycles",
                 frames, gpios, n_rec, cycles, boot);
        $display("  records: %0d V, %0d A (authenticated), %0d E, %0d Q, %0d I", n_v, n_a, n_e, n_q, n_i);
        if (att_lat >= 0)
            $display("  ROM measurement ('I' frame sent -> 'I' record received): %0d cycles", att_lat);
        $display("  longest decision delay (car leaves -> its record starts): %0d cycles", max_exit);
        $display("  longest RXDONE wait: %0d cycles (one byte-time is %0d cycles; ASIC %0d, FPGA 50 MHz %0d)",
                 max_lat, 10 * NB, 2630, 4340);
        $display("==== tb_app: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_APP: ALL TESTS PASSED");
        else           $display("TB_APP: FAILURES PRESENT");
        $finish;
    end

    initial begin
        #(TIMEOUT * 33.0);
        $display("FAIL timeout");
        $display("TB_APP: FAILURES PRESENT");
        $finish;
    end
endmodule
