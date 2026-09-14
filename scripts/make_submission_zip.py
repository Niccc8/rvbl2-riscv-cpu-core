#!/usr/bin/env python3
"""Build the Phase 2 source-code archive for the submission portal.

    python3 scripts/make_submission_zip.py

Writes RVBL2_Equipe13_source.zip at the repository root.

The portal caps this upload at 20 MB. top.gds is 48.7 MB raw but deflates to
about 9.7 MB, so the whole archive lands near 10.7 MB.

What goes in is driven by Submission Guide section 9. The report is NOT here --
it uploads through its own PDF slot -- and the video is a URL, not a file.

Two structural decisions worth recording:

  * The OpenLane output keeps its real path, results/final/verilog/gl/.
    Section 9 names that folder explicitly, so an evaluator looking for it finds
    it where the guide says it should be. Flattening would have been smaller to
    describe and worse to grade.

  * macros/ is excluded. Safe: rtl/dmem.v only instantiates the SkyWater SRAM
    macro under `ifdef DMEM_USE_SRAM_MACRO, which is off by default, so the
    default build and both verification suites are unaffected. Verified by
    extracting the archive and running both suites from the extracted copy.
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

OUT = os.path.join(ROOT, 'RVBL2_Equipe13_source.zip')
TOP = 'rvbl2_equipe13'
RUN = 'chipinventor/openlane/runs/platform_20260904'

VIDEO_URL = 'https://youtu.be/CcPI3QoY-no'
REPO_URL = 'https://github.com/Niccc8/rvbl2-riscv-cpu-core'

SKIP_EXT = ('.pyc', '.vvp', '.vcd')
SKIP_DIR = ('__pycache__', 'build')

files = []


def add_tree(src, dst):
    base = os.path.join(ROOT, src.replace('/', os.sep))
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR]
        for fn in sorted(filenames):
            if fn.endswith(SKIP_EXT):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, base).replace(os.sep, '/')
            files.append((full, '%s/%s/%s' % (TOP, dst, rel)))


def add_file(src, dst):
    files.append((os.path.join(ROOT, src.replace('/', os.sep)), '%s/%s' % (TOP, dst)))


# ---- section 9: all developed code, including testbenches ---------------
for d in ('rtl', 'tb', 'tests', 'scripts'):
    add_tree(d, d)

# ---- the submitted implementation ---------------------------------------
for d in ('blocks', 'firmware', 'rtl_ref', 'scripts'):
    add_tree('chipinventor/' + d, 'chipinventor/' + d)
for f in ('ci_top.v', 'top.v', 'tb_chipinventor.v',
          'README.md', 'NETLIST.md', 'BLOCK_METADATA.md', 'VALIDATION.md'):
    add_file('chipinventor/' + f, 'chipinventor/' + f)

# ---- section 9: config.json used by the OpenLane synthesis --------------
add_file('chipinventor/openlane/config.json', 'openlane/config.json')
add_tree('chipinventor/openlane/src', 'openlane/src')
add_file('chipinventor/openlane/README.md', 'openlane/README.md')
add_file('chipinventor/openlane/RESULTS.md', 'openlane/RESULTS.md')

# ---- section 9: GDSII, and the GL netlist in its stated folder ----------
add_file(RUN + '/results/final/gds/top.gds', 'openlane/results/final/gds/top.gds')
add_file(RUN + '/results/final/verilog/gl/top.v',
         'openlane/results/final/verilog/gl/top.v')
add_file(RUN + '/results/final/verilog/gl/top.nl.v',
         'openlane/results/final/verilog/gl/top.nl.v')
add_file(RUN + '/config_in.tcl', 'openlane/results/config_in.tcl')

README = """RVBL-2 -- Equipe 13 -- ChampionCHIP eXperience Phase 2
Source code archive

The report uploads separately as a PDF, and the demonstration video is a
YouTube link, so neither is in this archive.

  %(video)s
  %(repo)s

SUBMISSION GUIDE SECTION 9
  GDSII ................ openlane/results/final/gds/top.gds
  GL netlist ........... openlane/results/final/verilog/gl/top.v      (powered)
                         openlane/results/final/verilog/gl/top.nl.v   (non-powered)
  config.json .......... openlane/config.json
  All developed code ... rtl/  tb/  tests/  scripts/  chipinventor/

LAYOUT
  rtl/            Reference design, hierarchical, 16 modules.
  tb/             16 testbenches covering every module.
  tests/          Golden vectors and assembly test programs.
  scripts/        Firmware assembler, regression driver, synthesis helpers.
  chipinventor/   The submitted implementation, flattened for the block canvas.
                  blocks/     the 17 canvas blocks
                  ci_top.v    flattened top level
                  top.v       the netlist the platform exported
                  rtl_ref/    snapshot of rtl/ the equivalence test runs against
                  firmware/   official validation firmware + a coverage program
  openlane/       config.json, the synthesised source, and the signed-off output.

REPRODUCING
  Requires Icarus Verilog and Python 3. No PDK, licence or network needed.

    bash scripts/run_all.sh              15 testbenches, 7,384 checks
    bash chipinventor/scripts/run_ci.sh  12 gates, 15,281 checks, firmware verdict

  Both are self-checking and exit non-zero on any failure.

NOTE
  macros/ (an optional SkyWater SRAM macro) is not included. rtl/dmem.v only
  instantiates it under `ifdef DMEM_USE_SRAM_MACRO, which is off by default, so
  the default build and both suites run without it.
""" % {'video': VIDEO_URL, 'repo': REPO_URL}


def main():
    missing = [s for s, _ in files if not os.path.isfile(s)]
    if missing:
        sys.stderr.write('missing sources:\n  %s\n' % '\n  '.join(missing))
        return 1

    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr('%s/README.txt' % TOP, README)
        for src, dst in files:
            z.write(src, dst)

    size = os.path.getsize(OUT)
    limit = 20 * 1048576
    print('wrote %s' % OUT)
    print('  entries: %d' % (len(files) + 1))
    print('  size:    %.2f MB   (portal limit 20 MB)  %s'
          % (size / 1048576.0, 'OK' if size <= limit else 'TOO BIG'))
    return 0 if size <= limit else 1


if __name__ == '__main__':
    sys.exit(main())
