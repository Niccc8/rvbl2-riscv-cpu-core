# Audit against the official validation firmware

Source: <https://github.com/championchip-experience-community/CCX_Malaysia_Edition_Firmware_Stage_2>

Vendored here as `firmware/validation_firmware.txt` (11,396 bytes,
`sha256 18dd1ee8cc6925ac4ce5e0cbad635687ec129f5b4a75f861a9cb3a2f8df28890`) and
`firmware/validation_firmware.s`. `scripts/gen_validation_hex.py --check` re-pins that
checksum on every run, so an amended upstream is a loud failure rather than a silent one.

**Result: the firmware runs on this core and returns `x4 = 0x00000000` (PASS) in 991 cycles.**

This document records what was checked against the firmware and what each check settled,
so the one bug it found is traceable rather than folklore.

---

## The firmware in one page

259 words, contiguous, `0x00400000`–`0x00400408`. Nine subtests, then a verdict:

```
all_good:  li x4, 0          ; j .      at 0x004003E8 / 0x004003EC
_error:    li x4, 0xFFFFFFFF ; j .      at 0x004003F0 / 0x004003F4
```

It does **not** signal completion with `ECALL` or `EBREAK` — it spins. Every failing
subtest branches to the same `_error`, so the PC the branch came from is the only thing
that identifies which one failed; `suite_official` records it and names the subtest.

The last five words are not instructions. They are `.rodata` the firmware **loads out of
IMEM**:

| Address | Symbol | Read by |
|---|---|---|
| `0x004003F8` | `crc_data[0..1]` | `_rvbl2_crc_mem_test` (`lw` then `crcw`) |
| `0x00400400` | `source_data[0..2]` | `_rvbl2_mem_transfer_test` copy loop |

Instruction set used: RV32I, `MUL`/`MULH`/`MULHSU`/`MULHU`, and `CRCB`/`CRCH`/`CRCW`.
**No `DIV`/`REM`, no CSR instructions** — everything it executes is inside our 47.

---

## What the audit settled

| Checked | Against | Result |
|---|---|---|
| Xicrc encoding: opcode `0x33`, funct7 `0x40`, funct3 0/1/2 | `control_unit.is_crc` | matches exactly |
| CRC algorithm: CCITT-FALSE, poly `0x1021`, seed `0xFFFF`, MSB-first | firmware's expected `0x1E82` | all three widths chain to it |
| **CRC operand order** | `crcb s0, s1, s0`, encoding `0x80848433` | **MISMATCH — fixed, see below** |
| Zmmul funct3 map, including `MULHSU`=010 and `MULHU`=011 | `multiplier.v` | matches; expected values re-derived by hand and confirmed |
| `.bss` base — `auipc s0,0xfc10` @ `0x0040011C` then `addi -284` | `address_decoder.DMEM_BASE` | both `0x10010000`, exact |
| `dest_data` — same pattern @ `0x0040039C` | DMEM window | `0x10010010`, inside the 8 kB window |
| `.rodata` in IMEM, read by `lw` | ARCH_SPEC 7.4 datapath scoping | the case `oe_o` + AddrSrc were extended through WRITEBACK for |
| PC reset vector | `pc_reg.RESET_VECTOR` | both `0x00400000` |
| `addi zero, zero, 1` then `bne zero, zero, _error` | `register_file` x0 guard | x0 stays hardwired |
| `srai t1, t0, 2` — immediate field `0x402` | `alu` shift masking | ALU uses `b[4:0]`, so 1026 shifts by 2 |
| `sh`/`sb` then `lh`/`lhu`/`lb`/`lbu` at `0x10010004` / `0x10010008` | `lsu` byte lanes | all eight width/offset combinations correct |
| Total DMEM footprint | `DMEM_WORDS` | **28 bytes** (words 0–6) |

---

## The one bug: CRC operand order

The firmware accumulates the CRC in **rs2** and passes the new data in **rs1**:

```asm
crcb s0, s1, s0     # rd=s0, rs1=s1 (data byte), rs2=s0 (CRC so far)
```

Encoding `0x80848433` confirms it: rs1=9 (`s1`, holding `0x12`), rs2=8 (`s0`, holding the
`0xFFFF` seed). `crc_unit.v` had the roles the other way round.

Wired as built, the firmware's CRCB chain yields **`0x1CFF`** instead of `0x1E82`,
`_rvbl2_crc_test` branches to `_error`, and `x4` comes out `0xFFFFFFFF`. Nothing else in
the design was wrong — the polynomial, the seed handling, the bit order, the output mux and
the encoding were all already correct.

### Why it survived the testbench as it then stood (8,282 checks)

`CRCB(seed=X, data=Y)` and `CRCB(seed=Y, data=X)` are *both* valid CRC-16 computations.
Our vector file, our randomised sweeps and the standard `0x29B1` check value all confirmed
the algorithm — none of them could see which operand it read from. Only a test written
against the firmware's own expected value can pin the order down, which is what
`suite_crc`'s anchor now is.

There is a second reason it was easy to miss. **CRCH is symmetric in the two operands**:

```
CRCB  seed-first 0x9D77   data-first 0x7FF0   differ
CRCH  seed-first 0x69F0   data-first 0x69F0   IDENTICAL
CRCW  seed-first 0x2CF6   data-first 0x98AA   differ
```

Sixteen data bits entering a sixteen-bit register makes seed and data play identical roles
in the LFSR recurrence. A suite that happened to exercise only CRCH would report a clean
pass with the operands swapped — and when the fix landed, the CRCH signature in our own
firmware was indeed the one of the three that had never failed.

### Where it was fixed

| File | Change |
|---|---|
| `chipinventor/blocks/crc_unit.v` | `seed` from `rs2_data`, data from `rs1_data` |
| `chipinventor/rtl_ref/crc_unit.v` | identical, so mirror-equivalence stays valid |
| `rtl/crc_unit.v` | identical — the file-driven flow is correct too |
| `tb/tb_crc_unit.v` | driving order swapped; the `0x1E82` anchor added |
| `scripts/gen_firmware_test.py` | `crc_test` emits data in rs1 |
| `tests/progs/tb_core_prog.s` | `crcb x18, x0, x1` → `crcb x18, x1, x0` |

`tests/golden/crc_vectors.txt` was **not** regenerated. It records (seed, data) → result and
the algorithm did not change; only which port carries which value moved.

**The port list did not change**, so nothing on the ChipInventor canvas moves — the fix is a
repaste of one block's Code field.

---

## What this changed about the migration

| | Before | After |
|---|---|---|
| IMEM | our 483-word program at `0x00400000` | official 259 words at `0x00400000`, ours relocated to `0x00400800`; plus `imem_mock.v` for P&R |
| Completion detection | `sys_event_o` pulse (ECALL/EBREAK) | PC settling into a self-loop, verdict read from x4 |
| Mirror equivalence | 205,200 comparisons, one program | 410,400 across two phases, both programs |
| Combined suite | 15,249 checks | 15,281, with the official verdict as the headline |
| Canvas | 17 blocks, 20 instances, 45 nets, 72 connections | **unchanged** |

The supplementary program relocates for free: every control transfer in it is PC-relative
and its DMEM addresses are absolute, so its machine code is byte-identical at either base.
`gen_ci_firmware.py --check` proves that by assembling it twice rather than assuming it.

---

## What is still open

- **The mock IMEM is what gets taped out.** `blocks/imem_mock.v` is the version OpenLane
  synthesises, on the firmware repository's own advice. `run_ci.sh` step 8 builds the whole
  core against it and runs their three-instruction program to `x7 = 15`, so it cannot rot
  unnoticed — but the full ROM is never itself synthesised.
- **DMEM sizing.** The validation firmware touches 28 bytes. `DMEM_WORDS` stays at 2048
  (the Block Guide's 8 kB) for the functional runs; if P&R cannot close, the functional
  floor for validation is now known to be 8 words rather than guessed.
- **Two top-level pins.** Unchanged. If synthesis sweeps the design, x4 is now the natural
  thing to expose, since it is the competition's own verdict signal.
