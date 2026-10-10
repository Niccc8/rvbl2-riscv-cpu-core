# Stage 4 runbook: RVBL-2 + LaneX on the AWS F2 (ChipInventor "AWS FPGA")

**On the day, this is the only document you need.** Use it every time you touch the AWS feature.
Every step says what you should see. VM time
costs credit from **Start Synthesis** until **Terminate VM**: do the preparation first.
Source of every fact: `01_aws_reference.md`. Evidence that it works: `06_verification.md`.

---

## 0. Preparation (local, no VM, ~10 min)

- [ ] `git pull`; on branch `stage4`.
- [ ] Pre-flight green: `bash scripts/stage4/preflight.sh` ends with `PREFLIGHT: GO`
      (needs WSL for Verilator/Yosys). Do **not** start a build on anything else.
- [ ] Open `stage4/riscv.sv`. Its header must say:
      `ROM: 2793 words; the 'I' record must report rom_words 2793, rom_crc 0x56DE` and
      `core clock 31250000 Hz (MMCM); UART 271 clocks/bit`. 4,315 lines; last line `endmodule`.
- [ ] Have the organisers' `top.sv` ready **unchanged** (532 lines): from
      `github.com/championchip-experience-community/CCX_Malaysia_Edition_Stage_4/src/top.sv`
      (sha256 `0fd7391018a38aee…`). We need **no edit** to it: our module is called `RISCV`,
      its ports are `i_Rx_Serial, i_Clk, i_nRst, o_Tx_Serial, io_Pins`, and
      `riscvtop.e_PROCESSOR.w_PC_Output` exists in our design.
- [ ] Know the two backups (pre-verified the same way; only for §6, never first):
      `stage4/riscv_15mhz.sv` (same design at 15.625 MHz: if the core clock misses timing) and
      `stage4/riscv_bufgce_div.sv` (31.25 MHz from a BUFGCE_DIV: if the MMCM is refused).
- [ ] Optional but recommended: ask the organisers that a clock divider inside `riscv.sv` is
      fine (their README describes the core on `clk_main_a0` but does not forbid it).
- [ ] Copy the 12 command lines of §4 into a text file you can paste from.

## 1. Upload (VM offline, free)

| # | Do | You should see |
| --- | --- | --- |
| 1.1 | ChipInventor → left bar → **AWS FPGA** | Page with *VM Offline*, buttons Start Synthesis · Start FPGA · Terminate VM |
| 1.2 | File tree: **do not touch `cl_ports.vh`**. If an old `riscv.sv` exists, replace its whole content; otherwise create `riscv.sv` | — |
| 1.3 | Paste **all** of `stage4/riscv.sv` | Editor ends with `endmodule`; scroll to the top: the header lines of §0 |
| 1.4 | `top.sv`: paste the organisers' file unchanged (or leave theirs if it is already the Stage 4 version: 532 lines, `RISCV riscvtop (` near line 58) | — |
| 1.5 | `tick_gen.sv` may stay (nothing instantiates it; we declare no `tick_gen`). No other `.sv` with a module `RISCV`, `Transmitter` or `Receiver` may exist in the tree | Tree: `cl_ports.vh`, `riscv.sv`, `top.sv` (+ `tick_gen.sv`) |
| 1.6 | ☰ → **Save Project** | Green toast *"Project saved and synced successfully!"* |

## 2. Build (~45 min of VM time)

| # | Do | You should see |
| --- | --- | --- |
| 2.1 | **Start Synthesis** | Pill *VM Online hh:mm:ss*; Logs: Vivado starts (`build_all.tcl`, recipe `A1 B2 C0 H2`) |
| 2.2 | Watch the log for the first ~5 min: elaboration errors appear early | No `ERROR:` lines. Warnings `[Synth 8-5799] ... tri-state ... converted to logic` are **expected** (top.sv's and our `io_Pins` tri-states) |
| 2.3 | Wait (~40 min in the guide's run) | Ends with *"Finished building design checkpoints for customer design top"* and a JSON block with `"FpgaImageId": "afi-…"`, `"FpgaImageGlobalId": "agfi-…"` |
| 2.4 | **Copy both IDs** into your notes now | — |
| 2.5 | Search the log for the timing summary (`WNS`, `Timing constraints are met`/`not met`); note WNS per clock. The core clock (from `u_mmcm`, 32 ns) has 46 % slack in our pessimistic estimate (17.2 ns path); the 250 MHz paths are the organisers' and our short synchronisers | `WNS ≥ 0` expected. **Negative WNS on the core clock:** load and test anyway (§3); if any ladder step or line misbehaves, rebuild with `riscv_15mhz.sv` (§6). A small negative WNS on a 250 MHz path: load and test |

## 3. Load and bring-up ladder (FPGA console)

**Start FPGA** → popup → **Open Console** (`/home/ubuntu/aws-fpga/sdk/userspace#`). Then:

```bash
aws ec2 describe-fpga-images --fpga-image-ids afi-XXXXXXXX --region us-east-1   # repeat until "available"
sudo fpga-clear-local-image -S 0
sudo fpga-load-local-image -S 0 -I agfi-XXXXXXXX
./axil_rw write 0 0x00 0 && sleep 1 && ./axil_rw write 0 0x00 1 && sleep 1     # manual reset
```

| Step | Command | Expected | Proves |
| --- | --- | --- | --- |
| L0 | `./axil_rw read 0 0x00` | `Read 0x00000001 @ 0x00000000` | Core out of reset |
| L1 | `./axil_rw read 0 0x1C`, again 1 s later | Two **different** values, each between `0x00400000` and `0x00402BA4` (the main loop is short: if two reads happen to match, read a third time) | MMCM locked, core running our ROM, PC readback wired |
| L2 | §4 line **12 (identify)** | Ends `[ok] Read 0x0AE90449 …` `[ok] Read 0x19A356DE …` | UART both ways at 115,200; **the ROM on the FPGA is exactly this build** (2,793 words, CRC `0x56DE`) |
| L3 | §4 line **1 (charged)** | `Read 0x11000056`, `Read 0x7B3C00FA`, `Read 0x00000010 from OUTPUT PINS` | Pins in/out, tag CRC, decision, record |
| L4 | §4 lines 2–11 | Every line ends with `[ok] Read … from OUTPUT PINS` (or the second `-r4`) and no `[error]` | Every outcome, authentication |

`./emu` prints `[ok]`/`[error]` lines; **its exit status means nothing** (inverted in emu.c).
Read the text. Each line takes 5–40 s (emu waits 50 ms before every register access).

## 4. The 12 command lines (generated; expected values from the golden model)

Paste exactly. Each line resets the chip first, so lines are independent and any order works.

```bash
# 1 valid tag, class matches -> CHARGED RM 2.50, P4 on
./emu -d 0xF0 -i 0x01 -t4 0x301552A5 -t4 0x00000075 -t4 0x80511930 -t4 0xDCA583F3 -t4 0x39E21AF3 -t4 0x5A6ECCE5 -t2 0xF592 -i 0x00 -r4 0x11000056 -r4 0x7B3C00FA -o 0x10
# 2 car tag on a lorry -> CLASS MISMATCH, charged at the lorry fare, P4+P5
./emu -d 0xF0 -i 0x05 -t4 0x301552A5 -t4 0x00000075 -t4 0x8E9F9930 -t4 0x8C92C86B -t4 0xC4C6BBD7 -t4 0x5A96577D -t2 0x69D0 -i 0x00 -r4 0x31020056 -r4 0xFF6702EE -o 0x30
# 3 taxi tag -> CHARGED at the taxi fare RM 1.30
./emu -d 0xF0 -i 0x01 -t4 0x301552A5 -t4 0x00000075 -t4 0x96C5C430 -t4 0x9D003D70 -t4 0xD1491C14 -t4 0x5AF48B19 -t2 0xB12C -i 0x00 -r4 0x14000056 -r4 0x113C0082 -o 0x10
# 4 no tag read -> NO TAG, camera P5
./emu -d 0xF0 -i 0x01 -i 0x00 -r4 0x17010056 -r4 0x43220000 -o 0x20
# 5 motorcycle, no tag -> FREE, no lamp
./emu -d 0xF0 -i 0x07 -i 0x00 -r4 0x07050056 -r4 0xCAB00000 -o 0x00
# 6 stolen car on the hotlist -> HOTLIST, camera + alarm P5+P6
./emu -d 0xF0 -t4 0x710D48A5 -t4 0xAFE4D002 -t4 0x3550AD7D -t4 0x01594065 -t2 0xDC97 -i 0x01 -t4 0x301552A5 -t4 0x00000075 -t4 0xD0027130 -t4 0xAD7DAFE4 -t4 0x40653550 -t4 0x5A5E2559 -t2 0xA128 -i 0x00 -r4 0x11030056 -r4 0x1CEA0000 -o 0x60
# 7 cloned tag: seen 40 km away 30 s ago -> CLONE, camera + alarm
./emu -d 0xF0 -t4 0x020347A5 -t4 0x9AC60190 -t4 0xF91153A5 -t4 0xCE5BEDFF -t4 0x83BEFF60 -t4 0x02B913A3 -t4 0x00000000 -t2 0x380D -i 0x01 -t4 0x301552A5 -t4 0x00000075 -t4 0xEDFFF930 -t4 0xFF60CE5B -t4 0x13A383BE -t4 0x5AFC67B9 -t2 0x11AB -i 0x00 -r4 0x11040056 -r4 0x4DC70000 -o 0x60
# 8 radio-corrupted tag (bad Gen2 CRC) -> NO TAG, camera
./emu -d 0xF0 -i 0x01 -t4 0x301552A5 -t4 0x00000075 -t4 0x8E165130 -t4 0x75494A89 -t4 0xB4A5E024 -t4 0x5A207FB7 -t2 0x063C -i 0x00 -r4 0x17010056 -r4 0x43220000 -o 0x20
# 9 adjacent lane's weak read below the RSSI floor -> NO TAG
./emu -d 0xF0 -t4 0x1E0A50A5 -t4 0x0BB801F4 -t4 0x004000FA -t2 0xCD00 -t1 0xC8 -i 0x01 -t4 0x301552A5 -t4 0x00000075 -t4 0x064F9130 -t4 0x5D5EB5D9 -t4 0x66176C76 -t4 0x145724E4 -t2 0x282A -i 0x00 -r4 0x17010056 -r4 0x43220000 -o 0x20
# 10 lane closed (P3) -> LANE CLOSED, P7 stays on while closed
./emu -d 0xF0 -i 0x09 -t4 0x301552A5 -t4 0x00000075 -t4 0x80511930 -t4 0xDCA583F3 -t4 0x39E21AF3 -t4 0x5A6ECCE5 -t2 0xF592 -i 0x08 -r4 0x17060056 -r4 0x120F0000 -o 0x80
# 11 authenticated: key + counter start 1000, one car -> the 'A' record (Chaskey-12 tag)
./emu -d 0xF0 -t4 0x52144BA5 -t4 0x2D4C4256 -t4 0x616C2032 -t4 0x6B20656E -t4 0xE8217965 -t4 0x51000003 -t1 0x14 -i 0x01 -t4 0x301552A5 -t4 0x00000075 -t4 0x80511930 -t4 0xDCA583F3 -t4 0x39E21AF3 -t4 0x5A6ECCE5 -t2 0xF592 -i 0x00 -r4 0xCEC30041 -r4 0xF241EFCB -o 0x10
# 12 identify: the chip reads its own ROM and reports its size and CRC
./emu -d 0xF0 -t4 0x5B0049A5 -t1 0xAA -r4 0x0AE90449 -r4 0x19A356DE
```

How to read a record: `-r4 0x11000056 -r4 0x7B3C00FA` = bytes `56 00 00 11 FA 00 3C 7B`:
`V` (vehicle), seq 0, status 0 CHARGED, class 1/tag class 1, fare `0x00FA` = 250 sen, CRC.
Lamps (`-o`): `0x10` charged, `0x20` camera, `0x40` alarm, `0x80` lane closed.

## 5. When something is wrong: symptom → cause → fix

| Symptom | Likely cause | Fix (no rebuild unless it says so) |
| --- | --- | --- |
| Synthesis log: `module 'RISCV' not found` / `Transmitter` not found | `riscv.sv` not saved, or pasted partially | Re-paste, check last line `endmodule`, Save, restart synthesis |
| `duplicate module` / `already declared` | An old `riscv.sv` or a second copy in the tree | Keep exactly one file defining `RISCV`; restart |
| Error on `riscvtop.e_PROCESSOR.w_PC_Output` | Hierarchical reference not accepted (not expected: the organisers' own build uses it) | Change that one `top.sv` line to `3'b111: cl_ocl_rdata <= 32'b0;` (the README allows it); rebuild. L1 is then skipped |
| A DRC/placement error naming `MMCME4_BASE` / `u_mmcm` | MMCM placement in the CL region refused | Rebuild with `stage4/riscv_bufgce_div.sv` (pre-verified fallback, 31.25 MHz) |
| describe-fpga-images: `failed` | Build problem on the AWS side | Read the state message; rebuild only if it points at the design |
| L0 reads `0x00000000` | Reset left low | `./axil_rw write 0 0x00 1` |
| L1: PC frozen (the same value three times) or `0x00000000` | Clock not locked / core held in reset | Repeat the manual reset; if still frozen, rebuild with the BUFGCE_DIV fallback |
| emu stops after `[ok] Written … to UART RX` and never returns | `o_Tx_Done` not seen (should not happen: verified) | Ctrl-C; manual reset; retry L2 once |
| `-r` reads `0x00000000` | The chip sent nothing: core not running or UART mismatch | Check L1; run L2. If L1 passes and L2 reads 0, report it (do not rebuild blindly) |
| `-r` reads a valid `V` record but with seq `01` | A stray vehicle before the line's car (stale pins from an aborted line) | Run `./emu -d 0xF0 -i 0x00` once, then the line again |
| Only `-o` differs, in bit 7 (`0x80`) | The lane-closed pin P3 is still set from line 10 (emu keeps pin values between runs) | Run any line that writes `-i` (all except 12) or `./emu -d 0xF0 -i 0x00` |
| L2's CRC differs from `0x56DE` | A different `riscv.sv` was built | Compare the header in the editor with `stage4/riscv.sv`; rebuild only with the right file |

## 6. Rebuild or not? (each rebuild = ~45 min of credit)

```text
Synthesis failed? ──yes──► fix per §5 (paste/duplicate/PC line/MMCM→riscv_bufgce_div.sv) ──► rebuild
      │no
L0/L1 fail after a manual reset? ──yes──► rebuild with riscv_bufgce_div.sv
      │no
Core-clock WNS < 0 AND a ladder step or line misbehaves? ──yes──► rebuild with riscv_15mhz.sv
      │no
L2 (identify) wrong CRC? ──yes──► wrong file was built ──► rebuild with the right one
      │no
A line fails? ──► rerun it once after `./emu -d 0xF0 -i 0x00` ──► still fails? note the
                  exact output; it is a firmware/expectation issue, NOT a reason to rebuild
                  before the demo: use the lines that pass
```

## 7. Pre-flight checklist (tick before pressing Start Synthesis)

- [ ] `preflight.sh`: `PREFLIGHT: GO` today, on this commit
- [ ] `riscv.sv` in the editor: header as in §0, 4,315 lines, ends `endmodule`
- [ ] `top.sv` unchanged (line 58 `RISCV riscvtop (`, line 311 `riscvtop.e_PROCESSOR.w_PC_Output`)
- [ ] One module `RISCV` in the whole tree; `cl_ports.vh` untouched; project saved (green toast)
- [ ] 45 min of VM time available, plus ~20 min for load and the ladder
- [ ] This runbook and the 12 lines open in another window

## 8. Demo-day card (one page; at most six lines on stage)

| # | Say | Run | The audience sees |
| --- | --- | --- | --- |
| 1 | "This is our chip, and it can prove which firmware it runs." | line 12 | `0x56DE`: the chip measured its own ROM; matches the build |
| 2 | "A normal car with a valid tag." | line 1 | `56 … FA 00`: RM 2.50 charged, green lamp `0x10` |
| 3 | "A car tag on a lorry: the classic toll fraud." | line 2 | CLASS MISMATCH, charged the lorry fare, camera `0x30` |
| 4 | "A stolen car on the hotlist." | line 6 | HOTLIST, camera + alarm `0x60` |
| 5 | "The same tag 40 km away 30 s ago: a clone." | line 7 | CLONE (impossible speed), alarm `0x60` |
| 6 | "Every record is signed: a tamper-evident evidence trail." | line 11 | The `A` record: a Chaskey-12 (ISO/IEC 29192-6) tag, counter from 1,000 |

**If the live FPGA is unavailable or a line fails on stage:** say so plainly, then switch to the
recorded run (screen capture of §3/§4 taken during bring-up), the system-simulation transcript
(`docs/stage4/evidence/emu_sys_full.log`: the organisers' own `emu.c` on our design), and the offline
replay page (`docs/demo/index.html`, no network needed).
