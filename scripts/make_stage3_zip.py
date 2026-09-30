#!/usr/bin/env python3
"""Build the Stage 3 source-code archive for the submission portal.

    python scripts/make_stage3_zip.py

Writes RVBL2_Equipe13_Stage3_source.zip at the repository root.

What goes in is Submission Guide section 9: all developed source code (C,
Verilog, testbenches, scripts) and the complete firmware in binary and
assembly, plus what an evaluator needs to rebuild and rerun it. The report
uploads through its own PDF slot and the video is a URL, so neither is here.

The archive is built from the files git tracks, so nothing local (the brief,
the presentation, build output) can slip in, and it refuses to run if a file
it would include has uncommitted changes: the archive is exactly the commit.

Left out, on purpose:
  chipinventor/openlane/   Stage 2's physical design (GDS and GL netlists,
                           58 MB), submitted in Phase 2 and unchanged since.
  report-stage2/,          the reports' figures (the Stage 3 PDF is uploaded
  report-stage3/           separately; the Stage 2 report is on main).
  synth/                   Stage 2 synthesis logs.
  macros/                  SkyWater's SRAM macro: third-party, and only used
                           with DMEM_MACRO=1; the default build never reads it.
"""
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

OUT = os.path.join(ROOT, 'RVBL2_Equipe13_Stage3_source.zip')
TOP = 'rvbl2_equipe13_stage3'

VIDEO_URL = 'https://youtu.be/OZdPSbZZKvU'
REPO_URL = 'https://github.com/Niccc8/rvbl2-riscv-cpu-core/tree/stage3'
DEMO_URL = 'https://niccc8.github.io/rvbl2-riscv-cpu-core/demo/'

EXCLUDE_PREFIX = (
    'chipinventor/openlane/',
    'report-stage2/',
    'report-stage3/',
    'synth/',
    'macros/',
    '.git',                    # .gitignore, .gitattributes
    'docs/.nojekyll',
)

README = """LaneX on RVBL-2 -- Equipe 13 -- ChampionCHIP eXperience, Stage 3
Source code archive

The report is uploaded separately as a PDF, and the video is a YouTube link.

  Video:          %(video)s
  GitHub:         %(repo)s
  Live demo:      %(demo)s

SUBMISSION GUIDE SECTION 9
  All developed source code
    Verilog ........... rtl/ (gpio.v, uart.v, address_decoder.v, the core)
                        chipinventor/blocks/ (the ChipInventor canvas blocks)
    C ................. application/firmware/ (lane/main.c, lib/, include/, bsp/)
    Testbenches ....... official-firmware-testbench/, application/testbench/, tb/
  Complete firmware
    Assembly .......... application/firmware/out/lane/asm/main.s   (the application)
                        with hal.s, divmod.s, crt0.s
    Binary ............ application/firmware/out/lane/firmware.bin
                        firmware.txt (the IMEM lines), firmware.dmp (disassembly)
    Official test fw .. official-firmware-testbench/firmware/

LAYOUT
  README.md                      the full guide to the project (start here)
  rtl/                           the processor, the GPIO and the UART (reference RTL)
  tb/                            a testbench for every module of rtl/, and for the SoC
  chipinventor/                  the design as drawn on ChipInventor: blocks, the canvas
                                 mirror (ci_top.v), the exported netlists (top.v,
                                 export_stage3.v), platform testbenches, export checks
  official-firmware-testbench/   brief section 3: the organisers' test firmware, our IMEM,
                                 testbenches and logs
  application/                   brief sections 4-6: LaneX
    PROTOCOL.md                    frames, records, decisions, timing
    firmware/                      the C firmware; out/lane/ is the delivered firmware
    testbench/                     the golden model and the firmware testbenches
    emulator-preview/              the ./emu command lines, played on the chip
    replay/                        the demonstration page generator
  tools/rvbl-firmware-builder/   the organisers' Firmware Builder, an unchanged copy
  docs/                          specifications; docs/demo/index.html is the demo page
  scripts/, tests/               regression drivers and test programs

REPRODUCING
  Needs Icarus Verilog and Python 3; to rebuild firmware, make and a RISC-V GNU
  toolchain (we used xPack GCC 13.2.0, riscv-none-elf).

    bash official-firmware-testbench/run.sh   official firmware: 34/34 checks
    make -C application/firmware              the application, the organisers' way
    bash scripts/run_all.sh                   every Stage 2 and Stage 3 testbench
    bash chipinventor/scripts/run_ci.sh       the ChipInventor design and its export

  All are self-checking and exit non-zero on any failure.

NOT INCLUDED
  Stage 2's physical design (GDS, GL netlists; in Phase 2's archive and on GitHub),
  the reports, the Stage 2 synthesis logs, and SkyWater's optional SRAM macro
  (used only with DMEM_MACRO=1).

ATTRIBUTION
  tools/rvbl-firmware-builder/ and official-firmware-testbench/firmware/ (main.s,
  firmware.txt) are the organisers' own, copied unchanged. Everything else is
  Equipe 13's own work.
""" % {'video': VIDEO_URL, 'repo': REPO_URL, 'demo': DEMO_URL}


def git(*args):
    return subprocess.run(('git',) + args, cwd=ROOT, check=True,
                          capture_output=True, text=True).stdout


def main():
    tracked = git('ls-files', '-z').split('\0')
    files = [f for f in tracked if f and not f.startswith(EXCLUDE_PREFIX)]

    dirty = set(git('diff', '--name-only', 'HEAD').split())
    dirty_in = sorted(f for f in files if f in dirty)
    if dirty_in:
        sys.stderr.write('uncommitted changes in files the archive includes:\n  %s\n'
                         'commit them first: the archive must match the commit.\n'
                         % '\n  '.join(dirty_in))
        return 1
    missing = [f for f in files if not os.path.isfile(os.path.join(ROOT, f))]
    if missing:
        sys.stderr.write('missing sources:\n  %s\n' % '\n  '.join(missing))
        return 1

    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr('%s/README.txt' % TOP, README)
        for f in files:
            z.write(os.path.join(ROOT, f), '%s/%s' % (TOP, f))

    size = os.path.getsize(OUT)
    limit = 20 * 1048576
    print('wrote %s' % OUT)
    print('  commit:  %s' % git('rev-parse', '--short', 'HEAD').strip())
    print('  entries: %d' % (len(files) + 1))
    print('  size:    %.2f MB   (Phase 2 portal limit: 20 MB)  %s'
          % (size / 1048576.0, 'OK' if size <= limit else 'TOO BIG'))
    if 'VIDEO-ID' in VIDEO_URL:
        print('  NOTE:    VIDEO_URL is still the placeholder')
    return 0 if size <= limit else 1


if __name__ == '__main__':
    sys.exit(main())
