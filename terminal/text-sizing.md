# Text Sizing

A combined reference for rendering text at different sizes in the terminal: integer and fractional scaling, explicit cell widths that solve the client/terminal width-agreement problem, wrapping and overwriting rules, support detection, and the normative algorithm for splitting text into cells. Fully backward compatible — terminals implementing it behave unchanged for applications that do not use it.

## Notation

- `OSC` is the Operating System Command introducer (`ESC ]`); the terminator is `BEL` (`0x07`) or `ESC \`.
- *metadata* is a colon-separated list of `key=value` pairs; spaces in the wire formats below are for readability only.
- The payload is plain text in safe UTF-8 (valid RFC 3629 UTF-8, no C0/C1 control characters), at most 4096 bytes; longer strings are split across multiple escape codes.
- Sizes are relative to the base font size: if the base font changes, scaled sizes change with it (`s=2` at 11 pt ≈ 22 pt, approximately — terminals may adjust slightly, as fonts do not scale linearly).

## Wire Format

`OSC _text_size_code ; metadata ; text terminator`

```
printf "\e]_text_size_code;s=2;Double sized text\a\n\n"
printf "\e]_text_size_code;s=3;Triple sized text\a\n\n\n"
printf "\e]_text_size_code;n=1:d=2;Half sized text\a\n"
printf "\e]_text_size_code;n=1:d=2:w=1;Ha\a\e]_text_size_code;n=1:d=2:w=1;lf\a\n"
```

The last example pairs fractional scaling with `w=1` so each half-height pair of characters occupies exactly one cell — the same mechanism that lets a client dictate rendered width.

## Metadata Keys

| Key | Value           | Default | Meaning |
|-----|-----------------|---------|---------|
| `s` | integer 1–7     | `1`     | Overall scale; text renders in a block of `s * w` by `s` cells |
| `w` | integer 0–7     | `0`     | Width in cells for the text. `0` = the terminal splits text into scaled cells as it would for normal text |
| `n` | integer 0–15    | `0`     | Numerator of the fractional scale |
| `d` | integer 0–15    | `0`     | Denominator of the fractional scale; when non-zero must be `> n` |
| `v` | integer 0–2     | `0`     | Vertical alignment of fractionally scaled text (`n < d`): `0` top, `1` bottom, `2` centered |
| `h` | integer 0–2     | `0`     | Horizontal alignment of fractionally scaled text: `0` left, `1` right, `2` centered |

## How It Works

The client tells the terminal to render text in a multi-cell block, and the terminal adjusts the actual font size to fit that space.

- The block is `s * w` cells wide and `s` cells high. With `w=0` (the default), the terminal splits the text as it normally would, but each character occupies an `s` by `s` block — `abc` at `s=2`:

```
│a░│b░│c░│
│░░│░░│░░│
```

The terminal multiplies the font size by `s`, rendering at twice the base size.

- With non-zero `w`, **all** text in the escape code must render inside `s * w` cells. If it does not fit, the terminal may truncate or downsize the font — use `w` wisely. Send long strings as one escape code per fitting chunk; e.g. `cool-🐈` becomes `w=1;c w=1;o w=1;o w=1;l w=1;- w=2:🐈` (metadata/payload only). Since terminals get ASCII widths right, in practice use `w=0` for ASCII runs — `cool- w=2:🐈` — and reserve explicit `w` for non-ASCII characters and fractional scaling.

## Fractional Scaling

The `s` parameter alone gives only 7 sizes; `n`/`d` apply a fractional scale *on top of* `s`, adjusting the rendered font size **without changing the number of cells** the text occupies:

- Blank half-line above and below normal text: `s=2:n=1:d=2:v=2`
- Superscripts: `n=1:d=2`
- Subscripts: `n=1:d=2:v=1`

`v` and `h` position the scaled render area inside the full `s * w` by `s` block — this is area alignment, not text alignment, and applies only when `n < d`.

To fit more than one character per cell, split the string into pairs and send one code per pair:

```
OSC _text_size_code ; n=1:d=2:w=1 ; ab terminator
... repeat for each pair of characters
```

## The Character Width Problem

Terminal UIs break catastrophically when the client and the terminal disagree on how many cells a string occupies — a coordination problem: both sides would need the same character database and the same grapheme-segmentation algorithm, but Unicode revises widths nearly every year and correct segmentation is complex. This protocol removes the coordination problem: the client segments text with whatever Unicode database it has, then transmits each piece with explicit `w` values so the terminal renders exactly the expected number of cells.

> A terminal may implement only the width part of this protocol and ignore scaling — the escape code works with `w` alone (`s` defaults to `1`). Clients query support as described below.

## Wrapping and Overwriting

- If the block (`s * w` by `s`) exceeds the screen in either dimension, the terminal must discard the character — shrinking the window can therefore lose multicell characters.
- With DECAWM (wrap) enabled and insufficient room on the line, the cursor moves to the start of the next line and the character is drawn there.
- With DECAWM disabled, the cursor moves back as far as needed to fit `s * w` cells, then the character is drawn per the overwriting rules.

When new text (normal or sized) would overwrite an existing multicell character, apply these rules in decreasing precedence:

1. A combining character is added to the existing multicell character.
2. Overwriting the multicell character's top-left cell erases the entire character.
3. Overwriting any cell of its topmost row replaces the entire character with spaces (backward compatibility with wide-character overwriting).
4. Overwriting cells of a later row moves the cursor past the character's cells on that row before writing — independent of DECAWM, for implementation simplicity.

Rule 4's skipping can span many cells; it exists so wrapping keeps working around multi-line multicell characters.

## Detecting Support

Use the cursor position report (CPR). Send `CR`, `CPR`, `ESC ]_text_size_code;w=2; SPACE BEL` (draws a space in two cells), `CPR`, then `ESC ]_text_size_code;s=2; SPACE BEL` (draws a space in a 2x2 block), `CPR`. Compare the three CPR responses:

- All three identical → the protocol is not supported at all.
- The second response moved by two cells → the width part is supported.
- The third response moved by another two cells → the scale part is supported.

## Interaction with Other Terminal Controls

Multicell characters do not change the grid nature of the terminal; legacy controls assume one character per cell, so their interaction must be specified.

### Cursor Movement

Movement commands are unaffected — they move in single-cell increments, so the cursor can sit on any cell inside a multicell character. Creating a multicell character moves the cursor `s * w` cells right in the same row. Terminals should display an enlarged cursor over the whole block when the logical cursor is on any of its cells (block cursors cover all cells, bar cursors span the first column, and so on).

### Editing Controls

- **Insert characters (`CSI @`, ICH)** — erases any multi-line character intersecting line `y` at `x` and beyond, and any single-line multicell character split by the inserted range `x … x + n - 1`.
- **Delete characters (`CSI P`, DCH)** — same erasure rules as ICH, for the left shift.
- **Erase characters (`CSI X`, ECH)** — erases any multicell character intersecting the `n` cells starting at `x`.
- **Erase display (`CSI J`, ED)** — erases any multicell character intersecting the erased region; with mode `22`, screen contents (including multicell characters) are first copied into history.
- **Erase in line (`CSI K`, EL)** — like ECH: any multicell character intersecting the erased cells is erased.
- **Insert lines (`CSI L`, IL)** — erases multi-line characters split at line `y` (a split = a second-or-later row of the character on line `y`), and those split at the bottom of the screen after `n` lines are pushed out (any row except the last landing on the final line).
- **Delete lines (`CSI M`, DL)** — erases any multicell character intersecting the deleted lines.

## Splitting Text into Cells

The normative algorithm a terminal must use to assign text to cells (one cell = one width unit of the grid). It is based on Unicode's grapheme cluster segmentation (UAX #29), which alone is insufficient for terminals, and is currently defined against Unicode 16.

Decoding: bytes are decoded as UTF-8 into Unicode scalar values; each *maximal subpart of an ill-formed subsequence* is replaced with `U+FFFD`.

Per decoded code point, in order:

1. **ASCII control codes** (below `U+0020`, plus `U+007F` DEL) are handled as controls; `U+0000` NUL is discarded.
2. **Invalid code points** are discarded: categories `Cc`/`Cs`, the range `[0xFDD0, 0xFDEF]`, and the noncharacters `[0xFFFE, 0x10FFFF, 0x10000]` and `[0xFFFF, 0x10FFFF, 0x10000]`.
3. Determine the *previous cell*: the cell at `x-1` on the same line, or the last cell of the previous line when no line break separates the lines.
4. Compute the code point's width: 0, 1, or 2 cells (see the width classes below).
5. No previous cell and zero width → discard the code point.
6. Otherwise, apply UAX #29 rule C1-1 to decide whether a grapheme boundary lies between the previous cell and this code point.
7. No boundary → add the code point to the previous cell (see Variation Selectors below). Exception: a code point with `Grapheme_Cluster_Break=SpacingMark` and non-zero width widens the previous cell to two cells, provided that cell is a single unscaled cell whose width was not set explicitly via `w` — this affects only `U+0E33` (Thai Sara Am) and `U+0EB3` (Lao Am).
8. Boundary but zero width → add to the previous cell anyway.
9. Boundary and non-zero width → place in the current cell and advance the cursor right by 1 or 2 cells.

### Width Classes

Applied in decreasing priority. Notation: `[start, stop, step]` is an integer range, step defaulting to 1.

1. **Regional indicators** — the 26 code points starting at `0x1F1E6`: width 2.
2. **Doublewidth** — code points marked `W` or `F` in `EastAsianWidth.txt`: width 2. Additionally width 2 *unless* marked `A` there: `[0x3400, 0x4DBF]`, `[0x4E00, 0x9FFF]`, `[0xF900, 0xFAFF]`, `[0x20000, 0x2FFFD]`, `[0x30000, 0x3FFFD]`.
3. **Wide emoji** — from `emoji-sequences.txt`: all `Basic_Emoji` have width 2 unless followed by `FE0F` in the file; the leading code points of every `RGI_Emoji_Modifier_Sequence` and `RGI_Emoji_Tag_Sequence` have width 2; all code points of `RGI_Emoji_Flag_Sequence` have width 2.
4. **Marks** — width 0: code points whose category starts with `M` or `S`, category `Cf`, and the modifier code points of `RGI_Emoji_Modifier_Sequence`.
5. Everything else: width 1.

### Variation Selectors

`U+FE0E` and `U+FE0F` change the *previous* code point's presentation (text vs emoji) and thus its width, so they need special handling when added to a cell:

- **`U+FE0E` (VS15)** — shrinks the previous cell to width 1 when it is two cells wide, its width was not set via `w`, and its last code point is a `Basic_Emoji` *not* followed by `FE0F` in `emoji-sequences.txt`.
- **`U+FE0F` (VS16)** — grows the previous cell to width 2 when it is a single unscaled cell, its width was not set via `w`, and its last code point is a `Basic_Emoji` that *is* followed by `FE0F` in the file.

A width set explicitly with `w` always wins — such cells are never resized by variation selectors or spacing marks.

VS15 is problematic for terminals: string width becomes screen-width-dependent. A wide emoji received with one cell left wraps to the next line; a subsequent VS15 narrows it to one cell but it is *not* moved back. Applications should detect VS15 and use explicit `w` widths, or segment into graphemes and emit them so each affects exactly its `wcswidth` cells — moving the cursor back, writing the grapheme, and repairing with insert-cell:

```python
class Grapheme:
    text: str
    width: int

def output_one_line(iterator_over_graphemes):
    ' Output graphemes so that they affect exactly wcswidth cells only (works for >= 2 graphemes) '
    graphemes = tuple(iterator_over_graphemes)
    if not graphemes:
        return
    yield graphemes[0].text
    for i in range(1, len(graphemes)):
        g = graphemes[i]
        if g is graphemes[-1]:
            prev_g = graphemes[i-1]
            yield f'\x1b[{prev_g.width}D'  # move cursor back
            yield g.text
            yield f'\x1b[{g.width}D'  # move cursor back
            yield f'\x1b[{prev_g.width}@'  # insert cells
            yield prev_g.text
            yield f'\x1b[{g.width}C'  # move cursor forward
```

Splitting long text into screen-width lines with `wcswidth()` and writing each line via this function renders robustly in the presence of VS15.
