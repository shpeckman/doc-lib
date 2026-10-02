# Color Control

A combined reference for terminal color management: saving and restoring the complete color state on a stack, and setting or querying individual colors through a single string-keyed OSC protocol with a rigorously specified color encoding.

## Notation

- `OSC` is the Operating System Command introducer (`ESC ]`); `ST` is the string terminator (`BEL` or `ESC \`).
- Spaces inside the OSC 21 wire formats below are for readability only and are not part of the protocol.

## Saving and Restoring Colors

Full-screen applications with their own color themes often set the default foreground, background, selection and cursor colors, and the ANSI color table — which would otherwise destroy any colors the user had set with escape codes. A stack-based pair of escape codes saves and restores the complete state:

**Push:**  
`OSC 30001 ST`  

**Pop:**  
`OSC 30101 ST`  

Each stack entry covers the default foreground and background, selection background and foreground, cursor color, and all 256 entries of the ANSI color table.

> xterm implements the same facility under different, incompatible escape codes (`XTPUSHCOLORS`, `XTPOPCOLORS`, `XTREPORTCOLORS`). In the interest of interoperability, kitty supports xterm's codes as well, and both variants save and restore the entire ANSI color table.

## Setting and Querying Colors

The legacy xterm protocol spreads colors across OSC 4–6, 10–19 and 104–119, requiring two new numbers for every added color, with no representation for colors that have no fixed value (a reverse-video selection, for example) and no specified report format. OSC 21 replaces all of these with a single future-proof form using string keys:

**Wire format:**  
`OSC 21 ; key=value ; key=value ; ... ST`  

`key` is a number `0`–`255` addressing an entry of the terminal's ANSI color table, or one of the special keys below:

| Key                                | Meaning                                                                                                 | Dynamic value                                 |
|------------------------------------|---------------------------------------------------------------------------------------------------------|-----------------------------------------------|
| `foreground`                       | The default foreground text color                                                                       | Not applicable                                |
| `background`                       | The default background text color                                                                       | Not applicable                                |
| `selection_background`             | The background color of selections                                                                      | Reverse video                                 |
| `selection_foreground`             | The foreground color of selections                                                                      | Reverse video                                 |
| `cursor`                           | The color of the text cursor                                                                            | Foreground color                              |
| `cursor_text`                      | The color of text under the cursor                                                                      | Background color                              |
| `visual_bell`                      | The color of a visual bell                                                                              | Automatic, based on current screen colors     |
| `transparent_background_color1..7` | A background color rendered with the specified opacity in cells that have the specified background color | Unset                                         |

The *dynamic* column shows the effect of setting that color to dynamic (an empty value); it is advisory only — terminals may not support dynamic colors, or may define other effects. ANSI color-table entries cannot be set to dynamic. For `transparent_background_color1..7`, an opacity value less than zero means the terminal's default background opacity is used.

### Querying

Send the escape code with each `value` set to `?` (the byte `0x3f`); the terminal responds with the same code, each `?` replaced by the encoded color value:

**Request:**  
`OSC 21 ; foreground=? ; cursor=? ST`  

**Response:**  
`OSC 21 ; foreground=rgb:ff/00/00 ; cursor= ST`  

- A color with no defined value (reverse video, a gradient, or similar) replies with an *empty* value — the key and `=` only. Above, the foreground is red and the cursor color is undefined (the cursor typically takes the color of the text under it, and that text the color of the background).

Unknown keys are reported as `unknown` fields whose value is the base64-encoded (RFC 4648, *without* padding) name of the unknown key — one per unknown key, in the order received. Encoding the name rather than echoing it verbatim prevents abuse of the escape code to make the terminal emit arbitrary text:

**Request:**  
`OSC 21 ; foreground=? ; nonsense=? ST`  

**Response:**  
`OSC 21 ; foreground=rgb:ff/00/00 ; unknown=bm9uc2Vuc2U ST`  

(`bm9uc2Vuc2U` is the base64 encoding of `nonsense`; omitting padding keeps the response unambiguously parseable.)

### Setting

Send the escape code with each `value` set to an encoded color, or to the empty value for dynamic:

**Example:**  
`OSC 21 ; foreground=green ; cursor= ; background ST`  

- `key=value` sets the color.
- `key=` (empty value) selects the dynamic effect.
- `key` alone — no `=`, no value — resets the color to its default, the value it would have if it was never set.

Above, the foreground becomes green, the cursor color becomes dynamic (usually meaning the cursor takes the color of the text under it), and the background resets to its default value.

Set and query can be combined into a single escape code to confirm a change in one round trip:

`OSC 21 ; foreground=white ; foreground=? ST`

The terminal changes the foreground color and replies with the new value.

## Color Value Encoding

A rigorously specified subset of the xterm color encoding, kept for compatibility.

- `rgb:<red>/<green>/<blue>` — each component is one to four hexadecimal digits (case-insensitive): `h` is the value scaled in 4 bits, `hh` in 8 bits, `hhh` in 12 bits, and `hhhh` in 16 bits.
- `#<hex>` — `#RGB` (4 bits each), `#RRGGBB` (8 bits), `#RRRGGGBBB` (12 bits), `#RRRRGGGGBBBB` (16 bits). When fewer than 16 bits are specified, the digits are the *most significant* bits of the value rather than scaled: `#3a7` is the same as `#3000a0007000`.
- `rgbi:<red>/<green>/<blue>` — components are floating-point values between 0.0 and 1.0 inclusive: an optional sign, digits possibly containing a decimal point, and an optional `e`/`E` exponent. Values outside the 0–1 range are clipped.
- **Alpha** — append `@<alpha>` to any form, where alpha is a float between zero and one with the same syntax as `rgbi` components: `red@0.5`, `rgb:ff0000@0.1`, `#ff0000@0.3`. The default is `1.0`; out-of-range values are clipped, and negative values may have special context-dependent meaning.
- **Named colors** — standard color names are accepted case-insensitively, each corresponding to a defined RGB value.
