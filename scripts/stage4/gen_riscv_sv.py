#!/usr/bin/env python3
"""gen_riscv_sv.py - build stage4/riscv.sv, the one file we paste into the AWS FPGA
project next to the organisers' unchanged top.sv.

    python scripts/stage4/gen_riscv_sv.py            # write stage4/riscv.sv
    python scripts/stage4/gen_riscv_sv.py --check    # fail if stage4/riscv.sv is stale

One source of truth: the file is generated from rtl/*.v and the firmware image,
never edited by hand. rtl/ itself is not modified, so the ASIC sign-off stays valid.
What the generator does (docs/stage4/04_fpga_plan.md section 3.2):

  * every module of rtl/ gets the prefix rvbl2_ (our chip `top` would collide with
    the AWS `top`; `alu`, `uart`, ... could collide with HDK sources);
  * `ifdef/`ifndef are resolved as Vivado synthesis sees them (SYNTHESIS defined,
    DMEM_USE_SRAM_MACRO not), so no directive reaches the file;
  * FPGA-only edits, each matched exactly once or the run fails:
      - riscv_core exports its PC (pc_o), and the chip top names it w_PC_Output,
        the wire top.sv reads as riscvtop.e_PROCESSOR.w_PC_Output;
      - the chip top samples its pins through a 2-flip-flop synchroniser (they
        come from top.sv's 250 MHz registers);
      - dmem loses (* keep *) (an ASIC-flow workaround that could stop Vivado
        inferring block RAM);
      - imem becomes a literal case ROM equal to firmware.hex word for word;
  * the shell module RISCV (ports exactly as top.sv instantiates it) divides
    clk_main_a0 by 8 with an MMCM (31.25 MHz, the ASIC's own operating point),
    synchronises reset, and runs the
    chip as instance e_PROCESSOR; Transmitter and Receiver are the modules top.sv
    instantiates, with the behaviour emu needs (sticky o_Tx_Done, one-cycle
    o_Rx_Done).

--clock mmcm_slow divides by 16 (15.625 MHz: the timing backup) and --clock
bufgce_div swaps the MMCM for a BUFGCE_DIV /8 (the primitive backup); --core-hz and
--mutate exist for the pre-flight gate's mutation tests only.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RTL = os.path.join(ROOT, "rtl")
HEX = os.path.join(ROOT, "application", "firmware", "out", "lane", "firmware.hex")
OUT = os.path.join(ROOT, "stage4", "riscv.sv")
PREFIX = "rvbl2_"
CORE_HZ = {"mmcm": 31250000, "mmcm_slow": 15625000, "bufgce_div": 31250000}   # 250 MHz / 8, / 16, / 8
MMCM_DIV = {"mmcm": 32, "mmcm_slow": 64}   # CLKOUT0 = 1000 MHz VCO / this
SV_RESERVED_MODULES = {"top", "tick_gen", "Transmitter", "Receiver", "RISCV", "sh_ddr"}


def resolve_ifdefs(text, defined):
    """Keep the branches Vivado synthesis would keep; drop the directives."""
    out, stack = [], []          # stack of (taking, any_branch_taken)
    for line in text.splitlines(keepends=True):
        m = re.match(r"\s*`(ifdef|ifndef|else|endif)\b\s*(\w*)", line)
        if m:
            kw, name = m.groups()
            if kw in ("ifdef", "ifndef"):
                cond = (name in defined) == (kw == "ifdef")
                parent = all(t for t, _ in stack)
                stack.append((parent and cond, cond))
            elif kw == "else":
                taking, cond = stack.pop()
                parent = all(t for t, _ in stack)
                stack.append((parent and not cond, True))
            else:
                stack.pop()
            continue
        if all(t for t, _ in stack):
            out.append(line)
    assert not stack, "unbalanced `ifdef"
    return "".join(out)


def once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit("gen_riscv_sv: expected one match for %s, found %d" % (what, n))
    return text.replace(old, new)


def load_rom():
    words = []
    for line in open(HEX):
        line = line.strip()
        if line and not line.startswith("//") and not line.startswith("@"):
            words.append(int(line, 16))
    return words


def rom_crc(words):
    """The Xicrc CRC-16 the 'I' record reports (lane_model.rom_crc)."""
    crc = 0xFFFF
    for w in words:
        for i in range(31, -1, -1):
            bit = (w >> i) & 1
            msb = (crc >> 15) & 1
            crc = (crc << 1) & 0xFFFF
            if msb ^ bit:
                crc ^= 0x1021
    return crc


def imem_module(words):
    lines = [
        "// Instruction ROM: the LaneX firmware, word for word as firmware.hex (generated).",
        "// Same ports and read behaviour as rtl/imem.v: combinational, 0 outside the image",
        "// or when not selected.",
        "module %simem #(" % PREFIX,
        "    parameter IMEM_WORDS = 4096",
        ") (",
        "    input  wire [31:0] address_i,",
        "    input  wire        oe_i,",
        "    output reg  [31:0] data_o",
        ");",
        "    wire [19:0] word_addr = address_i[21:2];",
        "    wire        impl_sel  = (word_addr < IMEM_WORDS);",
        "    reg  [31:0] rom_word;",
        "    always @(*) begin",
        "        case (word_addr[11:0])",
    ]
    for i, w in enumerate(words):
        lines.append("            12'd%d: rom_word = 32'h%08x;" % (i, w))
    lines += [
        "            default: rom_word = 32'h00000000;",
        "        endcase",
        "        data_o = (oe_i && impl_sel) ? rom_word : 32'b0;",
        "    end",
        "endmodule",
        "",
    ]
    return "\n".join(lines)


SHELL_MMCM = """\
    // 250 MHz -> CORE_MHZ MHz. MMCME4_BASE: VCO = 250 x 4 = 1000 MHz (legal 800-1600),
    // CLKOUT0 = 1000 / MMCMDIV. Internal feedback; LOCKED holds the core in reset.
    wire clk_fb, clk_div, clk_locked;
    MMCME4_BASE #(
        .CLKIN1_PERIOD    (4.000),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (4.000),
        .CLKOUT0_DIVIDE_F (MMCMDIV.000)
    ) u_mmcm (
        .CLKIN1   (i_Clk),
        .RST      (1'b0),
        .PWRDWN   (1'b0),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_div),
        .LOCKED   (clk_locked)
    );
    BUFG u_bufg (.I(clk_div), .O(clk_core));
"""

SHELL_BUFGCE_DIV = """\
    // 250 MHz -> 31.25 MHz: a global clock buffer dividing by 8 (no lock to wait for).
    wire clk_locked = 1'b1;
    BUFGCE_DIV #(.BUFGCE_DIVIDE(8)) u_bufg_div (
        .I(i_Clk), .CE(1'b1), .CLR(1'b0), .O(clk_core)
    );
"""

SHELL = """\
// ============================================================================
// RISCV - the module top.sv instantiates as `riscvtop`. FPGA-only shell around
// the RVBL-2 chip (instance e_PROCESSOR, exactly as verified), so top.sv is used
// unchanged:
//   * the clock: our multicycle core was signed off at 33 ns (Sky130) and cannot
//     run at 250 MHz; it runs from clk_main_a0 divided down (CORE_MHZ MHz). Our
//     estimate of its longest path on this FPGA: 11 ns typical, 18 ns pessimistic;
//   * the reset: i_Nrst is top.sv's riscv_nreset (active low, 250 MHz domain);
//     it is synchronised into the core clock (asynchronous assert, synchronous
//     release) and also held while the clock is not yet locked;
//   * io_Pins: driven by the chip's own tri-state pattern, the one top.sv uses.
// ============================================================================
module RISCV (
    input  wire       i_Rx_Serial,
    input  wire       i_Clk,
    input  wire       i_nRst,
    output wire       o_Tx_Serial,
    inout  wire [7:0] io_Pins
);
    wire clk_core;
CLOCK
    wire rst_async = ~i_nRst | ~clk_locked;
    reg  [1:0] rst_sync = 2'b11;
    always @(posedge clk_core or posedge rst_async) begin
        if (rst_async) rst_sync <= 2'b11;
        else           rst_sync <= {rst_sync[0], 1'b0};
    end

    PREFIXtop #(
        .UART_CLK_FREQ_HZ (CORE_HZ),
        .UART_BAUD_RATE   (115200)
    ) e_PROCESSOR (
        .clk_i   (clk_core),
        .rst_i   (rst_sync[1]),
        .pins_io (io_Pins),
        .tx_o    (o_Tx_Serial),
        .rx_i    (i_Rx_Serial)
    );
endmodule

// ============================================================================
// Transmitter / Receiver - instantiated by top.sv (p_CLKS_PER_BIT = 2170 at
// 250 MHz = 115,200 bps), between its AXI registers and our chip's UART.
// 8-N-1, LSB first. Behaviour emu relies on:
//   Transmitter: one byte per one-cycle i_Tx_Transmit pulse; o_Tx_Serial idles
//     high, also in reset; o_Tx_Done is a LEVEL: 1 out of reset and once the
//     stop bit is sent, 0 while a byte is in flight (emu polls it 50 ms later).
//   Receiver: o_Rx_Done is high for exactly ONE cycle per byte, with o_Rx_Byte
//     valid in that cycle (top.sv advances its FIFO pointer every cycle it is
//     high); i_Rx_Serial comes from our core clock domain: 2-flip-flop
//     synchroniser.
// ============================================================================
module Transmitter #(
    parameter integer p_CLKS_PER_BIT = 2170
) (
    input  wire       i_Clk,
    input  wire       i_Rst,
    input  wire       i_Tx_Transmit,
    input  wire [7:0] i_Tx_Byte,
    output reg        o_Tx_Serial,
    output reg        o_Tx_Done
);
    localparam integer CW = $clog2(p_CLKS_PER_BIT);
    reg [CW-1:0] r_Count;
    reg [3:0]    r_Bit;          // on the line: 0 start, 1..8 data bit r_Bit-1, 9 stop
    reg [7:0]    r_Byte;
    reg          r_Busy;
    wire [3:0]   w_Next = r_Bit + 4'd1;
    always @(posedge i_Clk) begin
        if (i_Rst) begin
            o_Tx_Serial <= 1'b1;
            o_Tx_Done   <= 1'b1;
            r_Busy      <= 1'b0;
            r_Count     <= {CW{1'b0}};
            r_Bit       <= 4'd0;
            r_Byte      <= 8'h00;
        end else if (!r_Busy) begin
            if (i_Tx_Transmit) begin
                o_Tx_Serial <= 1'b0;                     // start bit
                o_Tx_Done   <= 1'b0;
                r_Busy      <= 1'b1;
                r_Byte      <= i_Tx_Byte;
                r_Bit       <= 4'd0;
                r_Count     <= {CW{1'b0}};
            end else begin
                o_Tx_Serial <= 1'b1;
            end
        end else if (r_Count != p_CLKS_PER_BIT[CW-1:0] - 1'b1) begin
            r_Count <= r_Count + 1'b1;
        end else begin
            r_Count <= {CW{1'b0}};
            if (r_Bit == 4'd9) begin                     // stop bit sent
                r_Busy    <= 1'b0;
                o_Tx_Done <= 1'b1;
            end else begin
                r_Bit       <= w_Next;
                o_Tx_Serial <= (w_Next == 4'd9) ? 1'b1 : r_Byte[w_Next[2:0] - 3'd1];
            end
        end
    end
endmodule

module Receiver #(
    parameter integer p_CLKS_PER_BIT = 2170
) (
    input  wire       i_Clk,
    input  wire       i_Rst,
    input  wire       i_Rx_Serial,
    output reg        o_Rx_Done,
    output reg  [7:0] o_Rx_Byte
);
    localparam integer CW = $clog2(p_CLKS_PER_BIT);
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;
    reg          r_S1, r_S2;
    reg [1:0]    r_State;
    reg [CW-1:0] r_Count;
    reg [2:0]    r_Bit;
    reg [7:0]    r_Byte;
    always @(posedge i_Clk) begin
        if (i_Rst) begin
            r_S1      <= 1'b1;
            r_S2      <= 1'b1;
            r_State   <= S_IDLE;
            r_Count   <= {CW{1'b0}};
            r_Bit     <= 3'd0;
            r_Byte    <= 8'h00;
            o_Rx_Done <= 1'b0;
            o_Rx_Byte <= 8'h00;
        end else begin
            r_S1      <= i_Rx_Serial;
            r_S2      <= r_S1;
            o_Rx_Done <= 1'b0;
            case (r_State)
                S_IDLE:
                    if (!r_S2) begin
                        r_State <= S_START;
                        r_Count <= {CW{1'b0}};
                    end
                S_START:                                 // confirm at mid-bit
                    if (r_Count == p_CLKS_PER_BIT[CW-1:0] / 2) begin
                        r_State <= r_S2 ? S_IDLE : S_DATA;
                        r_Count <= {CW{1'b0}};
                        r_Bit   <= 3'd0;
                    end else begin
                        r_Count <= r_Count + 1'b1;
                    end
                S_DATA:
                    if (r_Count == p_CLKS_PER_BIT[CW-1:0] - 1'b1) begin
                        r_Count        <= {CW{1'b0}};
                        r_Byte[r_Bit]  <= r_S2;
                        if (r_Bit == 3'd7) r_State <= S_STOP;
                        r_Bit          <= r_Bit + 3'd1;
                    end else begin
                        r_Count <= r_Count + 1'b1;
                    end
                default:                                 // S_STOP: mid stop bit
                    if (r_Count == p_CLKS_PER_BIT[CW-1:0] - 1'b1) begin
                        o_Rx_Done <= 1'b1;
                        o_Rx_Byte <= r_Byte;
                        r_State   <= S_IDLE;
                        r_Count   <= {CW{1'b0}};
                    end else begin
                        r_Count <= r_Count + 1'b1;
                    end
            endcase
        end
    end
endmodule
"""


def chip_modules(words, target="aws", mutate=None):
    """The RVBL-2 chip as rvbl2_* modules: rtl/*.v with the FPGA edits, then the
    firmware ROM. target "aws" is the AWS F2 build (pins on top.sv's inout bus);
    target "de10lite" is the DE10-Lite board (scripts/stage4/gen_de10lite.py),
    which differs only where a MAX 10 has no internal tri-state and where Quartus
    wants its RAM coded its own way (DE10LITE_* below)."""
    srcs = sorted(f for f in os.listdir(RTL) if f.endswith(".v"))
    texts = {f: open(os.path.join(RTL, f), encoding="utf-8").read() for f in srcs}
    names = []
    for f, t in texts.items():
        names += re.findall(r"^\s*module\s+(\w+)", t, re.M)
    clash = SV_RESERVED_MODULES & {PREFIX + n for n in names}
    assert not clash, clash
    body = []
    for f in srcs:
        t = resolve_ifdefs(texts[f], {"SYNTHESIS"})
        if f == "imem.v":
            continue                                      # replaced by the ROM below
        if f == "dmem.v":
            if target == "de10lite":
                t = once(t, DMEM_BEHAVIOURAL_NOTES, DE10LITE_DMEM_NOTE, "dmem notes")
                t = once(t, DMEM_SIM_NOTE, "", "dmem simulation note")
                t = once(t, "    (* keep *) reg [31:0] mem [0:DMEM_WORDS-1];\n", "", "dmem array")
                t = once(t, "    reg [31:0] data_r;\n    assign data_o = data_r;\n", "", "dmem data_r")
                t = once(t, DMEM_BEHAVIOURAL, DE10LITE_DMEM, "dmem realization")
            else:
                t = once(t, "(* keep *) reg [31:0] mem [0:DMEM_WORDS-1];",
                         "reg [31:0] mem [0:DMEM_WORDS-1];", "dmem keep")
        if f == "riscv_core.v":
            t = once(t, "    (* keep *) output wire sys_event_o\n);",
                     "    (* keep *) output wire sys_event_o,\n"
                     "    output wire [31:0] pc_o          // FPGA: the PC, for top.sv's 0x1C readback\n);",
                     "core pc port")
            t = once(t, "    assign address_o = addr_src_sel ? alu_result : pc;",
                     "    assign address_o = addr_src_sel ? alu_result : pc;\n    assign pc_o      = pc;",
                     "core pc assign")
        if f == "top.v":
            t = once(t, '    parameter IMEM_INIT_FILE   = "tests/progs/tb_firmware_prog.hex",\n', "",
                     "top init file parameter")
            t = once(t, "imem #(.IMEM_WORDS(IMEM_WORDS), .INIT_FILE(IMEM_INIT_FILE)) u_imem (",
                     "imem #(.IMEM_WORDS(IMEM_WORDS)) u_imem (", "top imem instance")
            t = once(t, ".store_data_o(core_store_data), .sys_event_o(sys_event_o)",
                     ".store_data_o(core_store_data), .sys_event_o(sys_event_o),\n"
                     "        .pc_o(w_PC_Output)", "top core instance")
            t = once(t, "    riscv_core u_core (",
                     "    // top.sv reads this wire as riscvtop.e_PROCESSOR.w_PC_Output (0x1C)\n"
                     "    wire [31:0] w_PC_Output;\n    riscv_core u_core (", "top pc wire")
            src = "pins_io"
            if target == "de10lite":
                t = once(t, "    inout  wire [7:0] pins_io,\n", DE10LITE_PIN_PORTS, "top pin ports")
                t = once(t, DE10LITE_PAD_OLD, DE10LITE_PAD_NEW, "top pad tri-state")
                t = once(t, "    assign gpio_i = pins_io;", "    assign gpio_i = pins_i;", "top pin input")
                src = "pins_i"
            t = once(t, "    assign gpio_i = %s;" % src,
                     "    // FPGA: the pins come from %s; sample them\n"
                     "    // through two flip-flops in this clock domain\n"
                     "    reg [7:0] pins_s1, pins_s2;\n"
                     "    always @(posedge clk_i) begin\n"
                     "        pins_s1 <= %s;\n"
                     "        pins_s2 <= pins_s1;\n"
                     "    end\n"
                     "    assign gpio_i = pins_s2;" % (
                         "the board fabric" if target == "de10lite" else "top.sv's 250 MHz registers", src),
                     "top pin synchroniser")
            if mutate == "pins":
                t = once(t, "assign pins_io[n] = gpio_oe[n] ? gpio_o[n] : 1'bz;",
                         "assign pins_io[n] = !gpio_oe[n] ? gpio_o[n] : 1'bz;", "mutation pins")
        # prefix module declarations and instantiations
        for n in names:
            t = re.sub(r"^(\s*module\s+)%s\b" % n, r"\g<1>%s%s" % (PREFIX, n), t, flags=re.M)
            t = re.sub(r"^(\s*)%s(\s*#\s*\(|\s+u_\w+\s*\()" % n, r"\g<1>%s%s\g<2>" % (PREFIX, n), t,
                       flags=re.M)
        body.append("// ---- from rtl/%s " % f + "-" * max(0, 70 - len(f)) + "\n" + t.strip() + "\n")
    body.append(imem_module(words))
    return body


# ---- DE10-Lite target (MAX 10): the only differences from the AWS chip ------
# 1. A MAX 10 has no internal tri-state and the chip is not at the FPGA's pins:
#    top.v's pad tri-state (Figure 1) is resolved in the board fabric instead,
#    value for value: pins_i[n] = pins_oe[n] ? pins_o[n] : the outside level.
DE10LITE_PIN_PORTS = """\
    output wire [7:0] pins_o,     // DE10-Lite: the pad tri-state is resolved in the
    output wire [7:0] pins_oe,    // board fabric (a MAX 10 has no internal tri-state):
    input  wire [7:0] pins_i,     // pins_i = pins_oe ? pins_o : the outside level
"""
DE10LITE_PAD_OLD = """\
    genvar n;
    generate
        for (n = 0; n < 8; n = n + 1) begin : g_pad
            assign pins_io[n] = gpio_oe[n] ? gpio_o[n] : 1'bz;
        end
    endgenerate
"""
DE10LITE_PAD_NEW = """\
    assign pins_o  = gpio_o;
    assign pins_oe = gpio_oe;
"""
# 2. The data RAM in the form Quartus documents for M9K inference: one RAM per
#    byte lane, a plain write enable, a registered read. Same behaviour at the
#    ports as rtl/dmem.v for every access: a read cycle presents the word on
#    data_o one cycle later; after a write cycle, or a cycle with neither,
#    data_o keeps its value (DMEM_WORDS = 2048 fills the 8 KB window, so
#    impl_sel is always 1). Zero at power-up, as an M9K is.
DMEM_BEHAVIOURAL_NOTES = """\
    // ------------------------------------------------------------------
    // Behavioral realization (default): a register array.
    // ------------------------------------------------------------------
    // (* keep *) prevents synthesis tools from concluding this array is
    // unobservable dead logic. `top` deliberately has zero data outputs
    // (Block Guide S2.2), so a naive RTL-to-gate flow that eliminates logic
    // with no path to a primary output would otherwise remove this entire
    // design. Purely a synthesis hint; has no effect on simulation.
"""
DE10LITE_DMEM_NOTE = """\
    // ------------------------------------------------------------------
    // DE10-Lite realization (generated): byte-lane M9K RAMs, below.
    // ------------------------------------------------------------------
"""
# (its "// synthesis ..." line would read as a directive to Quartus, and it
# describes code this realization does not have)
DMEM_SIM_NOTE = """\
    // Simulation-only zero-fill for waveform determinism. Fenced off from
    // synthesis so it cannot attach init values to 65,536 flip-flops that
    // deliberately have no hardware reset network. Synthesis must therefore
    // define SYNTHESIS - scripts/synth_yosys_generic.sh passes -DSYNTHESIS and
    // openlane/config.json sets SYNTH_DEFINES for the same reason.
"""
DMEM_BEHAVIOURAL = """\
    always @(posedge clk_i) begin
        if (we_i && impl_sel) begin
            if (bw_i[0]) mem[phys_addr][7:0]   <= data_i[7:0];
            if (bw_i[1]) mem[phys_addr][15:8]  <= data_i[15:8];
            if (bw_i[2]) mem[phys_addr][23:16] <= data_i[23:16];
            if (bw_i[3]) mem[phys_addr][31:24] <= data_i[31:24];
        end else if (oe_i) begin
            data_r <= impl_sel ? mem[phys_addr] : 32'b0;
        end
    end
"""
DE10LITE_DMEM = """\
    // DE10-Lite: four byte-lane RAMs (M9K blocks)
    (* ramstyle = "M9K" *) reg [7:0] ram0 [0:DMEM_WORDS-1];
    (* ramstyle = "M9K" *) reg [7:0] ram1 [0:DMEM_WORDS-1];
    (* ramstyle = "M9K" *) reg [7:0] ram2 [0:DMEM_WORDS-1];
    (* ramstyle = "M9K" *) reg [7:0] ram3 [0:DMEM_WORDS-1];
    integer z;
    initial begin
        for (z = 0; z < DMEM_WORDS; z = z + 1) begin
            ram0[z] = 8'h00; ram1[z] = 8'h00; ram2[z] = 8'h00; ram3[z] = 8'h00;
        end
    end
    wire        wr = we_i && impl_sel;
    reg  [7:0]  q0, q1, q2, q3;
    reg         rd_q, sel_q;
    reg  [31:0] data_r;           // data_o's held value
    always @(posedge clk_i) begin
        if (wr && bw_i[0]) ram0[phys_addr] <= data_i[7:0];
        if (wr && bw_i[1]) ram1[phys_addr] <= data_i[15:8];
        if (wr && bw_i[2]) ram2[phys_addr] <= data_i[23:16];
        if (wr && bw_i[3]) ram3[phys_addr] <= data_i[31:24];
        q0 <= ram0[phys_addr];
        q1 <= ram1[phys_addr];
        q2 <= ram2[phys_addr];
        q3 <= ram3[phys_addr];
    end
    always @(posedge clk_i) begin
        rd_q   <= oe_i && !wr;
        sel_q  <= impl_sel;
        data_r <= data_o;
    end
    assign data_o = rd_q ? (sel_q ? {q3, q2, q1, q0} : 32'b0) : data_r;
"""


def build(args):
    words = load_rom()
    body = chip_modules(words, "aws", args.mutate)
    shell = SHELL.replace("CLOCK", SHELL_BUFGCE_DIV if args.clock == "bufgce_div" else
                          SHELL_MMCM.replace("MMCMDIV", str(MMCM_DIV[args.clock])))
    shell = shell.replace("CORE_MHZ", ("%.3f" % (args.core_hz / 1e6)).rstrip("0").rstrip("."))
    shell = shell.replace("PREFIXtop", PREFIX + "top").replace("CORE_HZ", str(args.core_hz))
    shell = shell.replace("i_Nrst", "i_nRst")
    if args.mutate == "reset":
        shell = once(shell, "wire rst_async = ~i_nRst | ~clk_locked;",
                     "wire rst_async = i_nRst | ~clk_locked;", "mutation reset")
    if args.mutate == "rxdone":                     # o_Rx_Done as a level, not a pulse
        shell = once(shell, "            o_Rx_Done <= 1'b0;\n            case (r_State)",
                     "            case (r_State)", "mutation rxdone")
    if args.mutate == "txdone":
        shell = once(shell, "                r_Busy    <= 1'b0;\n                o_Tx_Done <= 1'b1;",
                     "                r_Busy    <= 1'b0;\n                o_Tx_Done <= 1'b0;", "mutation txdone")
    hexsha = hashlib.sha256(open(HEX, "rb").read()).hexdigest()
    try:
        commit = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                                capture_output=True, text=True).stdout.strip()
    except OSError:
        commit = "?"
    head = [
        "// ============================================================================",
        "// riscv.sv - RVBL-2 + LaneX for the organisers' AWS F2 top.sv (Stage 4).",
        "// GENERATED by scripts/stage4/gen_riscv_sv.py from rtl/*.v and the firmware",
        "// image. Do not edit: regenerate. Paste it unchanged next to top.sv.",
        "//",
        "//   rtl commit (at generation): %s" % commit,
        "//   firmware.hex sha256:        %s" % hexsha,
        "//   ROM: %d words; the 'I' record must report rom_words %d, rom_crc 0x%04X" % (
            len(words), len(words), rom_crc(words)),
        "//   core clock %d Hz (%s); UART %d clocks/bit at 115,200 bps" % (
            args.core_hz, "BUFGCE_DIV" if args.clock == "bufgce_div" else "MMCM",
            (args.core_hz + 57600) // 115200),
        "//   modules: RISCV, Transmitter, Receiver, and rvbl2_* (no other names)",
        "// ============================================================================",
        "",
    ]
    if args.mutate:
        head.insert(1, "// MUTANT (%s) - for the pre-flight gate's mutation test only. NEVER UPLOAD." % args.mutate)
    return "\n".join(head) + SHELL_HEADER_SEP + shell + "\n" + "\n".join(body)


SHELL_HEADER_SEP = ""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--check", action="store_true", help="fail if --out differs from a fresh build")
    ap.add_argument("--clock", choices=("mmcm", "mmcm_slow", "bufgce_div"), default="mmcm")
    ap.add_argument("--core-hz", type=int, default=None,
                    help="the core clock the UART divider assumes (mutation tests only)")
    ap.add_argument("--mutate", choices=("reset", "txdone", "rxdone", "pins"), default=None)
    args = ap.parse_args()
    if args.core_hz is None:
        args.core_hz = CORE_HZ[args.clock]
    text = build(args)
    if args.check:
        old = open(args.out, encoding="utf-8").read() if os.path.exists(args.out) else ""
        # the commit line legitimately changes with every commit
        strip = lambda s: re.sub(r"rtl commit \(at generation\): \S*", "", s)
        if strip(old) != strip(text):
            sys.exit("%s is stale: run scripts/stage4/gen_riscv_sv.py" % os.path.relpath(args.out, ROOT))
        print("%s is current" % os.path.relpath(args.out, ROOT))
        return
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote %s: %d lines, %d bytes" % (os.path.relpath(args.out, ROOT), text.count("\n"), len(text)))


if __name__ == "__main__":
    main()
