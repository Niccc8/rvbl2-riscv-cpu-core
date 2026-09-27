# GPIO and UART integration

**Stage 3 brief §2.** How the pin controller (GPIO) and the serial controller (UART) are
added to the RVBL-2 processor, and the design decisions behind them.

## 1. Where the peripherals sit

```text
                         +--------------------- rvbl2_soc (the SoC, a canvas project) ------------------+
                         |                                                                              |
  clk_i, rst_i --------->|  RISC-V core ---address, data, we, oe, byte enables---> address decoder      |
                         |                                                            |   |    |        |
                         |                                   0x0040_0000 (IMEM) <-----+   |    |        |
                         |                                   0x1001_0000 (DMEM) <---------+    |        |
                         |                                   0xF000_0000 - 0xFFFF_FFFF <-------+        |
                         |                                        | peripheral bus (one write strobe)   |
                         |                          +-------------+--------------+                      |
                         |                          |                            |                      |
                         |                     GPIO (slot 0)               UART (slot 1)                |
                         |                     0xF000_0000                 0xF100_0000                  |
                         |                          |  gpio_o, gpio_oe, gpio_i   |  tx_o, rx_i          |
                         +--------------------------+----------------------------+----------------------+
                                                    |                            |
  top (the chip) -------------------------- 8 Inout Pins P0..P7              tx_o, rx_i
```

- **One region for all peripherals.** The address decoder routes `0xF000_0000` to
  `0xFFFF_FFFF` to the peripheral bus. The region has 16 slots of 16 MB; address bits
  27:24 select the slot. The GPIO is slot 0 (`0xF000_0000`), the UART slot 1
  (`0xF100_0000`). Each peripheral decodes its own slot and register, so adding a
  peripheral changes no other block.
- **Read data comes back through a chain.** The decoder's chain output (zero) enters the
  GPIO, the GPIO's output enters the UART, and the UART's output returns to the decoder.
  Each peripheral ORs in its register only when it is addressed.
- **Reads have no side effects.** The core holds a load's address and read enable for two
  cycles, so an action on read would happen twice. No register changes when it is read.
- **Byte enables are honoured**, so `sb`, `sh` and `sw` all work. Every field is in byte 0.

## 2. GPIO (PIN controller)

| Offset | Register | Access | Meaning |
|---|---|---|---|
| 0x0 | DATAOUT | RW | Level driven on each output pin |
| 0x4 | DATAIN | R | Level on each input pin |
| 0x8 | DATADIR | RW | Direction of each pin: 0 input, 1 output |

- **The tri-state is at the chip's edge.** The GPIO block has two outputs per pin:
  `gpio_oe` (from DATADIR, the driver enable) and `gpio_o` (from DATAOUT, the level). The
  ChipInventor Inout Pin in `top` makes the tri-state buffer of the Block Guide's Figure 1:
  its D input is the enable, its C input the level. The block itself contains no tri-state,
  so the same block also works in an FPGA, where internal tri-states do not exist.
- **Safe reset.** After reset every pin is an input and DATAOUT is 0: the chip drives
  nothing until the firmware says so.
- **Synchroniser.** Each input passes two flip-flops before it is used, because the outside
  world changes at any time. The second flip-flop is Figure 1's DATAIN flip-flop.
- **An output pin reads 0 in DATAIN**, because Figure 1's input buffer is enabled only in
  input mode.
- **8 pins**, set by the parameter `N_PINS` (up to 32).

## 3. UART (serial controller)

| Offset | Register | Access | Meaning |
|---|---|---|---|
| 0x0 | TXDATA | RW | The byte to send |
| 0x4 | RXDATA | R | The last byte received |
| 0x8 | CONTROL | see below | bit 0 TRANSMIT, bit 1 RXDONE, bit 2 TXDONE |

- **Frame:** 8-N-1: a start bit, 8 data bits least-significant first, one stop bit.
- **Baud rate:** 115,200 bps from the chip's 30.303 MHz clock (33 ns): 263 clock cycles per
  bit. The divisor is computed from two parameters, `CLK_FREQ_HZ` and `BAUD_RATE`.
- **TRANSMIT** (write 1): starts sending TXDATA if the transmitter is free, and clears
  itself on the next cycle (it always reads 0). TXDATA is copied at the start, so software
  can write the next byte during a transmission.
- **TXDONE** (read only): 1 when the transmitter is free. It is 1 after reset.
- **RXDONE**: set when a byte arrives; software clears it by writing 0. If a byte arrives in
  the same cycle as the clear, the new byte wins, so no byte is lost without trace.
- **Receiver:** no oversampling, as the Block Guide says. The start edge is found at clock
  rate, checked again in the middle of the start bit (a glitch is ignored), and each data bit
  is sampled once, in its middle. This works with the far end's clock up to ±3.5 % off.
- **Errors:** a frame with a bad stop bit (framing error, or a break) is dropped. A new byte
  that arrives before software reads the last one overwrites RXDATA.
- **Full duplex:** separate transmit and receive shift registers.

## 4. On the ChipInventor canvas

Two canvas projects:

| Project | Contents |
|---|---|
| `rvbl2_soc` | 21 blocks: the core and data memory from Stage 2 (18), the address decoder (remade with the peripheral region), `gpio`, `uart` |
| `top` (the chip) | `rvbl2_soc` as one block, the instruction memory, `gpio_bits` (which splits the 8-bit buses into single wires), and the pins: `clk_i`, `rst_i`, 8 Inout Pins `pins_io_0..7`, `tx_o`, `rx_i` |

The wiring is listed wire by wire in `chipinventor/NETLIST.md` and drawn in
`chipinventor/build/wiring_map.html`. `chipinventor/scripts/run_ci.sh` compares the
platform's exported netlist with our design, wire by wire, before anything is simulated.

## 5. How it is verified

| Testbench | What it checks |
|---|---|
| `tb/tb_gpio.v`, `tb/tb_uart.v` | Each block alone: every register and bit, reset values, byte enables, the synchroniser, UART timing at ±3 % baud error, framing errors, breaks, overruns, RXDONE races |
| `tb/tb_periph_soc.v` | Both blocks inside the SoC, driven by the core |
| `chipinventor/tb_chipinventor.v` (SUITE 4) | On the canvas design: Figure 1 on every pin with the pull both ways, the Block Guide's GPIO and UART listings, and a 24-check register program |
| `official-firmware-testbench/` | The organisers' test firmware on the chip, and on the platform's exported netlist |
