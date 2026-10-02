# Terminal Events

A combined reference for terminal input handling across three channels: keyboard input via the Kitty protocol, mouse input via SGR pixel reporting, and terminal notifications (resize, focus, visibility, color scheme). Each channel pairs a raw wire format with a derived-event layer that the parser synthesizes from successive reports.

## Notation

- `CSI` is the Control Sequence Introducer (`ESC [`). Parameters are separated by `;`, sub-fields by `:`.
- DEC private modes are set with `CSI ? mode h` and reset with `CSI ? mode l`.
- Codepoints in the 57344–63743 range are in the Unicode Private Use Area (PUA).

## Keyboard

Keyboard handling uses the Kitty keyboard protocol with all five progressive enhancements enabled.

### Mode Control

The enhancements are flags in a bitmask; the value `31` enables the complete set:

| Flag | Name                   | Effect                                                                    |
|------|------------------------|---------------------------------------------------------------------------|
| 1    | Disambiguate           | Resolves overlaps with legacy control codes                               |
| 2    | Report Events          | Reports key repeat and key release events                                 |
| 4    | Report Alternates      | Reports shifted and base-layout key codes for robust shortcut matching    |
| 8    | Report All Keys        | Reports all keys as escape codes, including modifiers and plain-text keys |
| 16   | Report Associated Text | Embeds generated text directly in the escape code                         |

Push the flags on entry and pop on exit, so the prior mode is restored safely:

**Push:**  
`CSI > 31 u`  

**Pop:**  
`CSI < u`  

> Terminals maintain independent keyboard mode stacks for the main and alternate screens. If the application enters the alternate screen, push and pop the keyboard mode while inside it to avoid polluting the main screen's state.

### Report Format

With all enhancements active, every key event is delivered as a `CSI u` escape code (or with a letter / `~` suffix for some functional keys), carrying full key, modifier, event-type, and text information:

`CSI unicode-key:shifted-key:base-layout-key ; modifiers:event-type ; text-codepoints u`

Only the key code is mandatory:

- **`key`**: the un-shifted Unicode codepoint of the key (e.g. `97` for `a`), or a functional-key number (see the tables below). Always the lower-case / un-shifted value. For a pure text event with no known physical key (e.g. OS-level IME), this is `0`.
- **`shifted`**: the shifted codepoint (e.g. `65` for `A`); present only when the shift modifier is active.
- **`base`**: the codepoint of the same physical key in the standard PC-101 layout.
- **`modifiers`**: modifier bitfield, encoded as `1 + actual bits`.
- **`event-type`**: `1` press (default), `2` repeat, `3` release.
- **`text`**: associated text as one or more colon-separated decimal codepoints; never contains C0 or C1 control codes.

### Modifier Bits

| Modifier | Bit | Modifier  | Bit |
|----------|-----|-----------|-----|
| shift    | 1   | hyper     | 16  |
| alt      | 2   | meta      | 32  |
| ctrl     | 4   | caps_lock | 64  |
| super    | 8   | num_lock  | 128 |

The wire value is `1 + OR` of the active bits. A missing modifier field means no modifiers (value `1`).

### Functional Keys

Keys that do not represent printable text (functional keys, media keys, modifiers) use dedicated codepoints.

#### C0 Exceptions

For legacy compatibility, a few fundamental keys map to their C0 control code values:

| Key    | Code | Key       | Code  |
|--------|------|-----------|-------|
| ESCAPE | `27` | ENTER     | `13`  |
| TAB    | `9`  | BACKSPACE | `127` |

#### Legacy Functional & Cursor Keys

These commonly use the `CSI 1 ; modifiers letter` or `CSI number ; modifiers ~` format. The leading `1` is omitted when there are no modifiers.

| Key     | Encoding        | Key       | Encoding        |
|---------|-----------------|-----------|-----------------|
| UP      | `1 A`           | DOWN      | `1 B`           |
| RIGHT   | `1 C`           | LEFT      | `1 D`           |
| HOME    | `1 H` or `7 ~`  | END       | `1 F` or `8 ~`  |
| INSERT  | `2 ~`           | DELETE    | `3 ~`           |
| PAGE_UP | `5 ~`           | PAGE_DOWN | `6 ~`           |
| F1      | `1 P` or `11 ~` | F2        | `1 Q` or `12 ~` |
| F3      | `13 ~`          | F4        | `1 S` or `14 ~` |
| F5      | `15 ~`          | F6        | `17 ~`          |
| F7      | `18 ~`          | F8        | `19 ~`          |
| F9      | `20 ~`          | F10       | `21 ~`          |
| F11     | `23 ~`          | F12       | `24 ~`          |

#### System & Extended Function Keys

| Key       | Code    | Key          | Code    |
|-----------|---------|--------------|---------|
| CAPS_LOCK | `57358` | SCROLL_LOCK  | `57359` |
| NUM_LOCK  | `57360` | PRINT_SCREEN | `57361` |
| PAUSE     | `57362` | MENU         | `57363` |
| F13       | `57376` | F14          | `57377` |
| F15       | `57378` | F16          | `57379` |
| F17       | `57380` | F18          | `57381` |
| F19       | `57382` | F20          | `57383` |
| F21       | `57384` | F22          | `57385` |
| F23       | `57386` | F24          | `57387` |
| F25       | `57388` | F26          | `57389` |
| F27       | `57390` | F28          | `57391` |
| F29       | `57392` | F30          | `57393` |
| F31       | `57394` | F32          | `57395` |
| F33       | `57396` | F34          | `57397` |
| F35       | `57398` |              |         |

#### Keypad Keys

| Key         | Code             | Key          | Code    |
|-------------|------------------|--------------|---------|
| KP_0        | `57399`          | KP_1         | `57400` |
| KP_2        | `57401`          | KP_3         | `57402` |
| KP_4        | `57403`          | KP_5         | `57404` |
| KP_6        | `57405`          | KP_7         | `57406` |
| KP_8        | `57407`          | KP_9         | `57408` |
| KP_DECIMAL  | `57409`          | KP_DIVIDE    | `57410` |
| KP_MULTIPLY | `57411`          | KP_SUBTRACT  | `57412` |
| KP_ADD      | `57413`          | KP_ENTER     | `57414` |
| KP_EQUAL    | `57415`          | KP_SEPARATOR | `57416` |
| KP_LEFT     | `57417`          | KP_RIGHT     | `57418` |
| KP_UP       | `57419`          | KP_DOWN      | `57420` |
| KP_PAGE_UP  | `57421`          | KP_PAGE_DOWN | `57422` |
| KP_HOME     | `57423`          | KP_END       | `57424` |
| KP_INSERT   | `57425`          | KP_DELETE    | `57426` |
| KP_BEGIN    | `1 E` or `57427` |              |         |

#### Media Keys

| Key                  | Code    | Key                | Code    |
|----------------------|---------|--------------------|---------|
| MEDIA_PLAY           | `57428` | MEDIA_PAUSE        | `57429` |
| MEDIA_PLAY_PAUSE     | `57430` | MEDIA_REVERSE      | `57431` |
| MEDIA_STOP           | `57432` | MEDIA_FAST_FORWARD | `57433` |
| MEDIA_REWIND         | `57434` | MEDIA_TRACK_NEXT   | `57435` |
| MEDIA_TRACK_PREVIOUS | `57436` | MEDIA_RECORD       | `57437` |
| LOWER_VOLUME         | `57438` | RAISE_VOLUME       | `57439` |
| MUTE_VOLUME          | `57440` |                    |         |

#### Modifier Keys

| Key              | Code    | Key              | Code    |
|------------------|---------|------------------|---------|
| LEFT_SHIFT       | `57441` | RIGHT_SHIFT      | `57447` |
| LEFT_CONTROL     | `57442` | RIGHT_CONTROL    | `57448` |
| LEFT_ALT         | `57443` | RIGHT_ALT        | `57449` |
| LEFT_SUPER       | `57444` | RIGHT_SUPER      | `57450` |
| LEFT_HYPER       | `57445` | RIGHT_HYPER      | `57451` |
| LEFT_META        | `57446` | RIGHT_META       | `57452` |
| ISO_LEVEL3_SHIFT | `57453` | ISO_LEVEL5_SHIFT | `57454` |

### Raw Events

Raw events arrive directly from the terminal and are not derived. Each event carries the key code, the optional shifted and base-layout alternates, the full modifier bitfield, the event type (press / repeat / release), and the text codepoints. Modifier keys themselves report press and release.

### Derived Events

Higher-level events synthesized from the raw stream. Nearly all of them build on one piece of shared state — the pressed-set.

#### Pressed-Set

A map from key code to a record `{pressed_at, last_repeat_at, repeat_count, mods_at_press}`:

```
on event e:
  case e.type
  when press   then held[e.key] = {pressed_at: e.time, repeat_count: 0, mods_at_press: e.mods}
  when repeat  then held[e.key].last_repeat_at = e.time; held[e.key].repeat_count += 1
  when release then emit_derived(e, held[e.key]); held.delete(e.key)
```

#### Key Hold / Long Press

Two-state machine per key. On press, arm a threshold timer; a release before it fires means no long press, while the timer firing while still held emits the event. To avoid wall-clock timers, use the repeat-count variant below as the trigger.

#### Hold Duration via Repeat Counting

Uses the terminal's autorepeat as the clock; the threshold is a repeat count rather than a duration.

```
IDLE --press--> DOWN (count = 0)
DOWN --repeat--> DOWN (count += 1); if count == N then emit HoldReached
DOWN --release--> IDLE
```

#### Chords / Simultaneous Keys

The pressed-set is the state. Fire on the transition into a complete registered set, then latch to avoid re-firing as further keys or repeats arrive.

```
on press:   add key to held
            if held superset of registered chord C and not latched[C]:
              emit Chord(C); latched[C] = true
on release: remove key from held
            for each latched chord C no longer satisfied: latched[C] = false
```

#### Tap vs Hold

Per-key three-state machine. The discriminator is whether a repeat (or a duration threshold) is seen before release.

```
IDLE --press--> PENDING [arm timer T]
PENDING --release (before T, no repeat)--> IDLE [emit Tap]
PENDING --repeat OR timer T--> HOLDING [emit HoldStart]
HOLDING --release--> IDLE [emit HoldEnd]
```

#### Double-Tap / Multi-Tap

Consumes `Tap` output, not raw events. Track `{last_tap_key, last_tap_time, tap_count}`.

```
on Tap(key):
  if key == last_tap_key and (now - last_tap_time) < W:
    tap_count += 1
  else:
    tap_count = 1
  last_tap_key = key; last_tap_time = now
  emit MultiTap(key, tap_count)
```

#### Modifier-Only Gestures

A modifier tapped alone: its own press then release with no other key entering `held` between. A `pending` flag per modifier is cleared by any intervening non-modifier press.

```
on press(modifier M):    pending[M] = true
on press(any other key): clear pending for all modifiers
on release(modifier M):  if pending[M]: emit ModifierTap(M); pending[M] = false
```

#### Key Sequences / Leader Keys

A trie walked by successive presses, with a reset timeout. State is the current trie node plus a timer.

```
current = root
on press(key) (ignore pure modifier presses and repeats):
  if current has child[key]:
    current = child[key]; reset timer W
    if current is terminal: emit Sequence(current.action); current = root
  else:
    current = root.child[key] or root
on timer W: current = root
```

#### Rollover / Typing Dynamics

A rolling log rather than a state machine. Keep the last press time globally and per-key press times in `held`.

```
on press(key):
  overlap = count of keys still in held
  dd_latency = e.time - last_press_time
  last_press_time = e.time
on release(key):
  dwell = e.time - held[key].pressed_at
  emit TypingMetric(key, dwell, dd_latency, overlap)
```

#### Physical-Key Shortcut Matching

Match against `base` (base-layout code) so keyboard layout does not matter; fall back to `key` when no base alternate is present.

```
on press(e):
  target = e.base ?? e.key
  shortcut = lookup(normalize(e.mods), target)
  if shortcut: emit Shortcut(shortcut)
```

#### Shifted-Symbol Shortcut Matching

Lookup uses `shifted` when shift is active, so `ctrl+plus` matches whether the physical combo was `ctrl+shift+equal` or a dedicated `+`.

```
on press(e):
  effective = (shift in e.mods and e.shifted present) ? e.shifted : e.key
  emit Shortcut(lookup(e.mods without consumed shift, effective))
```

#### Text-vs-Key Separation

A stateless classifier. Route by whether the event carries text and whether command-class modifiers are set.

```
on event(e):
  if e.text present and no command-class mods (ctrl/super/hyper/meta):
    emit TextInput(e.text)
  else:
    emit KeyCommand(e.key, e.mods, e.type)
```

#### Synthetic Key-Press (Debounced Activation)

Collapse press / repeat / release into one logical activation for consumers that do not want the rich stream.

```
IDLE --press--> ACTIVE [emit Activate]
ACTIVE --repeat--> ACTIVE [swallow, or emit AutoRepeat]
ACTIVE --release--> IDLE [swallow]
```

### Caveats

- **Lock modifiers.** The caps_lock and num_lock bits are level state, not edges. Derive "lock toggled" from a transition in the bit, not from the key press alone; treat these two bits as state.
- **Enter / Tab / Backspace.** These retain legacy byte behavior in some sub-modes, but under report-all-keys they become full escape codes with release events. Every derived event that depends on their release relies on that flag.
- **Ordering.** Update the pressed-set and run the text-vs-key classifier before the other detectors each tick, since chords, typing dynamics, and modifier gestures all read `held`.

## Mouse

Mouse reporting uses Any-Event Tracking (1003) alongside SGR-Pixel encoding (1016).

### Mode Control

Mode 1003 selects which events are reported, while 1016 changes the coordinate encoding to pixels.

**Enable:**  
`CSI ? 1003 ; 1016 h`  

**Disable:**  
`CSI ? 1003 ; 1016 l`  

Under mode 1003, every press, release, drag, and bare motion event is reported, whether or not a button is held.

### Report Format

- Press / Drag / Motion / Scroll / Leave: `CSI < Pb ; Ppx ; Ppy M`
- Release: `CSI < Pb ; Ppx ; Ppy m`

The final `M` or `m` distinguishes a press from a release, so no button number is overloaded to mean "release".

- Coordinates are exact pixel integers relative to the window origin.
- Motion is emitted at a high frequency whenever the pointer moves.
- Leave is emitted when the pointer exits the window; the coordinates reflect the last known position and are frequently reported as `0, 0`.
- Wheel events are reported strictly as presses without matching releases; scrolling multiple lines emits consecutive per-line reports.

### Button Field

The low bits of `Pb` carry the button identity, while the high bits carry modifiers and the event class.

Button bits (low two bits):

| Value | Button                               |
|-------|--------------------------------------|
| 0     | Left                                 |
| 1     | Middle                               |
| 2     | Right                                |
| 3     | No button (motion with nothing held) |

Indicator bits:

| Bit      | Value | Meaning                               |
|----------|-------|---------------------------------------|
| `1 << 2` | 4     | Shift                                 |
| `1 << 3` | 8     | Alt                                   |
| `1 << 4` | 16    | Ctrl                                  |
| `1 << 5` | 32    | Drag (`32`/`33`/`34`) or Hover (`35`) |
| `1 << 6` | 64    | Scroll                                |
| `1 << 7` | 128   | Extra button                          |
| `1 << 8` | 256   | Leave window                          |

Scroll buttons (`64` + low bits): `64` wheel up, `65` wheel down, `66` wheel left, `67` wheel right.

Extra buttons (`128` + low bits): `128` Aux8, `129` Aux9, `130` Aux10, `131` Aux11.

Modifier bits reflect shift, alt, and ctrl states only; lock modifiers are not reported.

Common values:

| Pb  | Meaning                 |
|-----|-------------------------|
| 0   | Left press or release   |
| 1   | Middle press or release |
| 2   | Right press or release  |
| 4   | Shift + left            |
| 16  | Ctrl + left             |
| 20  | Ctrl + shift + left     |
| 32  | Left drag               |
| 33  | Middle drag             |
| 34  | Right drag              |
| 35  | Motion, no button held  |
| 48  | Ctrl + left drag        |
| 64  | Wheel up                |
| 65  | Wheel down              |
| 256 | Leave window            |

### Parsing Logic

1. Verify the sequence begins with `CSI <` and terminates with `M` or `m`.
2. Extract three `;`-separated decimal parameters: `Pb`, `Ppx`, and `Ppy`.
3. Extract the modifier bits: `4` (shift), `8` (alt), and `16` (ctrl).
4. Decode the event class from `Pb` in priority order:
   - `Pb & 256` set: emit Leave.
   - `Pb & 64` set: emit Scroll (the low two bits map to up, down, left, right).
   - `Pb & 32` set and `(Pb & 3) == 3`: emit Hover (bare pointer motion).
   - Otherwise identify the button: Aux8–11 if `Pb & 128` is set, otherwise Left / Middle / Right.
5. Finalize the action from the terminator and drag state:
   - Final byte `m`: emit Release.
   - Final byte `M` and `Pb & 32` set: emit Drag.
   - Otherwise: emit Press.

### Pixel-to-Cell Conversion

Mode 1016 reports in pixels, so the raw `Ppx, Ppy` values are not directly usable as terminal columns and rows:

```
col = Ppx / cell_width
row = Ppy / cell_height
```

Cell dimensions come from the terminal (the `TIOCGWINSZ` ioctl yields both the character grid and the pixel dimensions, or use a `CSI 16 t` size report). Deriving `cell_width` and `cell_height` as `pixel_extent / cell_count` keeps the conversion accurate across resizes and font changes.

- Keep both representations available: pixel coordinates for precise gestures (drag radius, velocity), cell coordinates for grid-aligned hit testing (widgets, text selection).
- Use integer (floor) division for the cell index; retain the pixel remainder if you need the offset within a cell.
- Recompute cell dimensions on resize (see Inband Resize Notification); a stale divisor silently skews every subsequent conversion.
- The `0, 0` fallback coordinates on Leave map to cell `0, 0`; treat them as invalid rather than a real corner hit.

### Derived Events

Composed from the raw reports (Press, Release, Drag, Hover, Scroll, Leave) by tracking state across successive reports. The terminal does not send these; the parser synthesizes them.

#### Click

A Press followed by a Release on the same button, within a small pixel radius and time window. Pixel encoding makes the radius check exact.

#### Double-Click / Triple-Click

Consecutive Clicks of the same button falling inside a time window and pixel radius. Increment a counter; reset it when either bound is exceeded.

#### Drag Lifecycle

The terminal reports each drag motion independently; bracket them into Drag Start (the first Drag following a Press), Drag Move (the intermediate Drag reports), and Drag End / Drop (the Release that terminates the sequence).

#### Enter

The terminal only reports Leave. Infer Enter when a motion or hover report arrives after a prior Leave, or as the first report seen with no preceding Leave.

#### Hover Dwell

Detect when motion stops for a threshold duration at a position, or when the pointer settles over a region (useful for tooltips). Emit Hover End when motion resumes.

#### Motion Delta / Velocity

Subtract successive `Ppx, Ppy` pairs to obtain movement vectors, speed, and direction. Pixel resolution yields smooth, sub-cell values.

#### Scroll Accumulation / Momentum

Multi-line scrolls arrive as consecutive per-line reports. Coalesce them into a single gesture with a magnitude, or compute scroll velocity from their arrival timing.

#### Gesture Recognition

Swipes and flicks built on the drag lifecycle plus velocity thresholds; drag direction is derived from the start-to-end vector.

#### Multi-Button Chord

Track which buttons are currently held to detect simultaneous presses.

#### Long Press

A Press with no matching Release after a threshold duration.

### Caveats

- Any derived event that depends on the exit position (edge-swipe detection, for example) cannot trust Leave coordinates, since they are frequently reported as `0, 0`. Fall back to the last valid motion report for position.

## Terminal Notifications

### Inband Resize Notification

**Enable / Disable:**  
`CSI ? 2048 h` / `CSI ? 2048 l`  

**Report:**  
`CSI 48 ; h ; w ; h_px ; w_px t`  

### Focus Tracking

**Enable / Disable:**  
`CSI ? 1004 h` / `CSI ? 1004 l`  

**Report:**  
`CSI I` (focus gained) / `CSI O` (focus lost)  

### Visibility Reports

**Enable / Disable:**  
`CSI ? 2033 h` / `CSI ? 2033 l`  

**Query:**  
`CSI ? 998 n`  

**Report:**  
`CSI ? 999 ; 1 n` (restored) / `CSI ? 999 ; 2 n` (minimized)  

### Color Scheme Notification

**Enable / Disable:**  
`CSI ? 2031 h` / `CSI ? 2031 l`  

**Query:**  
`CSI ? 996 n`  

**Report:**  
`CSI ? 997 ; 1 n` (dark mode) / `CSI ? 997 ; 2 n` (light mode)  
