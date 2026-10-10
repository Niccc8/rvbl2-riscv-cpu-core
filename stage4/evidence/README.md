# AWS F2 run, 2026-10-10: screenshots and recording (for the pitch slides)

The first and only AWS build (`afi-0732c3cb90c96019a`) on ChipInventor's AWS FPGA page. The full
console text is `docs/stage4/evidence/aws_console_log.txt`; the build log `aws_build_log.txt` beside it.

| File | Shows | Best use |
| --- | --- | --- |
| `Screenshot 2026-10-10 203411.png` | The AWS FPGA page: our `riscv.sv` open (`module RISCV`, the MMCM 250 → 31.25 MHz), the Synthesis Logs ending *"Finished building design checkpoints"* with the AFI/AGFI IDs | Slide "From our RTL to an AWS FPGA" |
| `Screenshot 2026-10-10 204622 (redacted).png` | `describe-fpga-images`: `pending` → `available`, Name `top`. **Use only this redacted copy** (the original shows the AWS account number and is kept out of git) | Backup / appendix |
| `Screenshot 2026-10-10 204904.png` | Clear old image, load ours: `loaded … ok`; manual reset | Backup |
| `Screenshot 2026-10-10 205302.png` | **The bring-up ladder in one shot**: reset reads 1, PC readback moving (`0x00401da4` → `0x00401ecc`), identify `0x0AE90449 0x19A356DE` (ROM CRC `0x56DE`), and line 1 CHARGED with lamp `0x10` | **Hero slide**: "It runs — first build" |
| `Screenshot 2026-10-10 210327.png` | Identify run six times in a row, all `[ok]` | "Repeatable, not lucky" |
| `Screenshot 2026-10-10 210735.png` | Lines 1–3: charged, **class mismatch (car tag on a lorry, `0x30`)**, taxi | Demo slide: fraud caught |
| `Screenshot 2026-10-10 210759.png` | Lines 3–6: taxi, no tag, motorcycle free, hotlist start | Backup |
| `Screenshot 2026-10-10 210820.png` | **Hotlist (stolen car, `0x60`) and clone (`0x60`)** | Demo slide: alarm cases |
| `Screenshot 2026-10-10 210837.png` | Bad tag CRC, adjacent-lane weak read, lane closed | Backup |
| `Screenshot 2026-10-10 210848.png` | Lane closed (`0x80`), **authenticated `A` record (`0xCEC30041 0xF241EFCB`)**, identify again (captured while its last read was still printing; the log shows it completed) | Slide: "Every record is signed" |
| `Screen Recording 2026-10-10 210606.mp4` | The run on video (270 MB; **local only**, not in git: over GitHub's file limit) | On-stage fallback if the live demo fails; cut a 30–60 s clip for the deck |

How to read a line for an audience: `-r4 0x11000056 -r4 0x7B3C00FA` = record `56 00 00 11 FA 00 …`:
**V**ehicle, seq 0, **CHARGED**, class 1, fare `0x00FA` = **RM 2.50**; `-o 0x10` = the green
"charged" lamp. `0x20` camera, `0x40` alarm, `0x80` lane closed.
