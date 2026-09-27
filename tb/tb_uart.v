`timescale 1ns/1ps
// ============================================================================
// tb_uart.v - unit tests for uart.v (spec §10.1, U5-U17).
//
// A bus-functional far-end UART drives rx_i with a bit time set in real
// nanoseconds, so it can run at any baud error; a decoder samples tx_o.
// Three instances share one bus but have their own write strobes:
//   u16  - 16 clocks/bit, fast; most tests
//   u64  - 64 clocks/bit; the tolerance sweep (finer timing resolution)
//   u263 - the real ASIC divisor (30303030 Hz / 115200), one frame each way
//
//   U5  TX frame bit-exact, TXDONE low for exactly 10N clocks, TRANSMIT pulse
//   U6  RX at 0, +-1, +-2, +-3 % baud error, random bytes
//   U7  tolerance sweep; the passing band must cover +-3.5 %
//   U8  back-to-back frames, far end 3 % fast and 3 % slow
//   U9  full duplex
//   U10 overrun: newest byte kept, RXDONE stays set
//   U11 framing error and break: byte dropped, receiver re-arms after idle
//   U12 start-bit glitches rejected
//   U13 rx_i low from reset: no phantom byte
//   U14 TRANSMIT while busy ignored; TXDATA write mid-frame is safe
//   U15 RXDONE: set wins over a same-cycle clear, write 1 has no effect,
//       0x3 starts a frame without clearing RXDONE, byte lanes
//   U16 read-only and reserved bits, offset 0xC, full decode
//   U17 reset mid-frame
// ============================================================================
module tb_uart;
    localparam real CLK_NS = 10.0;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  [31:0] addr = 0, wdata = 0;
    reg  [3:0]  bw = 0;
    reg  [2:0]  we = 0;                     // one strobe per instance
    reg         rx16 = 1, rx64 = 1, rx263 = 1;
    wire        tx16, tx64, tx263;
    wire [31:0] rd16, rd64, rd263;

    uart #(.SLOT(4'd1), .CLK_FREQ_HZ(1600000), .BAUD_RATE(100000)) u16 (
        .clk_i(clk), .rst_i(rst), .bus_addr_i(addr), .bus_wdata_i(wdata), .bus_we_i(we[0]),
        .bus_bw_i(bw), .bus_rdata_i(32'b0), .bus_rdata_o(rd16), .tx_o(tx16), .rx_i(rx16));
    uart #(.SLOT(4'd1), .CLK_FREQ_HZ(6400000), .BAUD_RATE(100000)) u64 (
        .clk_i(clk), .rst_i(rst), .bus_addr_i(addr), .bus_wdata_i(wdata), .bus_we_i(we[1]),
        .bus_bw_i(bw), .bus_rdata_i(32'b0), .bus_rdata_o(rd64), .tx_o(tx64), .rx_i(rx64));
    uart #(.SLOT(4'd1)) u263 (   // defaults: 30303030 Hz, 115200 bps
        .clk_i(clk), .rst_i(rst), .bus_addr_i(addr), .bus_wdata_i(wdata), .bus_we_i(we[2]),
        .bus_bw_i(bw), .bus_rdata_i(32'b0), .bus_rdata_o(rd263), .tx_o(tx263), .rx_i(rx263));

    localparam [31:0] TXDATA = 32'hF100_0000, RXDATA = 32'hF100_0004, CONTROL = 32'hF100_0008;
    localparam [31:0] TRANSMIT = 32'h1, RXDONE = 32'h2, TXDONE = 32'h4;

    integer pass = 0, fail = 0;
    integer i, k, n, got_n;
    reg [31:0] v, v2;
    reg [7:0]  b, bytes [0:63];
    real       err, lo_ok, hi_ok;
    reg        ok, band_broken;

    // ---------------- Checking ------------------------------------------------
    task check(input [31:0] got, input [31:0] exp, input [8*80-1:0] name);
        begin
            if (got === exp) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL %0s: got %h expected %h", name, got, exp); end
        end
    endtask

    // ---------------- Bus (one-cycle write strobe, combinational read) --------
    task wr(input integer inst, input [31:0] a, input [31:0] d, input [3:0] b_en);
        begin
            @(negedge clk); addr = a; wdata = d; bw = b_en; we = 3'b001 << inst;
            @(negedge clk); we = 0; bw = 0;
        end
    endtask
    task rd(input integer inst, input [31:0] a, output [31:0] d);
        begin
            addr = a; #1;
            d = (inst == 0) ? rd16 : (inst == 1) ? rd64 : rd263;
        end
    endtask

    // ---------------- Far-end transmitter (drives rx_i) ----------------------
    task set_rx(input integer inst, input level);
        begin
            case (inst) 0: rx16 = level; 1: rx64 = level; default: rx263 = level; endcase
        end
    endtask
    // One frame: start, 8 data bits LSB first, stop (stop_level 0 = framing error).
    task send(input integer inst, input [7:0] data, input real bit_ns, input stop_level);
        integer j;
        begin
            set_rx(inst, 0); #(bit_ns);
            for (j = 0; j < 8; j = j + 1) begin set_rx(inst, data[j]); #(bit_ns); end
            set_rx(inst, stop_level); #(bit_ns);
            set_rx(inst, 1);
        end
    endtask

    // ---------------- Receiver-side helpers ----------------------------------
    // Wait for RXDONE (bounded), read RXDATA, clear RXDONE by writing 0.
    task expect_rx(input integer inst, input [7:0] exp, input integer max_clks, input [8*80-1:0] name);
        integer t;
        begin
            t = 0; v = 0;
            while (!(v & RXDONE) && t < max_clks) begin @(negedge clk); rd(inst, CONTROL, v); t = t + 1; end
            if (!(v & RXDONE)) begin fail = fail + 1; $display("FAIL %0s: RXDONE never set", name); end
            else begin
                rd(inst, RXDATA, v); check(v, {24'b0, exp}, name);
                wr(inst, CONTROL, 32'h0, 4'b1111);
            end
        end
    endtask
    // Assert RXDONE stays clear for a while.
    task expect_quiet(input integer inst, input integer clks, input [8*80-1:0] name);
        integer t; reg seen;
        begin
            seen = 0;
            for (t = 0; t < clks; t = t + 1) begin @(negedge clk); rd(inst, CONTROL, v); if (v & RXDONE) seen = 1; end
            check({31'b0, seen}, 0, name);
        end
    endtask

    // ---------------- Transmit decoder on tx_o (cycle-exact) -----------------
    // After TRANSMIT: tx_o must fall, then hold each of the 10 bits for exactly
    // N clocks, with TXDONE low for exactly 10N clocks.
    task check_tx_frame(input integer inst, input integer nb, input [7:0] data, input [8*80-1:0] name);
        integer c, bad, lowdone; reg [9:0] frame; reg txv;
        begin
            frame = {1'b1, data, 1'b0};
            bad = 0; lowdone = 0;
            // wait for the start bit
            c = 0;
            txv = (inst == 0) ? tx16 : (inst == 1) ? tx64 : tx263;
            while (txv !== 1'b0 && c < 8) begin
                @(posedge clk); #1; txv = (inst == 0) ? tx16 : (inst == 1) ? tx64 : tx263; c = c + 1;
            end
            if (txv !== 1'b0) begin fail = fail + 1; $display("FAIL %0s: no start bit", name); end
            else begin
                for (c = 0; c < 10 * nb; c = c + 1) begin
                    txv = (inst == 0) ? tx16 : (inst == 1) ? tx64 : tx263;
                    if (txv !== frame[c / nb]) bad = bad + 1;
                    rd(inst, CONTROL, v); if (!(v & TXDONE)) lowdone = lowdone + 1;
                    @(posedge clk); #1;
                end
                check(bad, 0, name);
                check(lowdone, 10 * nb, "U5 TXDONE low for exactly 10 bit-times");
                rd(inst, CONTROL, v); check(v & TXDONE, TXDONE, "U5 TXDONE set once the stop bit is sent");
                txv = (inst == 0) ? tx16 : (inst == 1) ? tx64 : tx263;
                check({31'b0, txv}, 1, "U5 line idles high after the frame");
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); #1 rst = 0;

        // ---------------- Reset state and U16 register rules -----------------
        rd(0, CONTROL, v); check(v, TXDONE, "reset: CONTROL = TXDONE only");
        rd(0, TXDATA, v);  check(v, 0, "reset: TXDATA = 0");
        rd(0, RXDATA, v);  check(v, 0, "reset: RXDATA = 0");
        check({31'b0, tx16}, 1, "reset: tx_o idles high");

        wr(0, TXDATA, 32'hFFFF_FF3C, 4'b1111); rd(0, TXDATA, v); check(v, 32'h3C, "U16 TXDATA read-back, reserved bits 0");
        wr(0, RXDATA, 32'hFF, 4'b1111);        rd(0, RXDATA, v); check(v, 0, "U16 RXDATA is read-only");
        wr(0, CONTROL, 32'hFFFF_FFFA, 4'b1111); // TRANSMIT=0, RXDONE=1, TXDONE=0, reserved=1s
        rd(0, CONTROL, v); check(v, TXDONE, "U16 writing TXDONE=0 or RXDONE=1 changes nothing");
        rd(0, 32'hF100_000C, v); check(v, 0, "U16 offset 0xC reads 0");
        wr(0, 32'hF100_000C, 32'h1, 4'b1111);
        wr(0, 32'hF100_0018, 32'h1, 4'b1111);  // addr[23:4] != 0
        wr(0, 32'hF000_0008, 32'h1, 4'b1111);  // GPIO's slot
        rd(0, CONTROL, v); check(v, TXDONE, "U16 no aliasing: foreign addresses never start a frame");
        rd(0, 32'hF100_0018, v); check(v, 0, "U16 no aliasing: 0xF1000018 reads 0");

        // Byte lanes: CONTROL and TXDATA live in lane 0.
        wr(0, TXDATA, 32'h0000_5500, 4'b0010); rd(0, TXDATA, v); check(v, 32'h3C, "U15 sb to TXDATA+1 changes nothing");
        wr(0, CONTROL, 32'hFFFF_FFFF, 4'b0000); rd(0, CONTROL, v); check(v, TXDONE, "U15 misaligned store (bw=0000) cannot start a frame");
        wr(0, CONTROL, 32'h0000_0100, 4'b0010); rd(0, CONTROL, v); check(v, TXDONE, "U15 sb to CONTROL+1 cannot start a frame");

        // ---------------- U5: transmit frames --------------------------------
        wr(0, TXDATA, 32'hA5, 4'b1111);
        wr(0, CONTROL, TRANSMIT, 4'b0001);          // sb, lane 0
        // A load samples no earlier than 4 cycles after its store; 2 suffice.
        fork
            check_tx_frame(0, 16, 8'hA5, "U5 frame 0xA5 bit-exact at N=16");
            begin repeat (2) @(posedge clk); #2 rd(0, CONTROL, v2);
                  check(v2, 0, "U5 TRANSMIT self-cleared and TXDONE low once the frame starts"); end
        join
        wr(0, TXDATA, 32'h00, 4'b1111); wr(0, CONTROL, TRANSMIT, 4'b1111);
        check_tx_frame(0, 16, 8'h00, "U5 frame 0x00 bit-exact");
        wr(0, TXDATA, 32'hFF, 4'b1111); wr(0, CONTROL, TRANSMIT, 4'b1111);
        check_tx_frame(0, 16, 8'hFF, "U5 frame 0xFF bit-exact");
        wr(2, TXDATA, 32'h6B, 4'b1111); wr(2, CONTROL, TRANSMIT, 4'b1111);
        check_tx_frame(2, 263, 8'h6B, "U5 frame bit-exact at the ASIC divisor N=263");

        // ---------------- U6: receive at +-0..3 % ------------------------------
        for (k = -3; k <= 3; k = k + 1) begin
            err = k / 100.0;
            for (i = 0; i < 24; i = i + 1) begin
                b = $random;
                fork
                    send(0, b, 16 * CLK_NS * (1.0 + err), 1);
                    expect_rx(0, b, 400, "U6 RX byte at baud error -3..+3 %");
                join
                #(2 * 16 * CLK_NS);
            end
        end
        fork
            send(2, 8'hC6, 263 * CLK_NS * 1.02, 1);
            expect_rx(2, 8'hC6, 3200, "U6 RX at the ASIC divisor, far end 2 % slow");
        join

        // ---------------- U7: tolerance sweep at N=64 ------------------------
        lo_ok = 0.0; hi_ok = 0.0;
        band_broken = 0;
        for (k = 0; k <= 28 && !band_broken; k = k + 1) begin          // 0 .. +7 %
            err = k * 0.0025; ok = 1;
            for (i = 0; i < 12; i = i + 1) begin
                b = $random;
                fork send(1, b, 64 * CLK_NS * (1.0 + err), 1); join
                #(64 * CLK_NS);
                rd(1, CONTROL, v);
                if (!(v & RXDONE)) ok = 0; else begin rd(1, RXDATA, v); if (v[7:0] !== b) ok = 0; end
                wr(1, CONTROL, 0, 4'b1111);
            end
            if (ok) hi_ok = err; else band_broken = 1;
        end
        #(12 * 64 * CLK_NS); wr(1, CONTROL, 0, 4'b1111);   // let the failed point drain
        band_broken = 0;
        for (k = 0; k <= 28 && !band_broken; k = k + 1) begin          // 0 .. -7 %
            err = -k * 0.0025; ok = 1;
            for (i = 0; i < 12; i = i + 1) begin
                b = $random;
                fork send(1, b, 64 * CLK_NS * (1.0 + err), 1); join
                #(64 * CLK_NS);
                rd(1, CONTROL, v);
                if (!(v & RXDONE)) ok = 0; else begin rd(1, RXDATA, v); if (v[7:0] !== b) ok = 0; end
                wr(1, CONTROL, 0, 4'b1111);
            end
            if (ok) lo_ok = err; else band_broken = 1;
        end
        $display("  [U7] receiver tolerance at N=64: works from %0.2f %% to %0.2f %% far-end baud error",
                 lo_ok * 100.0, hi_ok * 100.0);
        check({31'b0, (hi_ok >= 0.035) && (lo_ok <= -0.035)}, 1, "U7 tolerance band covers +-3.5 %");

        // ---------------- U8: back-to-back frames ----------------------------
        for (k = 0; k < 2; k = k + 1) begin
            err = (k == 0) ? 0.03 : -0.03;
            for (i = 0; i < 32; i = i + 1) bytes[i] = $random;
            got_n = 0; ok = 1;
            fork
                for (n = 0; n < 32; n = n + 1) send(0, bytes[n], 16 * CLK_NS * (1.0 + err), 1);
                begin : consumer
                    integer t;
                    for (t = 0; t < 32 * 170 && got_n < 32; t = t + 1) begin
                        @(negedge clk); rd(0, CONTROL, v);
                        if (v & RXDONE) begin
                            rd(0, RXDATA, v); if (v[7:0] !== bytes[got_n]) ok = 0;
                            got_n = got_n + 1;
                            wr(0, CONTROL, 0, 4'b1111);
                        end
                    end
                end
            join
            check(got_n, 32, "U8 back-to-back: all 32 frames received");
            check({31'b0, ok}, 1, "U8 back-to-back: every byte correct");
            #(3 * 16 * CLK_NS);
        end

        // ---------------- U9: full duplex ------------------------------------
        wr(0, TXDATA, 32'h3E, 4'b1111); wr(0, CONTROL, TRANSMIT, 4'b1111);
        fork
            check_tx_frame(0, 16, 8'h3E, "U9 full duplex: TX frame exact while receiving");
            send(0, 8'hD1, 16 * CLK_NS, 1);
        join
        expect_rx(0, 8'hD1, 200, "U9 full duplex: RX byte correct while transmitting");

        // ---------------- U10: overrun ---------------------------------------
        send(0, 8'h11, 16 * CLK_NS, 1); #(16 * CLK_NS);
        send(0, 8'h22, 16 * CLK_NS, 1); #(16 * CLK_NS);
        rd(0, CONTROL, v); check(v & RXDONE, RXDONE, "U10 overrun: RXDONE still set");
        rd(0, RXDATA, v);  check(v, 32'h22, "U10 overrun: RXDATA holds the newest byte");
        wr(0, CONTROL, 0, 4'b1111);

        // ---------------- U11: framing error and break ------------------------
        fork
            send(0, 8'h5A, 16 * CLK_NS, 0);        // stop bit low
            expect_quiet(0, 200, "U11 framing error: byte dropped");
        join
        rd(0, RXDATA, v); check(v, 32'h22, "U11 framing error: RXDATA unchanged");
        set_rx(0, 0); #(3 * 10 * 16 * CLK_NS);     // break: 3 frames low
        fork
            begin set_rx(0, 1); #(40 * CLK_NS); end
            expect_quiet(0, 400, "U11 break: no byte delivered");
        join
        fork
            send(0, 8'h96, 16 * CLK_NS, 1);
            expect_rx(0, 8'h96, 200, "U11 receiver re-armed after break");
        join

        // ---------------- U12: start-bit glitches ----------------------------
        fork
            begin
                set_rx(0, 0); #(1 * CLK_NS);  set_rx(0, 1); #(40 * CLK_NS);
                set_rx(0, 0); #(4 * CLK_NS);  set_rx(0, 1); #(40 * CLK_NS);
                set_rx(0, 0); #(6 * CLK_NS);  set_rx(0, 1); #(40 * CLK_NS);
            end
            expect_quiet(0, 300, "U12 glitches of 1, N/4 and N/2-2 clocks rejected");
        join
        fork
            send(0, 8'h3C, 16 * CLK_NS, 1);
            expect_rx(0, 8'h3C, 200, "U12 real frame received after glitches");
        join

        // ---------------- U13: rx_i low from reset ----------------------------
        rst = 1; set_rx(0, 0); repeat (3) @(posedge clk); #1 rst = 0;
        #(2 * 10 * 16 * CLK_NS + 37 * CLK_NS);     // low for 2+ frames, odd phase
        fork
            begin set_rx(0, 1); #(40 * CLK_NS); end
            expect_quiet(0, 400, "U13 rx_i low from reset: no phantom byte");
        join
        fork
            send(0, 8'hE7, 16 * CLK_NS, 1);
            expect_rx(0, 8'hE7, 200, "U13 first real frame after the line recovers");
        join

        // ---------------- U14: TRANSMIT while busy, TXDATA mid-frame ---------
        wr(0, TXDATA, 32'h81, 4'b1111); wr(0, CONTROL, TRANSMIT, 4'b1111);
        fork
            check_tx_frame(0, 16, 8'h81, "U14 frame in flight unchanged");
            begin
                repeat (40) @(posedge clk);
                wr(0, TXDATA, 32'h7E, 4'b1111);       // mid-frame
                wr(0, CONTROL, TRANSMIT, 4'b1111);    // while busy: ignored
            end
        join
        repeat (20) @(posedge clk);
        check({31'b0, tx16}, 1, "U14 TRANSMIT written while busy started nothing");
        wr(0, CONTROL, TRANSMIT, 4'b1111);
        check_tx_frame(0, 16, 8'h7E, "U14 next TRANSMIT sends the new TXDATA");

        // ---------------- U15: RXDONE semantics -------------------------------
        send(0, 8'h01, 16 * CLK_NS, 1); #(16 * CLK_NS);   // RXDONE = 1, RXDATA = 0x01
        wr(0, CONTROL, RXDONE, 4'b1111);                   // write 1: no effect
        rd(0, CONTROL, v); check(v & RXDONE, RXDONE, "U15 writing 1 leaves RXDONE set");
        wr(0, CONTROL, 32'h0, 4'b0010);                    // sb zero to CONTROL+1
        rd(0, CONTROL, v); check(v & RXDONE, RXDONE, "U15 sb zero to CONTROL+1 does not clear RXDONE");
        wr(0, TXDATA, 32'h42, 4'b1111);
        wr(0, CONTROL, TRANSMIT | RXDONE, 4'b1111);        // 0x3
        fork
            check_tx_frame(0, 16, 8'h42, "U15 frame started by 0x3");
            begin repeat (2) @(posedge clk); #2 rd(0, CONTROL, v2);
                  check(v2, RXDONE, "U15 0x3 starts a frame and keeps RXDONE"); end
        join
        wr(0, CONTROL, 32'h0, 4'b0001);                    // sb zero to CONTROL
        rd(0, CONTROL, v); check(v, TXDONE, "U15 sb zero to CONTROL clears RXDONE");

        // Same-cycle collision: RXDONE already set, a new byte completes on the
        // very edge that a software clear is written. The set must win.
        send(0, 8'hAA, 16 * CLK_NS, 1); #(16 * CLK_NS);   // RXDONE = 1
        fork
            send(0, 8'hBB, 16 * CLK_NS, 1);
            begin
                @(negedge clk);
                while (!(u16.rx_state == 2'd3 && u16.rx_cnt == 0)) @(negedge clk);
                addr = CONTROL; wdata = 0; bw = 4'b1111; we = 3'b001;   // clear, same cycle
                #1 check({31'b0, u16.rx_done}, 1, "U15 collision really lands on the rx_done cycle");
                @(negedge clk); we = 0; bw = 0;
            end
        join
        rd(0, CONTROL, v); check(v & RXDONE, RXDONE, "U15 same-cycle set and clear: set wins");
        rd(0, RXDATA, v);  check(v, 32'hBB, "U15 same-cycle: RXDATA is the new byte");
        wr(0, CONTROL, 0, 4'b1111);

        // ---------------- U17: reset mid-frame --------------------------------
        wr(0, TXDATA, 32'h0F, 4'b1111); wr(0, CONTROL, TRANSMIT, 4'b1111);
        repeat (50) @(posedge clk);
        @(negedge clk) rst = 1; @(posedge clk); #1;
        check({31'b0, tx16}, 1, "U17 reset mid-TX: line high at the next edge");
        @(negedge clk) rst = 0;
        rd(0, CONTROL, v); check(v, TXDONE, "U17 reset mid-TX: TXDONE = 1, nothing pending");
        fork
            begin
                set_rx(0, 0); #(16 * CLK_NS); set_rx(0, 1); #(3 * 16 * CLK_NS);   // frame starts
            end
            begin #(20 * CLK_NS); @(negedge clk) rst = 1; @(negedge clk) rst = 0; end
        join
        expect_quiet(0, 300, "U17 reset mid-RX, sender aborts: no byte");
        fork
            send(0, 8'h5C, 16 * CLK_NS, 1);
            expect_rx(0, 8'h5C, 200, "U17 first frame after reset received");
        join

        $display("==== tb_uart: %0d passed, %0d failed ====", pass, fail);
        if (fail == 0) $display("TB_UART: ALL TESTS PASSED");
        else           $display("TB_UART: FAILURES PRESENT");
        $finish;
    end
endmodule
