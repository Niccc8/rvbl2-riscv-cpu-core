# The desk gantry: a printed MLFF gantry for the HC-SR04

A desk-sized model of a free-flow toll gantry, printed in one go on the Bambu Lab A1. It holds the
ultrasonic sensor looking straight down at the lane, carries its wires in a channel to the
roadside cabinet, and holds the DE10-Lite, the breadboard and the USB-UART in that cabinet.

![The assembled gantry](print/preview_assembly.png)

## What to print (copy these to the SD card)

| File (`print/`) | What | A1 time | PLA |
| --- | --- | --- | --- |
| `LaneX_gantry_A1.gcode.3mf` | **The whole gantry**: frame, left footing, cabinet tray, one plate | 7 h 21 min | 211 g |
| `LaneX_gantry_FIT_TEST_A1.gcode.3mf` | Optional: the (revised) sensor pod, one post foot, one socket | 1 h 14 min | 26 g |

Both are sliced with **your own Bambu Studio settings** (taken from your traffic-light job): Bambu
Lab A1, 0.4 mm nozzle, 0.20 mm Standard, Generic PLA, **Textured PEI plate**. Changes from those
settings: no support (the design needs none), no brim, gyroid infill; frame 2 walls / 10 % infill
(light up high), footing and tray 4 walls / 40 % (heavy down low).

**On the printer:** put the SD card in, touch Print files, pick the file, check the plate is the
Textured PEI, start. Any PLA colour works; the A1 asks which spool to use.

If the printer refuses the file (it was sliced in OrcaSlicer 2.4.2, the open-source sibling of Bambu
Studio): open `LaneX_gantry_BambuStudio_project.3mf` in Bambu Studio, choose your A1 / 0.20 mm
Standard / Generic PLA, Slice, then Export plate sliced file. The STL files are there too.

## What the first fit test (12 Oct) changed

The tenon and socket fitted. The sensor pod did not, because this HC-SR04 differs from its
datasheet drawing. The design now follows the board itself (measured on the fit-test photos):

| Found | Cause | Now |
| --- | --- | --- |
| The crystal (silver oval) was blocked by two tabs in the middle | It lies **across** the board (≈11.5 mm) at the edge opposite the header; the slot was 6.4 mm | A 15 mm slot the full depth of the pod; the middle tabs are gone |
| The sensor would not push in | A chip on the back runs to within ~0.5 mm of the board's end, under a 1.2 mm ledge with 0.8 mm headroom | No ledges: one full-width pocket, 7.1 mm tall (board 1.6 + 5.5 headroom; chips are 2 mm) |
| Tight overall | 0.35 mm at the ends, 0.6 mm round the transducers | 0.6 mm at the ends, 0.8 mm round the transducers |
| The header jammed under the roof | Its pins stand **straight up** from the back, and the plugs on top of them make a 16 mm stack | An open notch over the header: the pins and plugs stand up in front of the beam |
| A slot in the pod's top | The wire channel above was cut too far down | The channel now stops above the pod |

The checks now model this board (crystal across, chips at the ends, upright or bent header, and
every part at its tolerance extremes) and slide it in from 40 mm out at each size. Replayed
against the pod you printed, the same model collides with the middle tabs 19.5 mm from home, as
yours did. The new pod clears every case.

## Fitting the sensor

1. Plug the four jumpers onto its pins first.
2. Hold it face down: the two silver cans pointing down, the header edge towards you. Its pins and
   plugs point up.
3. Slide it into the pod from the front. The cans run in the two U-slots until they stop at the end;
   the plugs stand up through the open notch in front of the beam. The board passes a small bump
   at each end of the opening (a light click) that keeps it from sliding out.
4. **The joint:** push each tenon into its socket and press down. It wedges tight with no wobble,
   about 0.7 mm before the post's shoulder touches the socket top. That small gap is deliberate: it's
   what makes the joint play-free (your fit test confirmed it).

| If | Do |
| --- | --- |
| The sensor won't go in, or the cans rub | Measure the distance between the cans' centres (normally 26 mm). Tell me the number; it's one parameter (`CAN_PITCH`) |
| The tenon won't go in, or stops more than 3 mm high | Your printer prints holes tighter than usual: set `PRELOAD` to 0.0 (or −0.05) |
| The tenon goes all the way down and still wobbles | Holes print loose: set `PRELOAD` to 0.10 |

## Assembly

1. **Unplug the parts from the plate.** Nothing to remove: there is no support and no brim.
2. **Feet:** stand the frame up and push its two tenons into the footing (the side with the coin
   cups) and the tray. Press down firmly on top of each post; the wedges lock.
   To take it apart, rock a footing gently while pulling it down.
3. **Sensor:** as above: jumpers on first, then slide it into the pod from the front.
4. **Wires:** the channel on the front face takes the four jumpers. Press them in with a fingernail
   and they stay in (the channel is narrower at its mouth). The route: from the plugs, bend the
   wires back into the short channel just above the pod, then along the beam, round the corner,
   down the right post, over the groove in the socket boss, into the tray.
   The route is **442 mm** from the sensor plugs to the breadboard, so use **50 cm female-to-male jumpers**
   (female on the sensor's pins, male into the breadboard), or join a 30 cm and a 20 cm. If you join
   them, stagger the joints so they don't sit side by side in the channel.
5. **Cabinet tray** (each place sized from the part's real outline, connectors included):
   - **DE10-Lite**, on its four brass standoffs, between the two pairs of low side rails. Turn it so
     its **USB-B socket faces the tray's back end** (the end with the "RVBL-2 inside" label), where
     the cable has room. Its VGA and USB-B shells overhang the board's short edges, so nothing in the
     tray comes near those edges.
   - **400-point breadboard** in its frame (88 × 60 mm: room for clones and their joining tabs).
   - **UC00C** between its two rails, **USB end towards the tray's front edge**; both ends stay clear
     for the micro-USB plug and the jumper plugs.
   Nothing is clamped; every part has 1–3 mm to spare.
6. **Ballast (recommended):** the four cups on the left footing each hold about ten coins. Forty
   50-sen coins double the push it takes to tip it over (see below). A pea of Blu-Tack under each
   footing also stops it sliding.
7. Wire as in the lab brief (E4), power up, press KEY0 with the lane empty so the board learns the
   floor, then roll a toy under the sensor.

## Numbers

| | |
| --- | --- |
| Sensor height | transducer faces **194 mm** above the table (the lab brief's range is 150–250 mm) |
| Lane | **216 mm** clear between the posts; beam underside 214 mm above the table |
| Footprint | 200 mm along the road × 365 mm across (footing to tray edge) |
| Print | one plate, 7 h 21 min, 211 g (your old traffic light: four prints, ~330 g) |

### Why it won't wobble or tip

Your old stand moved because of **play in its joints**: square poles in square sockets. A 0.2 mm
slip fit over a 13 mm socket rocks 1.8°, which is 7.6 mm at the top. Here the tenons are **wedges**,
tapered 4.3° on the sides and 5.7° on the front face, in matching sockets 0.05 mm smaller. They lock
with zero play, and PLA on PLA self-locks below ~16°, so they stay put.

Tipping is plain statics (`stability.py`, with the slicer's own part masses). This is the horizontal
push at the top of the beam that tips it over:

| | Mass | Push to tip it forward | Leans before tipping |
| --- | --- | --- | --- |
| This gantry, empty tray, no coins (worst case) | 220 g | 0.87 N (an 89 g weight) | 50° |
| This gantry + 40 coins in the cups | 446 g | **1.78 N** (181 g) | 64° |
| Your previous stand (estimated from its files) | ~300 g | 0.74 N | 36° |

The DE10-Lite and breadboard in the tray add more. Sideways it's even steadier: the posts are
230 mm apart.

### The sensor's view

The posts are 216 mm apart so that nothing sits inside the sensor's beam: the datasheet gives
30° (±15°), and the posts are 31° off-axis at the table. The CAD check proves the 30° cone is empty.
A wider 45° cone just grazes the bosses' lane-side edges at table level. Those edges are chamfered
45° so any side lobe glances off.

## What the checks prove (`gantry_cad.py`, every run)

- The sensor, modelled as photographed (crystal across, chips to the ends, solder tails, upright or
  bent header with plugs), fits at home **and** slides in from 40 mm out (0.5 mm steps) without
  touching anything, in 10 cases: nominal, transducer pitch 25.4 / 26.6, board 45.5 × 20.5 and
  44.5 × 19.5, transducers 9.6 / 10.4 mm from the back edge, 16.2 mm transducers, a 12.2 mm crystal.
- Pod clearances: 0.6 mm at the ends, 0.8 mm round the transducers, 1.6 mm each side of the crystal,
  3.5 mm over the chips, 1.2 mm behind the board. The detent stops a 1.5 mm pull; the floor holds it.
- Nothing is inside the 30° acoustic cone.
- The wedge tenons lock with zero play, 0.67 mm before the shoulders land; nothing else touches on
  the way in.
- The DE10-Lite (97.5 × 80, on standoffs as low as 6 mm, with its pin tails, its VGA and USB-B shells
  overhanging the short edges, and the USB cable plug), a 400-point breadboard at clone maximum
  with its tabs (87 × 59), and the UC00C with its micro-USB plug and jumper plugs touch nothing in
  the tray, and stay 8–30 mm apart.
- Every part, and the fit-test pieces, print with **zero unsupported area** on every 0.2 mm layer;
  everything fits the A1 bed 6 mm from the edges, clear of its front calibration line; each part is
  one closed solid.
- The sliced G-code (`slice_gantry.py`): no support, every extrusion on the bed, stamped as an A1 file.

## Changing it

Every dimension is a parameter at the top of `gantry_cad.py`. To rebuild everything:

```text
build\pitchenv\Scripts\python stage4\de10lite\gantry\gantry_cad.py      # CAD + checks -> out/
build\pitchenv\Scripts\python stage4\de10lite\gantry\render_gantry.py   # preview scenes
build\pitchenv\Scripts\python stage4\de10lite\gantry\slice_gantry.py    # G-code for the A1
build\pitchenv\Scripts\python stage4\de10lite\gantry\stability.py       # the tipping numbers
```

The slicer is OrcaSlicer 2.4.2 portable, in `build/tools/orca` (git-ignored); the print settings are
`a1_bambu_studio_settings.json` (your Bambu Studio 1.9.5 A1 profile). Copy new results from `out/`
to `print/`.
