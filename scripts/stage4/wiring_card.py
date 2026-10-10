"""wiring_card.py - the printable wiring card for the DE10-Lite desk lane
(stage4/de10lite/wiring_card.html). Called by gen_de10lite.py with the same pin
table it writes into lanex.qsf, so the card and the FPGA can never disagree."""
import html

SHORT = {0: "from laptop TXD", 1: "to laptop RXD", 2: "Echo (divider)", 3: "Trig", 4: "green lamp",
         5: "white lamp", 6: "red lamp", 7: "buzzer", 8: "closed lamp"}
POWER = {11: ("5 V", "#b91c1c", "ultrasonic VCC only"), 12: ("GND", "#111827", "ultrasonic GND"),
         29: ("3.3 V", "#c2410c", "buzzer VCC"), 30: ("GND", "#111827", "ground")}

PARTS = [
    ("Ultrasonic sensor HC-SR04 (4 pins: VCC Trig Echo GND)", "1",
     "Mounted above the lane, looking down: it measures each vehicle's height. VCC from pin 11 (5 V)."),
    ("Resistors 1 k&Omega; and 2 k&Omega; (or 2 &times; 1 k&Omega; in series)", "1 each",
     "The Echo divider: 5 V &rarr; 3.3 V. <b>Never</b> wire Echo straight to the board."),
    ("LED + resistor: green, red, yellow (330 &Omega;) and white (100 &Omega;)", "1 each",
     "Long leg (anode) to the resistor, the resistor to the GPIO pin; short leg to GND. "
     "A 3-LED traffic-light module (resistors built in) also works."),
    ("Active buzzer <b>module</b> (3 pins, with a transistor)", "1",
     "Not a bare 2-leg buzzer: the FPGA pin cannot drive one. If it sounds while idle, flip SW6."),
    ("USB-UART adapter, 3.3 V (CP2102, CH340 or FT232)", "1",
     "Set its jumper to 3.3 V. Do not connect its VCC/5V pin."),
    ("Mini breadboard (170 points) + female-female and male-female jumpers", "1 + ~20",
     "The divider sits here; pin 30 (GND) is the rail for the LEDs, the buzzer and the divider."),
    ("Toy car, and a toy lorry clearly taller than the car", "1 each",
     "The height difference is the classifier (default: lorry from 6 cm)."),
]

CONTROLS = [
    ("SW0", "Lane closed (the chip lights P7)"),
    ("SW2:SW1", "Class: 00 the sensor's height &middot; 01 van &middot; 10 lorry &middot; 11 motorcycle"),
    ("SW5:SW3", "Tag the next vehicle carries"),
    ("SW6", "Buzzer module is low-level trigger"),
    ("SW7", "Mute the buzzer"),
    ("SW8", "Manual: KEY1 is the vehicle (no sensor needed)"),
    ("SW9", "Tour: replay the 12 AWS tests &rarr; PASS12"),
    ("KEY0", "Reset (lamp test, banner, Id.56dE); the sensor relearns the floor"),
    ("KEY1", "Manual vehicle (SW8 up), else: fingerprint the ROM"),
]

LEDS = [
    ("LEDR0", "Something is under the sensor (sensor check)"),
    ("LEDR1", "That vehicle is tall: a lorry"),
    ("LEDR2", "The chip sees a vehicle (P0)"),
    ("LEDR3", "The laptop is sending"),
    ("LEDR4&ndash;7", "The chip's lamps: charged, camera, alarm, closed"),
    ("LEDR8", "The last record was signed"),
    ("LEDR9", "Self-check: the ROM fingerprint matches (or PASS12)"),
]


def render(wires, header_pin, gpio_pins, presets):
    by_pin = {}
    for g, d, sig, to, col in wires:
        by_pin[header_pin(g)] = (g, d, sig, to, col)
    # the 2 x 20 header, pin 1 top-left: odd pins in the left column, even in the right
    cells = []
    for row in range(20):
        for side in (0, 1):
            pin = 2 * row + 1 + side
            x = 40 + side * 34
            y = 30 + row * 22
            if pin in by_pin:
                g, d, sig, to, col = by_pin[pin]
                fill, label, note = col, "GPIO_%d" % g, SHORT.get(g, sig)
            elif pin in POWER:
                label, fill, note = POWER[pin][0], POWER[pin][1], POWER[pin][2]
            else:
                fill, label, note = "#e5e7eb", "", ""
            stroke = "#b91c1c" if pin == 11 else "#374151"
            cells.append('<rect x="%d" y="%d" width="24" height="16" rx="3" fill="%s" stroke="%s"/>'
                         '<text x="%d" y="%d" class="pn"%s>%d</text>'
                         % (x, y, fill, stroke, x + 12, y + 12,
                            ' fill="#fff"' if fill not in ("#e5e7eb", "#a3a3a3", "#eab308") else "", pin))
            if label:
                tx = x - 8 if side == 0 else x + 32
                anchor = "end" if side == 0 else "start"
                cells.append('<text x="%d" y="%d" class="lb" text-anchor="%s">%s</text>'
                             % (tx, y + 12, anchor, html.escape("%s  %s" % (label, note)) if side else
                                html.escape("%s  %s" % (note, label))))
    svg = ('<svg viewBox="-150 0 400 480" class="hdr" role="img" aria-label="DE10-Lite GPIO header JP1">'
           '<rect x="30" y="20" width="78" height="448" rx="8" fill="#f9fafb" stroke="#9ca3af"/>'
           '<text x="69" y="14" class="cap" text-anchor="middle">JP1 (pin 1 top-left)</text>'
           + "".join(cells) + "</svg>")

    rows = []
    for g, d, sig, to, col in wires:
        rows.append("<tr><td class='num'>%d</td><td><span class='sw' style='background:%s'></span>GPIO_%d</td>"
                    "<td class='mono'>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                    % (header_pin(g), col, g, gpio_pins[g], "in" if d == "in" else "out",
                       html.escape(sig), html.escape(to)))
    for pin in sorted(POWER):
        name, col, note = POWER[pin]
        rows.append("<tr class='%s'><td class='num'>%d</td><td><span class='sw' style='background:%s'></span>%s</td>"
                    "<td class='mono'>&ndash;</td><td>&ndash;</td><td>%s</td><td>%s</td></tr>"
                    % ("danger" if pin == 11 else "", pin, col, name,
                       "Board 5 V" if pin == 11 else ("3.3 V supply" if pin == 29 else "Ground"),
                       "<b>HC-SR04 VCC only</b> (nothing else)" if pin == 11 else
                       ("buzzer module VCC" if pin == 29 else
                        ("HC-SR04 GND and the USB-UART GND" if pin == 12 else
                         "breadboard &minus; rail &rarr; the 2 k&Omega;, LEDs, buzzer GND"))))

    tags = "".join("<li><b>%d</b> %s</li>" % (p, html.escape(presets[p][0])) for p in range(8))
    parts = "".join("<tr><td>%s</td><td class='num'>%s</td><td>%s</td></tr>" % p for p in PARTS)
    ctl = "".join("<tr><td class='mono'>%s</td><td>%s</td></tr>" % c for c in CONTROLS)
    leds = "".join("<tr><td class='mono'>%s</td><td>%s</td></tr>" % c for c in LEDS)

    return PAGE.replace("{SVG}", svg).replace("{ROWS}", "\n".join(rows)).replace("{TAGS}", tags) \
               .replace("{PARTS}", parts).replace("{CONTROLS}", ctl).replace("{LEDS}", leds)


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LaneX Wiring Card</title>
<!-- GENERATED by scripts/stage4/gen_de10lite.py (wiring_card.py) from the pin table in lanex.qsf -->
<style>
  :root { --ink: #111827; --muted: #4b5563; --line: #d1d5db; --soft: #f3f4f6; --red: #b91c1c; --accent: #0369a1; }
  * { box-sizing: border-box; }
  body { margin: 0; background: #fff; color: var(--ink); font: 13px/1.45 "Segoe UI", system-ui, -apple-system, Arial, sans-serif; }
  .page { max-width: 1120px; margin: 0 auto; padding: 22px 26px; }
  h1 { font-size: 22px; margin: 0; }
  h2 { font-size: 14px; text-transform: uppercase; letter-spacing: 1px; color: var(--accent); margin: 18px 0 8px; }
  .sub { color: var(--muted); margin: 2px 0 0; }
  .top { display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; border-bottom: 2px solid var(--ink); padding-bottom: 10px; }
  .grid { display: grid; grid-template-columns: 400px minmax(0, 1fr); gap: 22px; margin-top: 12px; }
  .hdr { width: 100%; height: auto; }
  .hdr .pn { font: 700 9px Consolas, monospace; text-anchor: middle; fill: #111827; }
  .hdr .lb { font: 11px "Segoe UI", Arial, sans-serif; fill: #111827; }
  .hdr .cap { font: 600 10px "Segoe UI", Arial, sans-serif; fill: #4b5563; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: .6px; color: var(--muted); border-bottom: 1px solid var(--ink); padding: 5px 6px; }
  td { border-bottom: 1px solid var(--line); padding: 5px 6px; vertical-align: top; }
  .num { text-align: right; font-variant-numeric: tabular-nums; font-weight: 700; width: 36px; }
  .mono { font-family: Consolas, "Cascadia Mono", monospace; }
  td:nth-child(2) { white-space: nowrap; }
  .sw { display: inline-block; width: 11px; height: 11px; border-radius: 3px; margin-right: 6px; vertical-align: -1px; border: 1px solid rgba(0,0,0,.25); }
  tr.danger td { background: #fef2f2; color: var(--red); }
  .rules { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 14px; }
  .rule { border: 1.5px solid var(--ink); border-radius: 10px; padding: 9px 11px; }
  .rule.red { border-color: var(--red); background: #fef2f2; }
  .rule .t { display: block; font-size: 13.5px; font-weight: 700; margin-bottom: 3px; }
  .cols3 { display: grid; grid-template-columns: 1fr 1fr; gap: 28px; }
  td.mono { white-space: nowrap; }
  table.parts td:first-child { width: 34%; } table.parts td:nth-child(2) { width: 60px; white-space: nowrap; }
  ul.tags { list-style: none; padding: 0; margin: 0; columns: 2; }
  ul.tags li { padding: 2px 0; } ul.tags b { display: inline-block; width: 16px; color: var(--accent); }
  ol.steps { margin: 0; padding-left: 18px; } ol.steps li { margin: 3px 0; }
  .side { display: flex; gap: 14px; align-items: center; }
  .side svg { flex: none; }
  .note { color: var(--muted); font-size: 12px; }
  @media print { .page { padding: 0; max-width: none; } @page { size: A4 landscape; margin: 10mm; } h2 { margin-top: 12px; } }
  @media (max-width: 900px) { .grid, .cols3, .rules { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<div class="page">
  <div class="top">
    <div>
      <h1>LaneX desk lane &mdash; wiring card</h1>
      <p class="sub">Terasic DE10-Lite (MAX 10 10M50DAF484C7G) &middot; GPIO header JP1 &middot; pins as in <span class="mono">lanex.qsf</span></p>
    </div>
    <div class="note">Print: A4 landscape. Generated from the same pin table as the FPGA project.</div>
  </div>

  <div class="rules">
    <div class="rule red"><span class="t">5 V never reaches an FPGA pin.</span>The MAX 10 pins are not 5 V tolerant. Pin 11 (5 V) goes to the <b>ultrasonic VCC only</b>, and its <b>Echo goes through the divider</b>: Echo &rarr; 1 k&Omega; &rarr; pin 3, and pin 3 &rarr; 2 k&Omega; &rarr; GND.</div>
    <div class="rule"><span class="t">Measure first.</span>Board on, nothing plugged: multimeter <b>pin 29 &rarr; pin 30 = 3.3 V</b>, pin 11 &rarr; pin 12 = 5 V. That proves you hold the header the right way round.</div>
    <div class="rule"><span class="t">Wire with the board unplugged.</span>Then plug the USB in. With nothing wired the board still works: in manual mode (SW8) KEY1 is the vehicle, and the displays run the whole demo.</div>
  </div>

  <div class="grid">
    <div>{SVG}</div>
    <div>
      <h2>Connections</h2>
      <table>
        <thead><tr><th>Pin</th><th>Signal</th><th>FPGA</th><th>Dir</th><th>Function</th><th>Connect to</th></tr></thead>
        <tbody>
{ROWS}
        </tbody>
      </table>
      <h2>The gantry</h2>
      <div class="side">
        <svg viewBox="0 0 320 150" width="320" height="150" role="img" aria-label="Side view of the gantry">
          <rect x="10" y="134" width="300" height="4" fill="#9ca3af"/>
          <rect x="40" y="14" width="8" height="120" fill="#6b7280"/>
          <rect x="40" y="14" width="190" height="8" fill="#6b7280"/>
          <rect x="128" y="22" width="44" height="14" rx="3" fill="#0369a1"/>
          <circle cx="141" cy="36" r="5" fill="#94a3b8"/><circle cx="159" cy="36" r="5" fill="#94a3b8"/>
          <path d="M150 42 L132 132 M150 42 L168 132" stroke="#0369a1" stroke-dasharray="3 3"/>
          <text x="180" y="33" font-size="10">HC-SR04, looking down</text>
          <rect x="118" y="78" width="64" height="56" rx="3" fill="#fde68a" stroke="#b45309"/><text x="150" y="110" font-size="10" text-anchor="middle">lorry 9 cm</text>
          <rect x="222" y="104" width="64" height="30" rx="7" fill="#bfdbfe" stroke="#1d4ed8"/><text x="254" y="123" font-size="10" text-anchor="middle">car 4 cm</text>
          <path d="M300 92 L262 92" stroke="#111827" marker-end="url(#arr)"/><text x="268" y="86" font-size="9">push</text>
          <defs><marker id="arr" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto"><path d="M0,0 L6,3 L0,6 z" fill="#111827"/></marker></defs>
          <text x="54" y="80" font-size="10">15&ndash;25 cm</text>
        </svg>
        <p class="note">One sensor, 15&ndash;25 cm above the table, looking straight down at the lane. At power-up the lane must be empty: the board learns the floor. Push each toy under it at walking pace for a toy: the display shows the height it measured (<b>h&nbsp;&nbsp;4.5</b> = 4.5 cm); LEDR1 lights for a lorry (from 6 cm; <span class="mono">TALL_MM</span> in <span class="mono">lanex.qsf</span>).</p>
      </div>
    </div>
  </div>

  <h2>Parts</h2>
  <table class="parts"><thead><tr><th>Part</th><th>Qty</th><th>Note</th></tr></thead><tbody>{PARTS}</tbody></table>

  <div class="cols3">
    <div>
      <h2>Controls</h2>
      <table><tbody>{CONTROLS}</tbody></table>
      <h2>Tag presets (SW5:SW3)</h2>
      <ul class="tags">{TAGS}</ul>
    </div>
    <div>
      <h2>Lights</h2>
      <table><tbody>{LEDS}</tbody></table>
      <h2>Bring-up</h2>
      <ol class="steps">
        <li>Program the <span class="mono">.sof</span>: lamp test, banner, <b>Id.56dE</b>, LEDR9.</li>
        <li>SW9 up: <b>PASS12</b>. SW9 down.</li>
        <li>SW8 up, tag CAr, press KEY1: <b>CHArGE / 2.50</b>.</li>
        <li>Wire the sensor + divider (board unplugged); power up with the lane empty; a toy under it: LEDR0.</li>
        <li>Wire the lamps and buzzer; push the car, then the lorry.</li>
        <li>USB-UART + <span class="mono">lanex_live.html</span> in Chrome.</li>
        <li>Program the <span class="mono">.pof</span>: it boots by itself.</li>
      </ol>
    </div>
  </div>
</div>
</body>
</html>
"""
