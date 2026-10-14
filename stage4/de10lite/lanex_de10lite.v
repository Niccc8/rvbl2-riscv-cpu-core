// ============================================================================
// lanex_de10lite.v - top level for the Terasic DE10-Lite (MAX 10 10M50DAF484C7G).
// Port names are Terasic's (pins in lanex.qsf). Hand-written.
//
//   MAX10_CLK1_50 --> PLL (x mul / div) --> the core clock, CORE_HZ
//   KEY0 = reset (the whole board, as power-on; held 20 ms); KEY1, SW9..0: see lanex_board.v
//   GPIO header JP1 (wiring_card.html):
//     GPIO[0] in   laptop -> board (USB-UART TXD)     GPIO[5] out  white lamp (camera)
//     GPIO[1] out  board -> laptop (USB-UART RXD)     GPIO[6] out  red lamp (alarm)
//     GPIO[2] in   ultrasonic Echo (1k/2k divider)    GPIO[7] out  buzzer
//     GPIO[3] out  ultrasonic Trig                    GPIO[8] out  lane-closed lamp
//     GPIO[4] out  green lamp (charged)               GPIO[9] out  passive buzzer (2.4 kHz tone)
//                                                     GPIO[35:10]  not used (high impedance)
// ============================================================================
`default_nettype none

module lanex_de10lite #(
    // 31,250,000 = the AWS F2 build's clock. lanex.qsf sets it (set_parameter);
    // 25,000,000 and 20,000,000 are the fallbacks if timing is not met.
    parameter integer CORE_HZ = 31250000,
    // the lane's height thresholds (mm above the floor under the sensor): lanex.qsf
    parameter integer PRESENT_MM = 15,
    parameter integer TALL_MM    = 60
) (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0,
    output wire [7:0]  HEX1,
    output wire [7:0]  HEX2,
    output wire [7:0]  HEX3,
    output wire [7:0]  HEX4,
    output wire [7:0]  HEX5,
    inout  wire [35:0] GPIO
);
    localparam integer MUL = (CORE_HZ == 25000000) ? 1 : (CORE_HZ == 20000000) ? 2 : 5;
    localparam integer DIV = (CORE_HZ == 25000000) ? 2 : (CORE_HZ == 20000000) ? 5 : 8;

    // ---- the core clock: MAX 10 PLL, 50 MHz x MUL / DIV -------------------
    wire [4:0] pll_clk;
    wire       pll_locked;
    altpll #(
        .bandwidth_type          ("AUTO"),
        .clk0_divide_by          (DIV),
        .clk0_duty_cycle         (50),
        .clk0_multiply_by        (MUL),
        .clk0_phase_shift        ("0"),
        .compensate_clock        ("CLK0"),
        .inclk0_input_frequency  (20000),
        .intended_device_family  ("MAX 10"),
        .lpm_hint                ("CBX_MODULE_PREFIX=lanex_pll"),
        .lpm_type                ("altpll"),
        .operation_mode          ("NORMAL"),
        .pll_type                ("AUTO"),
        .port_activeclock        ("PORT_UNUSED"),
        .port_areset             ("PORT_USED"),
        .port_clkbad0            ("PORT_UNUSED"),
        .port_clkbad1            ("PORT_UNUSED"),
        .port_clkloss            ("PORT_UNUSED"),
        .port_clkswitch          ("PORT_UNUSED"),
        .port_configupdate       ("PORT_UNUSED"),
        .port_fbin               ("PORT_UNUSED"),
        .port_inclk0             ("PORT_USED"),
        .port_inclk1             ("PORT_UNUSED"),
        .port_locked             ("PORT_USED"),
        .port_pfdena             ("PORT_UNUSED"),
        .port_phasecounterselect ("PORT_UNUSED"),
        .port_phasedone          ("PORT_UNUSED"),
        .port_phasestep          ("PORT_UNUSED"),
        .port_phaseupdown        ("PORT_UNUSED"),
        .port_pllena             ("PORT_UNUSED"),
        .port_scanaclr           ("PORT_UNUSED"),
        .port_scanclk            ("PORT_UNUSED"),
        .port_scanclkena         ("PORT_UNUSED"),
        .port_scandata           ("PORT_UNUSED"),
        .port_scandataout        ("PORT_UNUSED"),
        .port_scandone           ("PORT_UNUSED"),
        .port_scanread           ("PORT_UNUSED"),
        .port_scanwrite          ("PORT_UNUSED"),
        .port_clk0               ("PORT_USED"),
        .port_clk1               ("PORT_UNUSED"),
        .port_clk2               ("PORT_UNUSED"),
        .port_clk3               ("PORT_UNUSED"),
        .port_clk4               ("PORT_UNUSED"),
        .port_clk5               ("PORT_UNUSED"),
        .port_clkena0            ("PORT_UNUSED"),
        .port_clkena1            ("PORT_UNUSED"),
        .port_clkena2            ("PORT_UNUSED"),
        .port_clkena3            ("PORT_UNUSED"),
        .port_clkena4            ("PORT_UNUSED"),
        .port_clkena5            ("PORT_UNUSED"),
        .port_extclk0            ("PORT_UNUSED"),
        .port_extclk1            ("PORT_UNUSED"),
        .port_extclk2            ("PORT_UNUSED"),
        .port_extclk3            ("PORT_UNUSED"),
        .self_reset_on_loss_lock ("OFF"),
        .width_clock             (5)
    ) u_pll (
        .areset (1'b0),
        .inclk  ({1'b0, MAX10_CLK1_50}),
        .clk    (pll_clk),
        .locked (pll_locked)
    );
    wire clk = pll_clk[0];

    // ---- reset: the PLL not locked, or KEY0 held for 20 ms ------------------
    // (KEY0 is debounced by the board's Schmitt trigger; the 20 ms filter also
    // keeps a glitch on it from restarting the demo)
    wire rst_async = !pll_locked;
    reg  [3:0] rst_sync = 4'hF;
    always @(posedge clk or posedge rst_async) begin
        if (rst_async) rst_sync <= 4'hF;
        else           rst_sync <= {rst_sync[2:0], 1'b0};
    end
    localparam integer KEY0_CYC = CORE_HZ / 50;           // 20 ms
    reg  [1:0]  k0_s = 2'b00;
    reg  [19:0] k0_cnt = 20'd0;
    reg         k0_rst = 1'b0;
    always @(posedge clk) begin
        k0_s <= {k0_s[0], !KEY[0]};
        if (!k0_s[1]) begin k0_cnt <= 20'd0; k0_rst <= 1'b0; end
        else if (k0_cnt == KEY0_CYC - 1) k0_rst <= 1'b1;
        else k0_cnt <= k0_cnt + 20'd1;
    end
    wire rst = rst_sync[3] | k0_rst;

    // ---- the board ---------------------------------------------------------
    wire [47:0] hex_n;
    wire        host_tx, sonar_trig, lamp_green, lamp_white, lamp_red, lamp_closed, buzzer, buzzer_tone;
    lanex_board #(.CLK_HZ(CORE_HZ), .PRESENT_MM(PRESENT_MM), .TALL_MM(TALL_MM)) u_board (
        .clk         (clk),
        .rst         (rst),
        .sw          (SW),
        .key1_n      (KEY[1]),
        .sonar_echo  (GPIO[2]),
        .sonar_trig  (sonar_trig),
        .host_rx     (GPIO[0]),
        .host_tx     (host_tx),
        .hex_n       (hex_n),
        .ledr        (LEDR),
        .lamp_green  (lamp_green),
        .lamp_white  (lamp_white),
        .lamp_red    (lamp_red),
        .lamp_closed (lamp_closed),
        .buzzer      (buzzer),
        .buzzer_tone (buzzer_tone)
    );
    assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = hex_n;

    assign GPIO[0]    = 1'bz;        // inputs
    assign GPIO[2]    = 1'bz;
    assign GPIO[3]    = sonar_trig;
    assign GPIO[1]    = host_tx;
    assign GPIO[4]    = lamp_green;
    assign GPIO[5]    = lamp_white;
    assign GPIO[6]    = lamp_red;
    assign GPIO[7]    = buzzer;
    assign GPIO[8]    = lamp_closed;
    assign GPIO[9]    = buzzer_tone;
    assign GPIO[35:10] = {26{1'bz}};
endmodule

`default_nettype wire
