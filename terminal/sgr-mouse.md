# Mouse Reporting (Any-Event Pixel Tracking)

## Mode Control

This implementation utilizes Any-Event Tracking (1003) alongside SGR-Pixel encoding (1016).  
Mode 1003 selects which events are reported, while 1016 changes the coordinate encoding to pixels.  

`\e[?1003;1016h`
  Enable

`\e[?1003;1016l`
  Disable

Under mode 1003, every press, release, drag, and bare motion event is reported, whether or not a button is held.

## Report Format

Coordinates are measured in exact pixels relative to the window origin:

- Press / Drag / Motion / Scroll / Leave: `CSI < Pb ; Ppx ; Ppy M`
- Release: `CSI < Pb ; Ppx ; Ppy m`

The final `M` or `m` distinguishes a press from a release, preventing any button number from being overloaded to mean "release".

## Button Field (`Pb`)

The low bits carry the button identity, while the high bits carry modifiers and the event class:

Button Bits (low two bits, or the indicator flags below):
- 0: Left
- 1: Middle
- 2: Right
- 3: No button (motion with nothing held)

Indicator Bits:
- `4` (1 << 2): Shift
- `8` (1 << 3): Alt
- `16` (1 << 4): Ctrl
- `32` (1 << 5): Drag (32|33|34) / Hover (35)
- `64` (1 << 6): Scroll (up: 64, down: 65, left: 66, right: 67)
- `128` (1 << 7): Extra button
- `256` (1 << 8): Leave window

Scroll Buttons (`64` + low bits):
- 64: Wheel up
- 65: Wheel down
- 66: Wheel left
- 67: Wheel right

Extra Buttons (`128` + low bits):
- 128: Aux8
- 129: Aux9
- 130: Aux10
- 131: Aux11

Modifier bits reflect shift, alt, and ctrl states only; lock modifiers are not reported.

Common Values:
- 0: Left press or release
- 1: Middle press or release
- 2: Right press or release
- 32: Left drag
- 33: Middle drag
- 34: Right drag
- 35: Motion, no button held
- 64: Wheel up
- 65: Wheel down
- 4: Shift + left
- 16: Ctrl + left
- 20: Ctrl + shift + left
- 48: Ctrl + left drag
- 256: Leave window

Wheel events are reported strictly as presses without matching releases.  
Scrolling multiple lines emits consecutive reports per line.

## Encoding Behavior

### Coordinates

Supplied in exact pixel integers rather than cell columns/rows.

### Motion Granularity

Emitted at a high frequency whenever the pointer moves.

### Mouse Leave

Emitted when the pointer exits the terminal window.  
The coordinates reflect the last known position and are frequently reported as `0, 0`.

## Parsing Logic

1. Ensure the sequence begins with `CSI <` and terminates with `M` or `m`.
2. Extract three `;`-separated decimal parameters: `Pb`, `Ppx`, and `Ppy`.
3. Extract modifier bits: `4` (Shift), `8` (Alt), and `16` (Ctrl).
4. Decode the specific event type from `Pb` in priority order:
- Check `Pb & 256`: If non-zero, emit a `Leave` event.
- Check `Pb & 64`: If non-zero, emit a `Scroll` event (mapping the low two bits to Up, Down, Left, or Right).
- Check `Pb & 32` AND verify `(Pb & 3) == 3`: Emit a `Hover` event for bare pointer motion.
- For all other states, identify the button (Aux8-11 if `Pb & 128` is set, otherwise Left/Middle/Right).
5. Finalize the action based on the sequence terminator and dragging state:
- If the final byte is `m`, emit a `Release`.
- If the final byte is `M` and `Pb & 32` is non-zero, emit a `Drag`.
- Otherwise, emit a `Press`.

## Pixel-to-Cell Conversion

Because 1016 reports in pixels, the raw `Ppx, Ppy` values are not directly usable as terminal columns and rows. Convert them by dividing by the cell dimensions:

- `col = Ppx / cell_width`
- `row = Ppy / cell_height`

The cell dimensions come from the terminal (for example via the `TIOCGWINSZ` ioctl, which yields both the character grid and the pixel dimensions, or from a `CSI 16 t` size report). Deriving `cell_width` and `cell_height` as `pixel_extent / cell_count` keeps the conversion accurate across resizes and font changes.

Guidelines:
- Keep both representations available: pixel coordinates for precise gestures (drag radius, velocity), cell coordinates for grid-aligned hit testing (widgets, text selection).
- Use integer (floor) division for the cell index; retain the pixel remainder if you need the offset within a cell.
- Recompute cell dimensions on resize; a stale divisor silently skews every subsequent conversion.
- The `0, 0` fallback coordinates on `Leave` map to cell `0, 0`; treat them as invalid rather than a real corner hit.

## Derived Events

The raw reports above (Press, Release, Drag, Hover, Scroll, Leave) can be composed into higher-level events by tracking state across successive reports. These are not sent by the terminal; the parser synthesizes them.

### Click

A `Press` followed by a `Release` on the same button, within a small pixel radius and time window. Pixel encoding makes the radius check exact.

### Double-Click / Triple-Click

Consecutive `Click`s of the same button falling inside a time window and pixel radius. Increment a counter; reset it when either bound is exceeded.

### Drag Lifecycle

The terminal reports each drag motion independently. Bracket them into:
- **Drag Start** — the first `Drag` following a `Press`.
- **Drag Move** — the intermediate `Drag` reports.
- **Drag End (Drop)** — the `Release` that terminates the sequence.

### Enter

The terminal only reports `Leave`. Infer an `Enter` when a motion or hover report arrives after a prior `Leave`, or as the first report seen with no preceding `Leave`.

### Hover Dwell (Begin / End)

Detect when motion stops for a threshold duration at a position, or when the pointer settles over a region. Useful for tooltips. Emit `Hover End` when motion resumes.

### Motion Delta / Velocity

Subtract successive `Ppx, Ppy` pairs to obtain movement vectors, speed, and direction. Pixel resolution yields smooth, sub-cell values.

### Scroll Accumulation / Momentum

Multi-line scrolls arrive as consecutive per-line reports. Coalesce them into a single gesture with a magnitude, or compute scroll velocity from their arrival timing.

### Gesture Recognition

Swipes and flicks built on the drag lifecycle plus velocity thresholds; drag direction derived from the start-to-end vector.

### Chord / Multi-Button

Track which buttons are currently held to detect simultaneous presses.

### Long Press

A `Press` with no matching `Release` after a threshold duration.

### Caveat

Any derived event that depends on the exit position (edge-swipe detection, for example) cannot trust `Leave` coordinates, since they are frequently reported as `0, 0`. Fall back to the last valid motion report for position.