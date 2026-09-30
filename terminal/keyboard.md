# Keyboard Handling (Kitty Protocol, All Enhancements)

## Mode Control

This document assumes the terminal has all five progressive-enhancement flags enabled:

`CSI = 31 u`
  Enable disambiguate (1) | report event types (2) | report alternate keys (4) | report all keys (8) | report associated text (16).

With this set, every key event — including plain text keys, modifier keys, and Enter/Tab/Backspace — is delivered as a `CSI u` escape code carrying full key, modifier, event-type, and text information.

Push the current flags before enabling and pop on exit so the prior mode is restored:

`CSI > 31 u`
  Push desired flags.

`CSI < u`
  Pop back to the previous mode.

## Report Format

The central escape code is:

`CSI unicode-key ; modifiers : event-type ; text-codepoints u`

Fields are separated by `;`, sub-fields by `:`. Only the key code is mandatory. Parsed into fields:

- `key` — the unshifted Unicode codepoint of the key, or a functional-key number.
- `shifted` — optional first alternate: the shifted codepoint (present only when shift is active).
- `base` — optional second alternate: the codepoint of the same physical key in the PC-101 layout.
- `mods` — modifier bitfield, encoded as `1 + actual bits`.
- `type` — event type sub-field: `1` press (default), `2` repeat, `3` release.
- `text` — associated text as one or more codepoints, colon-separated.

### Modifier Bits

```
shift     1
alt       2
ctrl      4
super     8
hyper     16
meta      32
caps_lock 64
num_lock  128
```

The wire value is `1 + OR of the active bits`. A missing modifier field means no modifiers (value `1`).

## Raw Events

These arrive directly and are not derived. Per event you receive: the key code, optional shifted and base-layout alternates, the full modifier bitfield, the event type (press / repeat / release), and text codepoints. Modifier keys themselves report press and release.

## Shared Foundation: The Pressed-Set

Nearly every derived event builds on one piece of state — the set of currently-held keys. Maintain it as a map from key code to a record `{pressed_at, last_repeat_at, repeat_count, mods_at_press}`.

```
on event e:
  case e.type
  when press   then held[e.key] = {pressed_at: e.time, repeat_count: 0, mods_at_press: e.mods}
  when repeat  then held[e.key].last_repeat_at = e.time; held[e.key].repeat_count += 1
  when release then emit_derived(e, held[e.key]); held.delete(e.key)
```

Update the pressed-set and run the text-vs-key classifier first each tick, since chords, typing dynamics, and modifier gestures all read `held`.

## Derived Events

### Key Hold / Long Press

Two-state machine per key. On press, arm a threshold timer; a release before it means no long press, the timer firing while still held emits the event.

```
IDLE --press--> DOWN [arm timer T]
DOWN --release (t < T)--> IDLE
DOWN --timer fires (still held)--> HELD [emit LongPress]
HELD --release--> IDLE [emit LongPressEnd]
```

To avoid wall-clock timers, use the repeat-count variant below as the trigger.

### Hold Duration via Repeat Counting

Uses the terminal's autorepeat as the clock; the threshold is a repeat count rather than a duration.

```
IDLE --press--> DOWN (count = 0)
DOWN --repeat--> DOWN (count += 1); if count == N then emit HoldReached
DOWN --release--> IDLE
```

Repeat rate is a user/OS setting, so the count is a coarse proxy for time — good for gating "is this held," not for precise duration.

### Chords / Simultaneous Keys

The pressed-set is the state. Fire on the transition into a complete registered set, then latch to avoid re-firing as further keys or repeats arrive.

```
on press:   add key to held
            if held superset of registered chord C and not latched[C]:
              emit Chord(C); latched[C] = true
on release: remove key from held
            for each latched chord C no longer satisfied: latched[C] = false
```

Because all text keys and modifier keys report release under these flags, true N-key combinations (the gaming WASD case) are detectable.

### Tap vs Hold

Per-key three-state. The discriminator is whether a repeat (or a duration threshold) is seen before release.

```
IDLE --press--> PENDING [arm timer T]
PENDING --release (before T, no repeat)--> IDLE [emit Tap]
PENDING --repeat OR timer T--> HOLDING [emit HoldStart]
HOLDING --release--> IDLE [emit HoldEnd]
```

Promote on whichever of repeat or timer comes first for responsiveness.

### Double-Tap / Multi-Tap

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

For "exactly N," defer emission and arm a timer `W` after each tap, emitting the final count when it lapses.

### Modifier-Only Gestures

A modifier tapped alone: its own press then release with no other key entering `held` between. A `clean` flag per modifier is cleared by any intervening non-modifier press.

```
on press(modifier M):       pending[M] = true
on press(any other key):    clear pending for all modifiers   # they were part of a combo
on release(modifier M):     if pending[M]: emit ModifierTap(M); pending[M] = false
```

This distinguishes a tapped Shift from Shift held while typing.

### Key Sequences / Leader Keys

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

Disambiguation makes this trustworthy: `ctrl+i` keys a different edge than `Tab`, `ctrl+m` a different edge than `Enter`.

### Rollover / Typing Dynamics

A rolling log rather than a state machine. Keep the last press time globally and per-key press times in `held`.

```
on press(key):
  overlap = count of keys still in held        # N-key rollover
  dd_latency = e.time - last_press_time         # keydown-to-keydown
  last_press_time = e.time
on release(key):
  dwell = e.time - held[key].pressed_at         # key-down duration
  emit TypingMetric(key, dwell, dd_latency, overlap)
```

Derived signals: dwell (press to release), flight/DD latency (press to next press), and overlap (size of `held` when a new press lands).

### Physical-Key Shortcut Matching

Stateless per-event transform. Match against `base` (base-layout code) so keyboard layout does not matter; fall back to `key` when no base alternate is present.

```
on press(e):
  target = e.base ?? e.key
  shortcut = lookup(normalize(e.mods), target)
  if shortcut: emit Shortcut(shortcut)
```

Resolves cases like `ctrl+c` on a Cyrillic layout.

### Shifted-Symbol Shortcut Matching

Same shape, but the lookup uses `shifted` when shift is active, so `ctrl+plus` matches whether the physical combo was `ctrl+shift+equal` or a dedicated `+`.

```
on press(e):
  effective = (shift in e.mods and e.shifted present) ? e.shifted : e.key
  emit Shortcut(lookup(e.mods without consumed shift, effective))
```

### Text-vs-Key Separation

A stateless classifier. Route by whether the event carries text and whether command-class modifiers are set.

```
on event(e):
  if e.text present and no command-class mods (ctrl/super/hyper/meta):
    emit TextInput(e.text)
  else:
    emit KeyCommand(e.key, e.mods, e.type)
```

Under associated-text reporting a single event can feed both channels — record `å` as text while still logging that alt was involved.

### Synthetic Key-Press (Debounced Activation)

The reductive case: collapse press / repeat / release into one logical activation for consumers that do not want the rich stream.

```
IDLE --press--> ACTIVE [emit Activate]
ACTIVE --repeat--> ACTIVE [swallow, or emit AutoRepeat]
ACTIVE --release--> IDLE [swallow]
```

Emit `AutoRepeat` on repeat if the consumer wants held-key acceleration but no release noise.

## Caveats

- **Lock modifiers.** The caps_lock and num_lock bits are level state, not edges. Derive "lock toggled" from a transition in the bit, not from the key press alone. Any model reading `mods` should treat these two bits as state.
- **Enter / Tab / Backspace.** These retain legacy byte behavior in some sub-modes, but under report-all-keys they become full escape codes with release events. Every derived event that depends on their release relies on that flag, which is set here.
- **Ordering.** Run the pressed-set update and the text-vs-key classifier before the other detectors each tick, since chords, dynamics, and modifier gestures read `held`.