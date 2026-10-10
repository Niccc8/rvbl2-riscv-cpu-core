// altpll_stub.v - a lint/elaboration stand-in for Quartus's altpll megafunction,
// so lanex_de10lite elaborates in Icarus and Verilator. clk[0] simply follows
// inclk[0]: the testbenches drive lanex_board with the core clock directly.
// Never part of the Quartus project (lanex.qsf does not list it).
module altpll #(
    parameter bandwidth_type = "AUTO", parameter clk0_divide_by = 1, parameter clk0_duty_cycle = 50,
    parameter clk0_multiply_by = 1, parameter clk0_phase_shift = "0", parameter compensate_clock = "CLK0",
    parameter inclk0_input_frequency = 20000, parameter intended_device_family = "MAX 10",
    parameter lpm_hint = "", parameter lpm_type = "altpll", parameter operation_mode = "NORMAL",
    parameter pll_type = "AUTO", parameter port_activeclock = "", parameter port_areset = "",
    parameter port_clkbad0 = "", parameter port_clkbad1 = "", parameter port_clkloss = "",
    parameter port_clkswitch = "", parameter port_configupdate = "", parameter port_fbin = "",
    parameter port_inclk0 = "", parameter port_inclk1 = "", parameter port_locked = "",
    parameter port_pfdena = "", parameter port_phasecounterselect = "", parameter port_phasedone = "",
    parameter port_phasestep = "", parameter port_phaseupdown = "", parameter port_pllena = "",
    parameter port_scanaclr = "", parameter port_scanclk = "", parameter port_scanclkena = "",
    parameter port_scandata = "", parameter port_scandataout = "", parameter port_scandone = "",
    parameter port_scanread = "", parameter port_scanwrite = "", parameter port_clk0 = "",
    parameter port_clk1 = "", parameter port_clk2 = "", parameter port_clk3 = "", parameter port_clk4 = "",
    parameter port_clk5 = "", parameter port_clkena0 = "", parameter port_clkena1 = "",
    parameter port_clkena2 = "", parameter port_clkena3 = "", parameter port_clkena4 = "",
    parameter port_clkena5 = "", parameter port_extclk0 = "", parameter port_extclk1 = "",
    parameter port_extclk2 = "", parameter port_extclk3 = "", parameter self_reset_on_loss_lock = "OFF",
    parameter width_clock = 5
) (
    input  wire                   areset,
    input  wire [1:0]             inclk,
    output wire [width_clock-1:0] clk,
    output wire                   locked
);
    assign clk    = {{(width_clock - 1){1'b0}}, inclk[0]};
    assign locked = !areset;
endmodule
