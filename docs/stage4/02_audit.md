# Stage 4 audit: RVBL-2 + LaneX, before the FPGA build

**Scope:** the whole stack, Stage 2 core to the Stage 3 application, judged as a toll operator or
a chip company would judge it, and against the AWS contract in `01_aws_reference.md`.
**Baseline (2026-10-10, before any change):** official firmware 34/34 + `./emu` 4/4;
`run_all.sh` 31/31 testbenches (application: directed 78/78, showcase 30/30, 921,600 bps 30/30,
platform 26/26, emulator preview 11/11, waveform, page logic 182/182); `run_ci.sh` 15,517 checks on
both netlists, 470,400 + 1,238,859 lockstep comparisons, every platform scenario. Logs:
`build/stage4_baseline/`.

**Priority** = pitch value × risk × effort. **P0** must be done for a working, honest Stage 4;
**P1** recommended, needs your approval; **P2** documented as roadmap, not built.
Severity: **Critical** (the FPGA demo fails), **High**, **Medium**, **Low**.

## A. FPGA blockers (from the AWS contract)

| # | Finding | Sev. | Evidence | Fix | Pri. |
|---|---|---|---|---|---|
| A1 | **Our core cannot be assumed to close timing at 250 MHz.** `top.sv` clocks `RISCV` from `clk_main_a0` (250 MHz, 4 ns). The multicycle core has no ALU-result register: register read → 32×32 multiply (DSP + adder chain) → register write happens in one cycle; estimated 80–140 MHz | Critical | `01` §3.1; old estimate (Yosys, 36-cell path) | Run the unchanged core from a divided clock generated **inside `RISCV`** (MMCM or `BUFGCE_DIV`, both auto-constrained by Vivado, no XDC needed). Alternative (pipeline the core to 250 MHz) touches verified RTL: rejected unless the clock divider is disallowed (`01` Q1) | P0 |
| A2 | **emu's start-up window**: after reset release, pin 0 is released and undriven, and pins 7–1 carry the *previous* run's `input_pins`, for ~100 ms until the line's own `-d`. A spurious P0 edge would create a phantom vehicle record and shift every `-r` | High | `01` §4, emu.c 141–167 | Model it exactly in the system simulation (both resolutions of an undriven pin); fix only if a run fails | P0 (verify) |
| A3 | Our chip module is named **`top`** (collides with AWS `top`); generic module names (`alu`, `uart`, `imem`…) may collide with HDK sources | High | `rtl/*.v` | Generator prefixes every module (`rvbl2_`) | P0 |
| A4 | `riscv.sv` is parsed as SystemVerilog; any identifier that is an SV keyword breaks it | Medium | file type | Verilator `-sv -Wall` lint in the gate | P0 |
| A5 | `dmem.v` puts `(* keep *)` on the memory array (an ASIC-flow workaround). On Vivado it may block block-RAM inference → 65,536 flip-flops | Medium | `rtl/dmem.v:113` | FPGA generator drops the attribute; Yosys check confirms RAMB inference | P0 |
| A6 | `imem.v` loads its image with `$readmemh(file)`; the AWS editor has no file path | High | `rtl/imem.v:38` | Generator emits a literal `case` ROM equal to `firmware.hex` bit for bit | P0 |
| A7 | `Transmitter`/`Receiver` must exist in `riscv.sv` with emu-compatible semantics (`o_Tx_Done` sticky level, `o_Rx_Done` one-cycle pulse, idle-high in reset) | Critical | `01` §3.2 | Write them; test against emu.c's real loop | P0 |
| A8 | **emu shows 8 bytes per run.** With a key loaded, every vehicle produces 16 bytes (`V` + `A`), so `-r` sees only the `A`. The showcase (17 records) cannot be shown through emu at all | Medium | `01` §3.5 | See C5 | P1 |

## B. Correctness

| # | Finding | Sev. | Evidence | Fix | Pri. |
|---|---|---|---|---|---|
| B1 | **The lane clock freezes after a 32-bit wrap.** `now` advances only if `t > now` (`main.c` on_read, `T`). After the host's millisecond clock wraps (2³² ms = **49.7 days** if it counts from its own boot), every new time is "smaller", `now` never moves again, and the guard and dedup windows silently stop working. The dedup test also uses signed 64-bit differences, which is wrong across the wrap | High | `main.c:500–501, 563–565, 400` | Serial-number arithmetic (RFC 1982): accept `t` when `(int32_t)(t - now) > 0`; all window tests as `uint32_t` differences, the same rule `too_fast` already uses. Model + directed test at the wrap | P1 |
| B2 | **A full hotlist drops a stolen tag silently.** `hot_add` gives up when its 8-slot probe window is full; the back office never learns the tag is not being watched | High (for an operator) | `main.c:286–301`; coverage bin "probe window full 8" | Report it: an `E` record with a new reason 6 (table full, `type` = `H`), counted in `bad_frame` | P1 |
| B3 | Sightings evict the oldest in the window silently | Low | `seen_put` | Expected behaviour (a cache); document | P2 |
| B4 | `seq` is 8-bit: gaps are detectable only modulo 256 | Low | §4 | The `A` counter is 32-bit; document. A wider `seq` would break the 8-byte record | P2 |
| B5 | After a lost byte the parser may eat the start of the next frame (no byte stuffing); one extra frame is lost, CRC rejects both | Low | `parse()` | By design; the optional timeout bounds it. Document | P2 |
| B6 | Stack and memory: 2,892 B static + 4 KB stack reserved in 8 KB DMEM; deepest frame chain `main`→`finalize`→`mac_step` ≈ 304 B | — | `size -A`, `.s` frames | No action; worth a sentence in the pitch | — |

## C. Security (pragmatic, no invented PKI)

| # | Finding | Sev. | Fix | Pri. |
|---|---|---|---|---|
| C1 | **Silent downgrade**: an empty `K` frame turns authentication off, and anyone on the UART can do it | High | **Key lock**: once a key is loaded, `K` is refused until reset (`E` reason 7). Rotation = reset + reload, which the back office controls | P1 |
| C2 | **Replay across reboots**: the `A` counter restarts at 0 at every key load, so after a reboot old `V`+`A` pairs verify again | High | `K` may carry a 4-byte **counter start** (payload 20 bytes): the back office sets it above every counter it has seen. 16-byte `K` keeps today's behaviour | P1 |
| C3 | **`I` is integrity, not attestation**: a CRC detects a wrong or corrupted build; it proves nothing against a malicious firmware, which can report any CRC | Medium | Say so everywhere ("build fingerprint"). Optional: when a key is loaded, follow `I` with an `A` (MAC over the identity record), so the answer is authenticated | P0 (wording), P1 (MAC) |
| C4 | Configuration frames (`C`, `P`, `H`, `h`, `S`) are unauthenticated: anyone on the line can change fares or delete a hotlist entry | Medium | Roadmap: authenticated commands (MAC over each frame with the same key). Out of scope for the prototype; say so | P2 |
| C5 | Demonstrating authentication through emu (A8) | Medium | Two honest options: (a) one emu line that loads a key and shows the **`A` record** in the window (the last 8 bytes); (b) our own host tool reads the window as bytes arrive (`0x18` pointer) at native speed. (a) is free | P1 (a) |
| C6 | 32-bit truncated tag: 2⁻³² forgery per record | Low | Adequate for an evidence trail; documented | — |

## D. Operator reality

| # | Finding | Fix | Pri. |
|---|---|---|---|
| D1 | Registered class = `epc[0] & 7` is **our assumption**; the Touch 'n Go tag layout is not public | Keep, and say it; in a deployment the class comes from the back office's account lookup | P2 |
| D2 | Back office silent: the lane keeps deciding with its last lists and fares (fail-operational), but nobody can see how stale they are | `Q` could carry a configuration fingerprint (CRC of gantry, fares, parameters) so the back office can check the lane runs the intended configuration | P2 |
| D3 | No heartbeat | The host polls with `Q` today; a periodic unsolicited record would break emu's 8-byte window | P2 |
| D4 | Audit trail | `seq`, the 32-bit `A` counter, `E` counts and `Q` stats exist; the replay page proves the chain offline | — |

## E. Lean

| Metric | Value |
|---|---|
| Code | 2,722 instructions, 2,774 of 4,096 IMEM words (68 %) |
| Data | 2,892 B static + 4 KB stack of 8 KB DMEM |
| Main loop | ~170 cycles per turn; a received byte waits ≤ 199 cycles (budget 2,630 at 30.3 MHz) |
| Decision | ≤ 0.62 ms from the car leaving to its sealed record |
| Silicon (Stage 2, Sky130) | 0.404 mm² die, setup slack +2.25 ns at 33 ns, 0 DRC, LVS clean |
| Capacity | A 26-byte tag-read frame takes 2.3 ms at 115,200 bps; one lane's peak traffic (~2,000 vehicles/h, ~0.6/s, ASSUMPTION) is far below what the loop handles |

## F. Standards: what is real

| Claim | Status |
|---|---|
| EPC Gen2 / ISO 18000-63 tag CRC (CRC-16/EPC-C1G2) | **Real**: the chip recomputes it; check value `0xD64E` verified on the RTL |
| Chaskey-12, ISO/IEC 29192-6:2019 | **Real**: all 64 reference vectors in Python, six on the RTL, and the page's JS |
| MLFF architecture (reader, classifier, ANPR, back office) | Concept-level alignment only; no certification claimed |

## G. Reproducibility

One command per layer exists (`run_all.sh`, `run_ci.sh`, `official-firmware-testbench/run.sh`), but
the full run takes ~10 min, and Stage 4 adds a pre-flight gate (`scripts/stage4/preflight.sh`, P0).
The firmware rebuilds byte-identically (xPack and Ubuntu GCC 13.2). The README is Stage 3's; a
Stage 4 section is P0.

## H. The ten things a sceptic will attack

| # | Attack | Our honest answer |
|---|---|---|
| 1 | "It's a student prototype." | Yes: an **FPGA-validated prototype** with a signed-off ASIC layout and a golden-model-checked firmware. What we sell today is a verified design and the team that built it |
| 2 | "Any off-the-shelf MCU can run this." | True for the function. Our chip adds one-instruction CRC (Xicrc) and a design small enough (0.4 mm² in Sky130) to sit inside a reader; the point is owning the silicon path, not beating an MCU today |
| 3 | "Kapsch and TransCore already sell lane controllers." | We are a component and IP for integrators, not a replacement for a tolling system |
| 4 | "A 32-bit MAC tag? Key sent in clear?" | Truncation is a deliberate trade for 8-byte records (2⁻³² per record); key provisioning belongs to the back office. With C1/C2 the key is locked and replays across reboots fail |
| 5 | "How do you know the Touch 'n Go tag class?" | We don't; it is an assumption, isolated in one line, and a deployment takes the class from the account |
| 6 | "115,200 baud? One lane?" | One controller per lane; a vehicle needs ~2–3 ms of line time against ~1.7 s between cars at peak |
| 7 | "Is it certified?" | No. Road-side equipment certification is a roadmap item with a partner |
| 8 | "Malaysia's MLFF keeps slipping." | Answered with sourced dates in `03_market.md` |
| 9 | "Who owns the IP?" | Our RTL, firmware and tools are ours; Sky130 is an open PDK; the organisers' tools are credited and not redistributed as ours |
| 10 | "Does it really work, or only in simulation?" | Every byte is checked against an independent model, on the platform's own netlist; Stage 4 runs it on an AWS F2 FPGA under the organisers' `emu` |

## I. Recommended scope (for GATE 1)

- **P0 (do):** A1–A7 (the FPGA path), C3 wording, the Stage 4 README section and the pre-flight script.
- **P1 (recommend, your call):** **B1** lane-clock wrap fix · **B2** report a full hotlist · **C1** key lock · **C2** counter start in `K` · **C5(a)** an authenticated emu line. Each: golden model, `PROTOCOL.md`, firmware and a directed test in lockstep; full regression after each.
- **P2 (document only):** B3–B5, C4, D1–D3.
