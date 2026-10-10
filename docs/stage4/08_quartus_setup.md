# Quartus Prime Lite on Windows for the DE10-Lite: install, driver, first compile, programming

Follow top to bottom once. Sources (accessed 2026-10-10) are listed at the end; anything marked
**(check)** could not be confirmed from an official page and tells you what to look for.

## 0. Before you start (5 min)

- [ ] Windows 10 or 11, 64-bit. Altera's 25.1 Standard/Lite notes recommend specific Windows 10/11
      builds (see the release notes).
- [ ] **Disk:** keep **≥ 20 GB free** on the install drive. Altera lists ~14 GB for a full Lite
      install; installing only MAX 10 support needs less, but builds and temporary files need room.
- [ ] **Administrator rights for ~10 minutes.** The USB-Blaster driver install (§4) needs them.
      If this laptop has no admin account, arrange that first — it is the one step you cannot skip.
- [ ] The DE10-Lite and its USB A–B cable (it powers the board and is the programming cable).
- [ ] An Altera/Intel account may be needed to download **(check)**: the download page will ask.

## 1. Download (Quartus Prime **Lite** Edition, version **25.1std**, Windows)

Go to Altera's download page *"Quartus Prime Lite Edition Design Software Version 25.1 for
Windows"* (altera.com → Downloads → FPGA Development Tools). As of 2026-10-10 the newest Lite
release found is **25.1std** (page dated Nov 2025); if a newer **Lite** version is listed, it is fine
to use it, provided it lists **MAX 10** device support.

Two ways (pick one):

| Option | Download | Notes |
| --- | --- | --- |
| **Web installer (recommended)** | `qinst-lite-windows-25.1std-1129.exe` (~33 MB) | It downloads only what you tick in the next step |
| Offline | the Quartus Prime Lite setup file **and** the MAX 10 device file `max10-25.1std.0.1129.qdz` (~288 MB), **in the same folder** | Use if the venue/home network is slow or flaky |

## 2. Install

1. Run the installer. Accept the licence agreement.
2. **Components — tick only:**
   - **Quartus Prime Lite Edition** (the software)
   - **MAX 10 FPGA** device support
   - Untick other device families (Cyclone IV/V/10, Arria…) and **Questa**: we simulate with our
     own tools, so you do not need Questa or its licence. This saves several GB.
3. **Install folder:** accept the default, but **write it down** — you need it in §4 and §7. It
   must not contain spaces. Older versions used `C:\intelFPGA_lite\<version>`; 25.1 may use
   `C:\altera_lite\25.1std` **(check: whatever the installer shows)**. Below it is called `<Q>`.
4. If the installer offers **"Install USB-Blaster driver"** (or "Install devices drivers"), leave it
   **ticked** — that may do §4 for you.
5. Finish. Launch **Quartus Prime Lite**. If it asks about a licence, choose **run the Quartus
   Prime software** (Lite needs no licence).

## 3. Connect the board

Plug the DE10-Lite into the laptop with the USB cable (the USB-B port, labelled
"5V Power & USB-Blaster"). The **POWER GOOD** LED lights, and the factory demo starts (LEDs and
7-segment digits move).

## 4. USB-Blaster driver (needs admin)

The DE10-Lite has an on-board **USB-Blaster** (the original one, not "USB-Blaster II").

1. Open **Device Manager** (Win+X → Device Manager).
2. If you see **JTAG cables → Altera USB-Blaster**, the driver is already installed: go to §5.
3. Otherwise you see **Other devices → USB-Blaster** with a yellow mark. Right-click it →
   **Update driver** → **Browse my computer for drivers** → **Browse…** → select
   `<Q>\quartus\drivers\usb-blaster` and keep **Include subfolders** ticked → **Next**.
   (Do not pick the `x32`/`x64` subfolders yourself.)
4. If Windows warns it cannot verify the publisher: choose **Install this driver software anyway**.
5. Device Manager now shows **JTAG cables → Altera USB-Blaster**.

**If it fails on Windows 11:**

| Symptom | Fix (in this order) |
| --- | --- |
| "Windows encountered a problem installing the driver" | Altera's knowledge base: install the driver from the `drivers` folder of **Quartus Prime 17.0 or 17.1** (Standard Edition or the stand-alone Programmer) instead |
| The driver installs but is blocked ("a driver can't load on this device") | Windows Security → Device security → Core isolation → **Memory integrity: Off**, reboot, install, then decide whether to turn it back on (programming needs the driver to load) |
| Nothing appears in Device Manager | Try another USB port/cable; the board must show POWER GOOD |

## 5. Check the cable in Quartus

1. Quartus → **Tools → Programmer**.
2. **Hardware Setup…** → *Currently selected hardware*: **USB-Blaster [USB-0]** → Close.
3. Click **Auto Detect**. It finds the MAX 10 (**10M50DA…** / 10M50DAF484). If asked to pick a
   device, choose **10M50DAF484C7G**.

✓ If you see the device, the toolchain is ready.

## 6. Compile the LaneX project (after I deliver `stage4/de10lite/`)

You do **not** need the Pin Planner: the project's `.qsf` already contains the device, every pin,
the I/O standard (3.3-V LVTTL), the weak pull-ups on the sensor inputs and the flash settings —
taken from Terasic's schematic and pin tables.

1. **File → Open Project…** → `stage4\de10lite\lanex.qpf`.
2. **Processing → Start Compilation** (or Ctrl+L). A few minutes.
3. Check, in the Compilation Report:
   - **Flow Summary:** device 10M50DAF484C7G; logic elements roughly 15–20k of 49,760.
   - **Timing Analyzer → Slow 1200mV 85C Model → Fmax Summary:** the core clock's Fmax must be
     **≥ 31.25 MHz**, and there must be no red "Timing requirements not met". If it is lower, tell
     me the number: I regenerate the project at 25 MHz (one switch) and you recompile.
4. (Optional) **Tools → Pin Planner** to see the assignments: `CLOCK_50` on PIN_P11, `KEY[0]` on
   PIN_B8, `SW[0]` on PIN_C10, `LEDR[0]` on PIN_A8, `HEX0[0]` on PIN_C14, `GPIO[0]` on PIN_V10.

Command line (same result), from a terminal in `stage4\de10lite`, with `<Q>\quartus\bin64` on PATH:

```text
quartus_sh --flow compile lanex
```

## 7. Program the board

**Quick test (RAM, lost at power-off):** Programmer → **Add File…** →
`output_files\lanex.sof` → tick **Program/Configure** → **Start**. Progress 100 %: the board runs
our design immediately.

**Permanent (internal flash, boots by itself — use this for the demo):** Programmer → remove the
`.sof` → **Add File…** → `output_files\lanex.pof` → tick **Program/Configure** (it selects the
configuration flash and the settings) → **Start**. Then unplug and replug power: the demo starts on
its own, with no laptop (the MAX 10 configures itself from its internal flash at power-up).

## 8. Host link drivers (only for plan A/B in `07` §5)

| Bridge | Driver |
| --- | --- |
| CP2102 module | Usually installed automatically by Windows Update; otherwise Silicon Labs "CP210x VCP" driver |
| CH340 module | Usually automatic; otherwise WCH "CH341SER" driver |
| FT232 module | Usually automatic (FTDI VCP) |
| Raspberry Pi Pico with Debugprobe | None (standard USB serial) |

Check: Device Manager → **Ports (COM & LPT)** shows the new COM port. The dashboard needs
**Chrome or Edge** (it uses the browser's Web Serial API).

## 9. Troubleshooting

| Problem | Likely cause | Fix |
| --- | --- | --- |
| Programmer: "No hardware" | Driver (§4) or Hardware Setup not set | §4, then Hardware Setup → USB-Blaster |
| "Can't recognize silicon ID" / JTAG chain error | Cable/port, or the board not powered | Replug; POWER GOOD on; another USB port |
| Compile error about a missing file | Project opened from a different folder | Open `lanex.qpf` from `stage4\de10lite` inside the repo |
| Timing not met | The core path on MAX 10 is slower than on UltraScale+ | Report the Fmax; regenerate at 25 MHz |
| After power cycle the board runs the factory demo again | Only the `.sof` was programmed | Program the `.pof` (§7) |

## Sources

- Altera, *Quartus Prime Lite Edition Design Software Version 25.1 for Windows* (download page; web
  installer `qinst-lite-windows-25.1std-1129.exe`, MAX 10 package `max10-25.1std.0.1129.qdz`):
  https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-25-1-windows
- Quartus Prime Standard/Lite 25.1std Software and Device Support Release Notes (OS and disk
  sections; "all information for Standard Edition also applies to Lite Edition"):
  https://www.intel.com/content/www/us/en/docs/programmable/683593/25-1std/version-software-and-device-support.html
- Altera, *Cables and Adapter Driver Installation Guide*:
  https://www.altera.com/design/guidance/software/cables-and-adapter-drivers-installation-guide
- Altera knowledge base, "Update Driver Software – USB-Blaster: Windows encountered a problem…"
  (use the 17.0/17.1 driver): https://community.altera.com/kb/knowledge-base/update-driver-software---usb-blaster-windows-encountered-a-problem-installing-th/345148
- Terasic wiki, Altera USB Blaster driver installation:
  https://www.terasic.com.tw/wiki/Altera_USB_Blaster_Driver_Installation_Instructions
- Windows 11 / Memory integrity note: UPC DE10-Lite course page
  https://digsys.upc.edu/csd/units/DE10_Lite/DE10_Lite.html
- MAX 10 internal-flash programming (`.pof` into CFM over JTAG): Intel MAX 10 FPGA Configuration
  User Guide, https://intel.com/content/www/us/en/docs/programmable/683865/current/programming-pof-into-internal-flash.html
- DE10-Lite pins and polarities: Terasic DE10-Lite schematic (rev B1, sheets 4, 7, 13, 14),
  https://mil.ufl.edu/3701/docs/DE10/DE10-Lite_Schematic.pdf ; pin table
  https://www.iuma.ulpgc.es/roberto/ed/practicas/DE10-Lite-info.html
- Raspberry Pi Debugprobe (Pico UART on GP4/GP5, 115,200): https://github.com/raspberrypi/debugprobe
  (`include/board_pico_config.h`)
