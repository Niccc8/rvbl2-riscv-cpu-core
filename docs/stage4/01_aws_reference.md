# AWS F2 FPGA on ChipInventor: the ground truth (Stage 4)

**Read this first in any Stage 4 session.** It replaces `STAGE3_AWS_FPGA_REFERENCE.md` (kept
locally for history, now superseded) and the notes of our pre-`top.sv` wrapper (archived locally in
`archive/stage4-aws-pre-topsv/`). Every fact is
tagged with its source; anything untagged is a design consequence, and the reasoning is next to it.

| Tag | Source (precedence: PDF > REPO > EMU > older notes) |
| --- | --- |
| **[PDF]** | `AWS Guide.pdf`, 15 slides, given by the organisers (local only, not in git), plus the "Commands" text file it links to |
| **[REPO]** | Organisers' Stage 4 repo `CCX_Malaysia_Edition_Stage_4` @ `b748304` (2026-10-08): `README.md`, `src/top.sv` (sha256 `0fd73910…68551`) |
| **[EMU]** | Organisers' `RVBL-Emulator/src/emu.c` from `CCX_Malaysia_Edition_Stage_3` @ `560947c` (sha256 `31e4ca7c…cda4`): the source of `./emu` |
| **[AWS]** | AWS F2 HDK documentation, as cited in the old reference (fetched 2026-09-23) |
| **[OLD]** | Our Stage 3 notes. Trusted only where nothing newer contradicts them |

No source conflicts with a higher one on any point that matters (§8 lists every conflict with
our *older notes*). One open point needs a hardware answer: §7.

---

## 1. The flow, step by step [PDF]

| # | Where | Action | Evidence of success |
| --- | --- | --- | --- |
| 1 | ChipInventor, left bar | **AWS FPGA** | The AWS FPGA page: status pill **VM Offline**, buttons **Start Synthesis · Start FPGA · Terminate VM** |
| 2 | File tree | Create a file (icon at the top of the tree) and paste code into it. **`cl_ports.vh` is provided by AWS: never modify it.** The example tree is `cl_ports.vh`, `riscv.sv`, `tick_gen.sv`, `top.sv` | Files listed |
| 3 | `top.sv` | Adapt only the `RISCV riscvtop (...)` instance (module name, port names on the left) and, if needed, the PC read line (§3) | — |
| 4 | ☰ menu | **Save Project** | Green toast *"Project saved and synced successfully!"* |
| 5 | Top bar | **Start Synthesis** | Pill turns **VM Online hh:mm:ss**. The **Logs** tab shows Vivado starting (`vivado -mode batch -source build_all.tcl … SSL_SpreadLogic_high AggressiveExplore A1 B2 C0 H2`, Vivado 2024.1 IP build, Ubuntu 20.04, Xeon 8488C) |
| 6 | Logs | Wait. **The guide's own run: Vivado 16:10:01 → 16:51:46 (~42 min); VM timer 45 min** | Ends with *"Finished building design checkpoints for customer design top"* and an **FPGA Image Creation JSON Output** block with `"FpgaImageId": "afi-…"` and `"FpgaImageGlobalId": "agfi-…"`. **Copy both** |
| 7 | Top bar | **Start FPGA** → popup *"Process Completed! … Open Console"* | The FPGA console (`/home/ubuntu/aws-fpga/sdk/userspace#`) |
| 8 | Console | `aws ec2 describe-fpga-images --fpga-image-ids afi-… --region us-east-1` | `"State": {"Code": "pending"}` → wait → `"available"`. A good image also shows `"Name": "top"`, `"ShellVersion": "0x10212415"`, `PciId` `DeviceId 0xf010` / `VendorId 0x1d0f` |
| 9 | Console | `sudo fpga-clear-local-image -S 0` | `AFI 0 No AFI cleared 1 ok 0 0x10212415` |
| 10 | Console | `sudo fpga-load-local-image -S 0 -I agfi-…` | `AFI 0 agfi-… loaded 0 ok 0 0x10212415`, `AFIDEVICE … 0x1d0f 0x7010` |
| 11 | Console | Manual reset: `./axil_rw write 0 0x00 0 && sleep 1 && ./axil_rw write 0 0x00 1 && sleep 1` | `Wrote 0x00000000 @ 0x00000000`, `Wrote 0x00000001 @ 0x00000000` |
| 12 | Console | `./emu -d 0xF0 -i 0x02 -t1 0x30 -r1 0x30 -o 0x20` (the organisers' test firmware) | Six `[Ok]` lines, ending `Read 0x00000020 from OUTPUT PINS` |
| 13 | Top bar | **Terminate VM** when finished [OLD: credit time runs while the VM is online] | Pill back to **VM Offline** |

**What costs credit:** the VM is online from Start Synthesis to Terminate (~45 min per build in
the guide), and again while the FPGA console is in use. **A firmware change is a new synthesis**:
the firmware lives in the instruction ROM inside `riscv.sv`, and the platform offers no other
way to load it [PDF, REPO; §6 discusses a loadable IMEM].

## 2. The files we provide [REPO]

| File | Content | Rule |
| --- | --- | --- |
| `top.sv` | The organisers' file, **unchanged except the `RISCV riscvtop` instance and the `3'b111` PC line** | *"All other sections of `top.sv` must remain unchanged."* |
| `riscv.sv` | **Our whole processor and every module it uses, plus `Transmitter` and `Receiver`** (top.sv instantiates them but does not define them) | One file is fine: *"as long as every required module is declared in `riscv.sv`"* |
| `cl_ports.vh` | AWS Shell ports | Provided; do not modify |
| `tick_gen.sv` | Left over from the example; `top.sv` no longer instantiates it | Harmless if present. **Never declare a module `tick_gen` in `riscv.sv`** |

`top.sv` also includes `cl_id_defines.vh` and `top_defines.vh`, which the build environment
supplies (they are not in the file tree). Files are pasted into an editor, not uploaded, so a
`$readmemh("file.hex")` path cannot be relied on: **the firmware must be a literal ROM in
`riscv.sv`**. The example processor already does this (a `case` ROM) [OLD].

## 3. The frozen contract in `top.sv` [REPO]

### 3.1 Our module and how it is connected

```systemverilog
RISCV riscvtop (                 // module name ours; instance name riscvtop is fixed
  .i_Rx_Serial (w_Rx),           // serial INTO the processor  (from top's Transmitter)
  .i_Clk       (riscv_clk),      // = ocl_aclk = clk_main_a0, directly (tick_gen is commented out)
  .i_nRst      (riscv_nreset),   // ACTIVE LOW, from register 0x00 bit 0
  .o_Tx_Serial (w_Tx),           // serial OUT of the processor (into top's Receiver)
  .io_Pins     (io_Pins)         // 8-bit inout
);
```

- **Clock: `clk_main_a0` = 250 MHz.** Three independent pieces of evidence:
  - `p_CLKS_PER_BIT = 2170`, and 250,000,000 / 115,200 = 2,170.1 [REPO];
  - the example's `tick_gen` is commented *"1 Hz @250 MHz"* with `DIV = 250_000_000` [PDF, REPO];
  - AWS fixes `clk_main_a0` at 250 MHz in every clock recipe; the recipe letters in the build log
    (`A1 B2 C0 H2`) only change the *extra* clocks [AWS, OLD §3].
- **Reset:** `riscv_nreset` is a register in `top.sv`. It is **1 after the Shell's reset**, so the
  processor runs as soon as the image is loaded, and goes to 0 only when the host writes 0 to
  `0x00`. Our core resets on `!i_nRst`.
- Top's wrapper UARTs run on the same `riscv_clk`, with **`i_Rst = ~riscv_nreset`** (active high).

### 3.2 `Transmitter` and `Receiver`: we write them, top.sv fixes their ports

| Module | Ports (exact names) | Behaviour top.sv and `emu` require |
| --- | --- | --- |
| `Transmitter #(p_CLKS_PER_BIT)` | `i_Clk, i_Rst, i_Tx_Transmit, i_Tx_Byte[7:0], o_Tx_Serial, o_Tx_Done` | Starts a frame on the **one-cycle** `i_Tx_Transmit` pulse. `o_Tx_Serial` **idles high, including in reset** (it drives our `i_Rx_Serial`). **`o_Tx_Done` must be a level that stays 1 once the byte is sent**: `emu` polls bit 8 of `0x0C` 50 ms later and loops until it reads 1 (emu.c:211–216). A one-cycle pulse would hang `emu` forever |
| `Receiver #(p_CLKS_PER_BIT)` | `i_Clk, i_Rst, i_Rx_Serial, o_Rx_Done, o_Rx_Byte[7:0]` | **`o_Rx_Done` must be a one-cycle pulse per byte**: every cycle it is high, the FIFO walker advances by 8 (top.sv:270–274). `i_Rx_Serial` comes from our core, so it needs a synchroniser if our core runs in another clock domain |

### 3.3 The register map (OCL AXI4-Lite, BAR0), exactly as coded

| Offset | Read returns | A write does |
| --- | --- | --- |
| `0x00` RST | `{31'b0, riscv_nreset}` | bit 0 → `riscv_nreset` (0 = hold core **and both wrapper UARTs** in reset, and **clear the RX FIFO and walker**) |
| `0x04` IN | `{16'b0, input_en, input_pins}` | `[7:0]` → `input_pins`, `[15:8]` → `input_en`. **Not cleared by `riscv_nreset`**: it keeps its value between `emu` runs |
| `0x08` OUT | `{24'b0, output_pins}` | nothing (no write case) |
| `0x0C` TX | `{23'b0, w_Tx_Done, r_Tx_Data}` | `[7:0]` → `r_Tx_Data`, and `r_Tx_Transmit` pulses for **one cycle**: **every write sends one byte**, including `0x00` and repeats |
| `0x10` RX0 / `0x14` RX1 | `r_UART_RX_FIFO[31:0]` / `[63:32]` | nothing |
| `0x18` | `{26'h0, r_UART_RX_FIFO_Walker}`: the **bit** position of the next byte (0, 8, … 56) | nothing |
| `0x1C` PC | `riscvtop.e_PROCESSOR.w_PC_Output` (hierarchical) | nothing |

All writes respect `wstrb[0]` only. Addresses decode on bits `[4:2]`, so the map aliases every 32 bytes.

### 3.4 Pins: who drives what

```systemverilog
assign io_Pins[n]     = !input_en[n] ? input_pins[n] : 1'bz;   // host drives when input_en = 0
assign output_pins[n] =  input_en[n] ? io_Pins[n]    : 1'bz;   // host observes when input_en = 1
```

| `input_en[n]` (`IN[8+n]`, `emu -d` bit) | Host | Our chip must | `OUT` bit *n* |
| --- | --- | --- | --- |
| **0** | **drives** `input_pins[n]` | treat pin *n* as an **input** (DATADIR = 0) | `'z` in RTL; **reads 0 on hardware** (below) |
| **1** | releases and observes | **drive** pin *n* (DATADIR = 1) | our pin level |

So **`emu -d` bit = 1 means "the processor's output"**, as emu's help says (*"1 for output and 0
for input"*), and `emu -d 0xF0` matches our firmware's `DATADIR = 0xF0` exactly: no contention
once `-d` has run.

**Internal tri-states.** The FPGA fabric has none: Vivado converts them to logic
(`[Synth 8-5799]`, a warning) [OLD]. The guide's run gives the one hardware fact we have about
the result: `-d 0xF0 -i 0x02 … -o 0x20` reads **`0x20`, not `0x22`**, so a pin the host drives reads
**0** in `OUT` [PDF p14]. Our `RISCV` must use the same pattern on `io_Pins`
(`assign io_Pins[n] = oe[n] ? o[n] : 1'bz;` and read `io_Pins[n]`), which `rtl/top.v` already does.

### 3.5 The RX FIFO

8 bytes, circular. Each byte our chip sends is written at the walker's position and the walker
advances by 8, wrapping after 8 bytes: **byte 9 overwrites byte 1**. Reading never consumes
anything. `riscv_nreset = 0` clears the FIFO and the walker.

### 3.6 PC readback

`3'b111: cl_ocl_rdata <= riscvtop.e_PROCESSOR.w_PC_Output;` must resolve in our design, or be
replaced by `32'b0`. The organisers' own build uses this hierarchical reference, so Vivado accepts
it in this flow [PDF: their design synthesised]. **We can satisfy it with zero edits to `top.sv`**
by naming our hierarchy to match: an instance `e_PROCESSOR` inside `RISCV` holding a wire
`w_PC_Output` driven by our PC register.

## 4. `./emu` exactly [EMU]

| Behaviour | Line | Consequence |
| --- | --- | --- |
| **50 ms sleep before every register access** (`DELAY_AXI`) | 16–17, 43, 55 | One byte sent = write + ≥1 poll = ~100 ms. A 26-byte tag-read frame takes ~2.6 s. Nothing in our firmware may time out between bytes (the frame timeout is off by default ✓) |
| **Start of every run:** `-d 0x01` (read-modify-write), then RST `1, 0, 1` | 141–167 | Between reset release and the line's own `-d`, **pin 0 is released (floats)** and pins 7–1 are **driven with the previous run's `input_pins`**. See §6, R6 |
| `-d DIR`: `IN = (IN & 0x00FF) \| DIR << 8` | 97–118 | Not inverted |
| `-i DATA`: `IN = (IN & 0xFF00) \| DATA` | 74–95 | Keeps the direction |
| `-o DATA`: read `0x08`, compare **all 32 bits** | 349–365 | Host-driven pins must read 0 (they do, §3.4) |
| `-t1/-t2/-t4`: one `0x0C` write per byte, **least-significant byte first**, then poll `0x0C` bit 8 until 1 | 203–220, 393–427 | `o_Tx_Done` must be a sticky level (§3.2) |
| `-r1/-r2/-r4`: read `0x10` and `0x14`, take bytes `[ptr, ptr+n)`, `ptr += n`; `ptr` starts at 0 each run | 173–201 | **No waiting and no popping**: it reads a snapshot of the 8-byte window. More than 8 bytes of `-r` per run reads past the window (undefined). A chip that sends more than 8 bytes in a run leaves only the **last** 8 in the window |
| Values: `strtoul(…, 0)` | — | Decimal or `0x` hex |
| **Exit status is inverted**: `return err ? EXIT_SUCCESS : EXIT_FAILURE` | 497 | **Exit 1 = all passed, 0 = an error.** Scripts must check the `[error]` text, not `$?` |
| Output lines | — | `[ok] RISC-V started!`, `[ok] Written 0x%08X to DIRECTION`, `… to INPUT PINS`, `[ok] Written 0x%02X/%04X/%08X to UART RX`, `[ok] Read 0x%02X/%04X/%08X from UART TX`, `[ok] Read 0x%08X from OUTPUT PINS`; errors `[error] OUT read error. Expected 0x%08X. Got 0x%08X`, `[error] UART read error. Expected … Got …` |

`./axil_rw read <slot> <offset_hex>` / `./axil_rw write <slot> <offset_hex> <value>` print
`Read  0x%08x @ 0x%08x` / `Wrote 0x%08x @ 0x%08x` [OLD, PDF]. Both tools live in
`/home/ubuntu/aws-fpga/sdk/userspace` and must be run as `./emu`, `./axil_rw` [PDF].

## 5. The AXI side of `top.sv`, as a verification model must see it [REPO]

- Writes: `W_IDLE → W_WAIT` (AW and W accepted in either order) `→ W_WRITE` (the register updates
  here) `→ W_SEND_RESP`. `bvalid` stays high for one extra cycle after the B handshake. A master
  that holds `bready` high sees **two** B handshakes per write. The organisers' runs work, so the
  Shell tolerates it; our testbench master must too (wait for B, then ignore a trailing one).
- Reads: `R_IDLE` (captures `araddr`; `arready` = 1) `→ R_SEND_RESP` (`rdata` registered) `→ R_IDLE`
  when `rready`; `rvalid` is high for the cycle after.
- Both FSMs and every register reset on the Shell's `rst_main_n`, not on `riscv_nreset`.

## 6. Requirements on our `riscv.sv`, derived from §1–§5

| # | Requirement | Why |
| --- | --- | --- |
| R1 | One file `riscv.sv`: module `RISCV` with ports `i_Rx_Serial, i_Clk, i_nRst, o_Tx_Serial, io_Pins[7:0]`, an instance `e_PROCESSOR` with wire `w_PC_Output` → `top.sv` used **byte-for-byte unchanged** | Zero-edit integration removes a whole class of paste mistakes |
| R2 | `Transmitter` / `Receiver` with the exact ports and the semantics of §3.2 | `emu -t` hangs otherwise; the FIFO fills with garbage otherwise |
| R3 | **No module may be named `top`** (ours is), `tick_gen`, or anything in the HDK; prefix every module (`rvbl2_…`) | Duplicate-module errors in synthesis |
| R4 | Clean as SystemVerilog (the file is `.sv`): no identifier that is an SV keyword | Parse errors |
| R5 | Firmware as a literal ROM; DMEM as inferred block RAM (no `(* keep *)` that could block inference); no file I/O | §2; resource use |
| R6 | **Boot must be robust to the emu start-up window**: pin 0 floats and pins 7–1 hold stale values for ~100 ms after reset release, until the line's own `-d` | A phantom vehicle would put a stray record in the 8-byte window and shift every `-r` |
| R7 | At most 8 bytes from the chip per `emu` run, or the bytes that matter must be the last 8 | §3.5, §4 |
| R8 | Our UART divider = our core clock / 115,200 (2,170 at 250 MHz; another value if the core runs slower) | Both ends at 115,200 bps |
| R9 | Timing must close at the clock our core actually runs at | 250 MHz is given; our core was estimated at 80–140 MHz [OLD §14.9a]. **Resolved:** MMCM ÷8 → 31.25 MHz inside `RISCV` (the ASIC's operating point); estimated path 11–18 ns of 32 ns (`04_fpga_plan.md` §2, `06_verification.md` G6) |

## 7. Open points (answer on the first hardware session, or ask the organisers)

| # | Question | Current best evidence | Risk if wrong |
| --- | --- | --- | --- |
| Q1 | May a CL instantiate an **MMCM / BUFGCE_DIV** inside `riscv.sv` to run the core slower than 250 MHz? | AWS's own CL examples instantiate clock generators inside the CL; nothing in the PDF or repo forbids it | Decides whether R9 is solved by a slower clock or by a faster core (`04_fpga_plan.md`) |
| Q2 | What does Vivado's tri-state conversion produce for a pin **nobody** drives (pin 0 during emu's start-up window)? | A disabled single driver reads 0 (§3.4) | **Closed by design:** all 12 lines pass with the pin read as 0 and as 1 (`06_verification.md` G4), after the firmware arms its detector only once the lane is seen empty |
| Q3 | Does the web editor accept a ~400 kB file? | The example `riscv.sv` was 16 kB | Fallback: split into several `.sv` files (the build compiles every file in the tree [OLD]) |
| Q4 | Can the build's timing summary be read in the Logs pane? **Yes**: intermediate and final `WNS/WHS` and AWS's own negative-slack check are in the log (`06` §1b) | The log prints `report_timing` commands [PDF p8] | Without it, rely on our own margin analysis |

## 8. Discrepancies with our older notes

| # | Old claim (where) | New truth | Source | Impact |
| --- | --- | --- | --- | --- |
| 1 | *"The Stage 3 wrapper is not provided … the DUT clock and baud are our choice"* (old ref §14.9a; `stage4-aws/`) | The organisers provide a **frozen `top.sv`**; the processor gets `clk_main_a0` directly; the wrapper UARTs run at 2,170 clocks per bit | REPO | Our own wrapper (`stage4-aws/rtl/rvbl2_cl.sv`, its MMCM, 256-deep TX queue, registers `0x20`–`0x3C`, loadable IMEM, host tool `rvbl2_f2.c`) **cannot be used as is**. Only what fits inside `RISCV` survives. Archive it |
| 2 | `emu` writes `IN[15:8] = ~DIR`; *"bits 15:8 = 1 means the host drives"* (old ref §14.3, §14.6; our `rvbl2_cl.sv`, `tb_cl.sv`) | `emu` writes `DIR` unchanged; `input_en = 1` means the host **releases** the pin | EMU 108, REPO | Our old wrapper and its testbench had the polarity backwards (already flagged in `stage4-aws/README.md`). Moot with the organisers' `top.sv`; the new testbench uses their RTL and emu's real code |
| 3 | `0x18` = *"the most recent byte"* (old ref §14.3) | `0x18` = the FIFO write pointer, in bits (0–56) | REPO | Cosmetic; emu never reads it |
| 4 | TX is *"level- or change-triggered … de-assert"*; a `0x00` byte may not be sendable (P3) | Every write to `0x0C` sends exactly one byte, `0x00` included | REPO 190, 207–211 | No COBS or zero-avoidance needed in our protocol |
| 5 | `emu`'s waits are unknown; `-r` takes "the next bytes" | 50 ms before every access; `-r` reads a fixed 8-byte window from byte 0 with no wait | EMU | Firmware must answer within ~50 ms of the last stimulus (ours: 0.62 ms worst case ✓); at most 8 bytes counted per run (R7) |
| 6 | Reset register *"resets to 0 (held)"* (our wrapper) / *"resets to 1"* (old example) | `riscv_nreset` resets to **1**: the core runs after image load; emu pulses 1→0→1 | REPO 182, EMU 120–139 | Bring-up: the PC (`0x1C`) moves right after load, before any emu run |
| 7 | `OUT` is RW (slide) | No write case for `0x08`: read-only | REPO | None |
| 8 | Synthesis takes 15–20 min (old ref §7) | Vivado ran ~42 min; VM timer 45 min | PDF p7–8 | Budget **≥ 45 min of VM time per build**, plus AFI `pending` |
| 9 | Five files to paste (`stage4-aws/aws/`) | Two: `top.sv` (theirs) and `riscv.sv` (ours) | REPO | Simpler upload; one generated file |
| 10 | PC path generated from export names (old ref §14.4) | Fixed path `riscvtop.e_PROCESSOR.w_PC_Output` | REPO | Name our hierarchy to match (R1) |
| 11 | `emu` exit status unknown | Inverted: 1 = success | EMU 497 | Runbook scripts check text |
| 12 | Guide example: `-d 0xF0 -i 0x02 -o 0x20 -t1 0x30 -r1 0x30` order (organisers' Stage 3 README) | The PDF uses `-t1 0x30 -r1 0x30 -o 0x20`: `-o` **after** the echo | PDF p14 | Confirms our Stage 3 finding (report §3 callout) |
| 13 | AXI slave rules: exactly one B per write (old ref §5) | `top.sv` emits a trailing `bvalid` cycle (§5) | REPO | Not ours to fix (frozen); the testbench tolerates it |
| 14 | `0x20`+ registers (ID, STATUS, CYCLES…) available for bring-up (our wrapper) | Not in `top.sv`; the map aliases every 32 bytes | REPO | Bring-up uses `0x1C` (PC) and the `I` frame instead (`04_fpga_plan.md`) |

## 9. The commands file linked from the guide [PDF]

```bash
# 1. AFI ID
aws ec2 describe-fpga-images --fpga-image-ids afi-xxxxxxxxxxxxxxxxx --region us-east-1
# 2. Clear the currently loaded FPGA image
sudo fpga-clear-local-image -S 0
# 3. Load your FPGA image (AGFI ID)
sudo fpga-load-local-image -S 0 -I agfi-xxxxxxxxxxxxxxxxx
# 4. Reset Manual
./axil_rw write 0 0x00 0
sleep 1
./axil_rw write 0 0x00 1
sleep 1
# 5. Run your application (example only)
./emu -d 0xF0 -i 0x02 -t1 0x30 -r1 0x30 -o 0x20
```
