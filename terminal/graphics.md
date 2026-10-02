# Graphics

A combined reference for rendering arbitrary pixel (raster) graphics in the terminal: transmitting pixel data over several media, displaying it through placements with full layout control, Unicode-placeholder and relative positioning, deletion, animation, and storage limits. All commands share a single APC escape-code form.

## Notation

- Every graphics command is an *Application Programming Command* (APC): `ESC _G <control data> ; <payload> ESC \`. Most terminals ignore APC codes, so the form is safe to emit.
- *control data* is a comma-separated list of `key=value` pairs; leading or trailing commas are undefined behavior — implementations may ignore them or reject the code entirely.
- *payload* is arbitrary binary data, base64 (RFC 4648) encoded to avoid confusing legacy terminals; its meaning depends on the control data.
- All integers are 32-bit.

## Design Goals

- Terminals are not required to understand image formats.
- Graphics can be drawn at individual pixel positions.
- Graphics integrate with text: drawable below *and* above it, alpha-blended, and scrolling with it automatically.
- Clients running on the same machine as the terminal get optimized transmission paths.

## Getting the Window Size

The client needs the window size in pixels and the grid dimensions; cell size is the pixel extent divided by the cell count.

- The `TIOCGWINSZ` ioctl yields rows, columns, and pixel width/height in one call. (Some terminals return `0` for the pixel values.)
- `CSI 14 t` — the terminal replies `CSI 4 ; height ; width t` with the window size in pixels. Widely supported.
- `CSI 16 t` — the terminal replies with the pixel dimensions of a single cell. More precise, but less widely supported.

## Transferring Pixel Data

The terminal understands three data formats, selected with the `f` key:

| `f`    | Format                        |
|--------|-------------------------------|
| `32`   | 32-bit RGBA (default)         |
| `24`   | 24-bit RGB                    |
| `100`  | PNG                           |

### RGB and RGBA Data

Pixel data is stored directly as 3 or 4 bytes per pixel, in the **sRGB color space**. The image dimensions **must** be sent via the `s` (width) and `v` (height) keys:

`ESC _Gf=24,s=10,v=20;<payload> ESC \`

Here the payload is exactly `3 * 10 * 20 = 600` bytes.

### PNG Data

Any PNG image can be transmitted directly with `f=100`; the dimensions are read from the PNG data itself:

`ESC _Gf=100;<payload> ESC \`

If PNG is combined with compression, the `S` key must carry the size of the PNG data.

### Compression

`o=z` selects RFC 1950 (zlib/deflate) compression — the only supported scheme. Compression applies to the pixel data *before* base64 encoding, works with any format, and the terminal decompresses before interpreting:

`ESC _Gf=24,s=10,v=20,o=z;<payload> ESC \`

### Transmission Media

The `t` key selects the medium (default `d`):

| `t`  | Medium                                                                                                                                                                                                                              |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `d`  | Direct — the data is in the escape code itself                                                                                                                                                                                       |
| `f`  | A simple file (regular files only — no pipes, devices, etc.)                                                                                                                                                                         |
| `t`  | A temporary file, deleted by the terminal after reading. For security, only delete when the file is in a known temporary directory (`/tmp`, `/dev/shm`, `$TMPDIR`, platform temp dirs) and its full path contains `tty-graphics-protocol` |
| `s`  | A shared memory object (POSIX `shm_open` / Windows named shared memory). On POSIX the name must start with `/`, contain no other `/`, and fit the OS name limit. The terminal reads the data, then unlinks and closes (POSIX) or just closes (Windows) |

File-access security rules:

- The terminal must follow symlinks, failing with an error on loops or too many indirections.
- Paths come from potentially untrusted sources: the terminal must refuse device/socket/other special files — only regular files — and may refuse sensitive locations (`/proc`, `/sys`, `/dev`, …). Checks happen on the path *before* opening, since merely opening a file can have side effects.
- The client may be remote or sandboxed: all read failures — missing, unreadable, not a regular file, sensitive location, smaller than claimed — must produce a single identical error response (kitty answers `EBADF:Failed to read image file` and logs the real reason locally).

### Local Client

```
ESC _Gf=100,t=f;<encoded /path/to/file.png> ESC \
ESC _Gs=10,v=2,t=s,o=z;<encoded /some-shared-memory-name> ESC \
ESC _Gs=10,v=2,t=s,S=80,O=10;<encoded /some-shared-memory-name> ESC \
```

The `S` (size) and `O` (offset) keys restrict reading to a part of the file — the third example reads 80 bytes starting at offset 10.

### Remote Client (Chunked Transfer)

Remote clients send data directly (`t=d`), chunked, since escape codes have limited length:

- Base64-encode first, then split into chunks of at most 4096 bytes; every chunk except the last must be a multiple of 4 bytes.
- The `m` key is `1` for all chunks except the last, where it is `0`:

```
ESC _Gs=100,v=30,m=1;<first chunk> ESC \
ESC _Gm=1;<second chunk> ESC \
ESC _Gm=0;<last chunk> ESC \
```

- Only the first chunk carries the full control data; subsequent chunks **must** carry only `m` and optionally `q` (and `a=f` when sending animation frames).
- The client must finish one image's chunks before sending any other graphics codes; the image is displayed at the cursor position as of the *final* chunk; the terminal must not display anything until the sequence is complete and validated.

### Querying Support and Media

Send an image id with the `i` key (any positive integer up to 4294967295 — never zero) and the terminal replies after attempting to load:

**Request:**  
`ESC _Gi=31,s=10,v=2,t=s;<encoded /some-shared-memory-name> ESC \`  

**Response:**  
`ESC _Gi=31;OK ESC \`  or  `ESC _Gi=31;<error message> ESC \`  

The message is ASCII, printable characters and spaces only. With the *query action* (`a=q`) the terminal performs the same load check but neither stores the image nor replaces an existing image with the same id.

To detect protocol support, send a query action followed by a primary device attributes request:

`ESC _Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA ESC \` `ESC [c`

A response to the graphics query means the protocol is supported; a device-attributes response with no graphics response means it is not. Supporting terminals must therefore answer query actions immediately, without processing other input first.

## Displaying Images

Each transmission of an image can be shown any number of times, in different locations and with different source rectangles; each such display is a *placement*.

- `a=T` — transmit and display in one step.
- `a=p,i=10` — display a previously transmitted image at the current cursor position.
- When an image id is given, the terminal acknowledges the placement:

```
ESC _Gi=<id>;OK ESC \                         image found
ESC _Gi=<id>;ENOENT:<detailed error> ESC \    image not found (re-transmit needed)
```

- The `p` key (1–4294967295) assigns a placement id; the pair *(image id, placement id)* uniquely identifies a placement, and the ack becomes `ESC _Gi=<image id>,p=<placement id>;OK ESC \`.
- A placement id given for an image without an id (`i=0`) is ignored; multiple images with `i=0, p=0` can coexist. Omitting `p` (or `p=0`) across several `a=p` commands with the same non-zero image id creates multiple placements.
- Sending a second placement with an existing *(image id, placement id)* pair replaces the first — usable for flicker-free moves and resizes.

> Re-transmitting image data for an existing id deletes the old image and all its placements; the new data replaces the old but is not displayed until a new placement is created. This avoids divergent behavior when unrelated programs reuse ids.

### Controlling Layout

- The image renders from the upper-left corner of the current cursor cell; `X` and `Y` add a pixel offset within that cell (must be smaller than the cell size).
- `x, y, w, h` select a source rectangle in pixels (top-left corner, width, height); the displayed area is its intersection with the source image. By default the whole image is shown, truncated at the right screen edge.
- `c, r` set the target rectangle in columns/rows; the image is scaled to fit. With only one of the two, the other is computed from the aspect ratio (no distortion); with both, the image is letterboxed/pillarboxed. A start offset given via `X,Y` is not added to `c,r`.
- `z` sets the z-index; overlapping semi-transparent images are blended. Negative values draw *under* the text (text over images); values below `INT32_MIN/2` (-1,073,741,824) additionally draw under cells with non-default backgrounds. Ties on z-index are broken by image id (lower id = lower z); identical z and id is undefined.
- After placement the cursor moves right by the placement's columns and down by its rows; if that leaves the screen or scroll area, the final position is implementation-defined. `C=1` (cursor movement policy) suppresses the movement entirely.

### Unicode Placeholders

The character `U+10EEEE` acts as a text-level placeholder for an image, letting images live inside host applications that support Unicode, colors, and escape-code passthrough (tmux, vim, …) but know nothing of the graphics protocol.

1. Transmit the image normally, in quiet mode (`q=2`), without creating a placement.
2. Create a *virtual placement* with `U=1` and the target extent:  
   `ESC _Ga=p,U=1,i=<image_id>,c=<columns>,r=<rows> ESC \`  
   (or combine transmission and virtual placement in one `a=T` code). The image is fit into the rectangle, aspect ratio preserved.
3. Display it by printing placeholder cells as ordinary text: the image id goes in the **foreground color**, the row and column in **combining diacritics** (from the protocol's row/column diacritic table — `U+0305` = 0, `U+030D` = 1, `U+030E` = 2, …).

```
printf "\e[38;5;42m\U10EEEE\U0305\U0305\U10EEEE\U0305\U030D\e[39m\n"
printf "\e[38;5;42m\U10EEEE\U030D\U0305\U10EEEE\U030D\U030D\e[39m\n"
```

This prints a 2x2 placeholder for image id `42` (cells `(0,0) (0,1) / (1,0) (1,1)`), displaying the image in a 2x2 grid. Ideally the number of printed cells matches the virtual placement; on mismatch only part of the image shows.

- Foreground color alone limits ids to 8 bits (256-color) or 24 bits (true color). Since ids are a global namespace, a **third diacritic** can carry the most significant byte of the id (e.g. id `33554474 = 42 + (2 << 24)` uses diacritic `U+030E` for the `2`).
- The **underline color** carries the placement id (omitted/zero: the terminal picks any virtual placement of the image). The **background color** shows through transparent pixels. Other attributes are reserved.
- Diacritics may be omitted; missing values are inherited from the placeholder cell to the left, applied left-to-right:
  - No diacritics, same foreground and underline colors → same row, column + 1, same most-significant id byte.
  - Only the row diacritic, same row and colors → column + 1, same most-significant byte.
  - Only row and column diacritics, same row, colors, and column one less → same most-significant byte.
  
  This allows specifying only the row diacritic of the first column. It fails under horizontal scrolling or overlapping images; terminals may apply other heuristics but are not required to.
- Virtual placements are invisible prototypes, not real placements: they are deletable only via `d` = `i`, `I`, `r`, `R`, `n`, `N`; the position-based delete values never affect them.
- The images rendered on top of placeholders are not protocol placements at all — they cannot be manipulated with graphics commands; move, delete, or restyle them by editing the placeholder text.

### Relative Placements

A placement can be positioned relative to another placement instead of the cursor — useful with Unicode placeholders: a single transparent pixel image rides the text flow while real images anchor to it.

`ESC _Ga=p,i=<image_id>,p=<placement_id>,P=<parent_img_id>,Q=<parent_placement_id> ESC \`

- `P`/`Q` identify the *parent placement*; when the parent moves, the relative placement moves with it. `H` and `V` offset it by whole cells (positive = right/down) from the parent's top-left cell.
- Lifetimes are tied: deleting the parent deletes its relative placements, and an image with no remaining placements is deleted — parent and relatives form one managed group.
- Chains (a relative placement parenting another) must be supported to a depth of at least 8; exceeding the implementation's limit → `ETOODEEP`.
- Cycles (A relative to B relative to C relative to A) must be rejected with `ECYCLE`; a reference to a nonexistent placement → `ENOPARENT`.
- Virtual (Unicode-placeholder) placements cannot themselves be relative — `EINVAL` — but can serve as parents; their position is the minimum x and minimum y over all placeholder cells referring to them.

> Since a relative placement takes its position from another placement rather than the cursor, the cursor must not move after creating one, regardless of the `C` key.

## Deleting Images

`a=d` with no other keys deletes all placements visible on screen. The `d` key targets specific images; every value has a lowercase variant (delete placements/images but keep the stored data, so images can be re-displayed without resending) and an uppercase variant (also free the data, unless referenced elsewhere, e.g. in the scrollback buffer). `x`/`y` values are cursor-style cell coordinates (`x=1, y=1` is top left).

| `d`     | Deletes                                                                                                          |
|---------|------------------------------------------------------------------------------------------------------------------|
| `a`/`A` | All placements visible on screen                                                                                 |
| `i`/`I` | All images with the id in the `i` key; adding `p` deletes only that placement                                     |
| `n`/`N` | The newest image with the number in the `I` key; adding `p` deletes only that placement                           |
| `c`/`C` | All placements intersecting the current cursor position                                                          |
| `f`/`F` | Animation frames                                                                                                 |
| `p`/`P` | All placements intersecting the cell `x`,`y`                                                                      |
| `q`/`Q` | All placements intersecting the cell `x`,`y` with z-index `z`                                                     |
| `r`/`R` | All images with `x` ≤ id ≤ `y`                                                                                    |
| `x`/`X` | All placements intersecting column `x`                                                                            |
| `y`/`Y` | All placements intersecting row `y`                                                                               |
| `z`/`Z` | All placements with z-index `z`                                                                                   |

- When the last placement of an image is deleted with an uppercase form, the image itself is deleted. Under storage pressure, images without placements are evicted first.
- A delete command received during an incomplete chunked upload aborts the upload.

```
ESC _Ga=d ESC \               delete all visible placements
ESC _Ga=d,d=i,i=10 ESC \      delete image id=10, keep data
ESC _Ga=d,d=i,i=10,p=7 ESC \  delete placement 7 of image 10, keep data
ESC _Ga=d,d=Z,z=-1 ESC \      delete placements with z-index -1, free data
ESC _Ga=d,d=p,x=3,y=4 ESC \   delete placements intersecting cell (3, 4), keep data
```

## Suppressing Responses

The `q` key silences terminal responses for limited clients (e.g. shell scripts): `q=1` suppresses `OK` responses, `q=2` suppresses failure responses.

## Requesting Image Ids from the Terminal

Programs sharing the screen with others cannot know which image ids are free. The `I` key (image *number*) solves this: numbers need not be unique, and creating an image with `I` always creates a new image even if the number is already used. The terminal replies with the new id:

`ESC _Gi=99,I=13;OK ESC \`

Commands referring to an image by number (placements, deletes) always act on the *newest* image with that number, so a client can pipeline number-based commands and switch to the `i` key once the id arrives. Specifying both `i` and `I` in one command is an error — the terminal replies `EINVAL` unless silenced.

## Usage Hints

The `N` key is a bitmask of hints letting the terminal optimize caching. Currently only `N=1` (*transient*) is defined: the terminal may assume short-lived use — evicting the data first under storage pressure once the image is soft-deleted with no visible placements, or skipping disk writes — and is free to ignore the hint. A frame composited from transient frames inherits the hint. Specify it at transmission time; it has no effect on placement commands.

## Animation

Animations attach to a single image: first create a normal image, then add frames. All animation codes must identify the image with `i` or `I`. Two action modes are added: `a=f` (transmit frame data) and `a=a` (control playback). The design supports both client-driven and terminal-driven playback (latency between client and terminal is unknown, especially over SSH) and delta frames (animations often change little per frame).

### Transferring Frame Data

Like transferring image data, with `a=f` plus `i`/`I` in every code. Frames are composed onto a background canvas:

- `x, y, s, v` restrict the frame's data to a rectangle; the rest comes from the canvas.
- Canvas: `Y` = a 32-bit RGBA background color (e.g. `Y=4278190335` = `0xff0000ff` opaque red; default `0` = transparent black), or `c` = the 1-based frame number whose pixels serve as the canvas (`c=1` is the root frame — the base image data).
- Composition: full alpha blend by default; `X=1` for simple replacement.
- `r` edits an existing frame instead of creating a new one (1-based; `r=1` = root frame) — the canvas is that frame's current content.
- `z` sets the frame *gap* in milliseconds: `0` is ignored, positive sets the gap, negative creates a *gapless* frame. Gapless frames are never displayed (instantly skipped) but serve as base data for later frames — e.g. a static background behind moving objects. The root frame has no natural gap, so set it via the animation control code.

### Controlling Animations

`a=a` drives playback:

- `c` makes a frame current (client-driven): `ESC _Ga=a,i=3,c=7 ESC \` shows frame 7 of image 3.
- `s` sets the state: `s=1` stop, `s=2` run in *loading* mode (pause at the last frame awaiting more), `s=3` run and loop.
- `v` sets loops: `0` ignored, `1` infinite (default), any other positive `n` = `n - 1` loops. Stopping resets the loop counter.
- `z` sets a frame's gap, at transmit time or via control code: `ESC _Ga=a,i=7,r=3,z=48 ESC \` sets frame 3 of image 7 to 48 ms.

Client-driven animation suffers unknown latency and requires the client to stay alive; terminal-driven playback (gaps + start/stop) suits `cat`-like utilities.

### Composing Frames

`a=c` copies a rectangle of pixels from one frame onto another — fast, low-bandwidth frame edits:

`ESC _Ga=c,i=1,r=7,c=9,w=23,h=27,X=4,Y=8,x=1,y=3 ESC \`

composes the 23x27 rectangle at `(4, 8)` of frame 7 onto frame 9 at `(1, 3)` of image 1. `r` = source frame, `c` = destination frame, `w`/`h` = rectangle size (default: full image), `X`,`Y` = source offset, `x`,`y` = destination offset, `C` = mode (alpha blend default, `C=1` overwrite).

Errors: missing image or frames → `ENOENT`; rectangles out of bounds → `EINVAL`; same source and destination frame with overlapping rectangles → `EINVAL`.

> Compositing may force the terminal to fully render a frame previously stored as a sequence of operations, increasing storage; kitty responds `ENOSPC` if that exceeds available space.

## Persistence and Storage Quotas

Terminals should enforce a storage quota against denial of service, sized for at least a few full-screen images (kitty: 320 MB per buffer). When a new image would exceed the quota, older images are evicted to make room. Animation frame data may be stored on disk under a separate, larger quota (kitty: five times the base quota).

## Interaction with Other Terminal Actions

- Resetting the terminal clears all visible images.
- Switching to the alternate screen (mode 1049) clears that screen's images, just as its text is cleared; the erase-display code (`CSI 2J`) also clears images, so `clear` works.
- Other text-erasure commands must not affect graphics; use the delete commands.
- Scrolling (index commands, history navigation) scrolls images with the text. With page margins set, only images entirely inside the page area scroll, clipped at the margins.

## Control Data Reference

All integers are 32-bit; the *Default* column applies when the key is absent.

**General**

| Key | Values                                        | Default | Meaning            |
|-----|-----------------------------------------------|---------|--------------------|
| `a` | `t`, `T`, `q`, `p`, `d`, `f`, `a`, `c`        | `t`     | Action: transmit, transmit+display, query, put (display), delete, transmit frame, animation control, compose frames |
| `q` | `0`–`2`                                       | `0`     | Suppress responses: `1` = suppress OK, `2` = suppress errors |
| `d` | `aAcCnNiIpPqQrRxXyYzZ`                        | `a`     | What to delete (see Deleting Images) |

**Image transmission**

| Key | Values                | Default | Meaning                                      |
|-----|-----------------------|---------|----------------------------------------------|
| `f` | `24`, `32`, `100`     | `32`    | Data format: RGB, RGBA, PNG                  |
| `t` | `d`, `f`, `t`, `s`    | `d`     | Transmission medium                          |
| `s` | positive integer      | `0`     | Image width in pixels                        |
| `v` | positive integer      | `0`     | Image height in pixels                       |
| `S` | positive integer      | `0`     | Size of data to read from a file             |
| `O` | positive integer      | `0`     | Offset to read from in a file                |
| `i` | 1–4294967295          | `0`     | Image id                                     |
| `I` | 1–4294967295          | `0`     | Image number                                 |
| `p` | 1–4294967295          | `0`     | Placement id                                 |
| `o` | `z`                   | none    | Compression (zlib/deflate)                   |
| `m` | `0`, `1`              | `0`     | More chunked data follows                    |
| `N` | bitmask               | `0`     | Usage hints (`1` = transient)                |

**Image display**

| Key | Default | Meaning                                                                    |
|-----|---------|----------------------------------------------------------------------------|
| `x` | `0`     | Left edge (px) of the source rectangle                                     |
| `y` | `0`     | Top edge (px) of the source rectangle                                      |
| `w` | `0`     | Source rectangle width (px); `0` = full width                              |
| `h` | `0`     | Source rectangle height (px); `0` = full height                            |
| `X` | `0`     | X-offset (px) within the first cell                                        |
| `Y` | `0`     | Y-offset (px) within the first cell                                        |
| `c` | `0`     | Columns to display over                                                    |
| `r` | `0`     | Rows to display over                                                       |
| `C` | `0`     | Cursor movement policy; `1` = do not move the cursor                       |
| `U` | `0`     | `1` = create a virtual placement for Unicode placeholders                  |
| `z` | `0`     | Z-index stacking order                                                     |
| `P` | `0`     | Parent image id for relative placement                                     |
| `Q` | `0`     | Parent placement id for relative placement                                 |
| `H` | `0`     | Horizontal cell offset for relative placement                              |
| `V` | `0`     | Vertical cell offset for relative placement                                |

**Animation frame loading**

| Key | Default | Meaning                                                                                          |
|-----|---------|--------------------------------------------------------------------------------------------------|
| `x` | `0`     | Left edge (px) of the frame region being updated                                                  |
| `y` | `0`     | Top edge (px) of the frame region being updated                                                   |
| `c` | `0`     | 1-based frame whose pixels are the base canvas; default canvas is transparent black               |
| `r` | `0`     | 1-based frame to edit; default creates a new frame                                                |
| `z` | `0`     | Frame gap (ms); `0` ignored, negative = gapless frame; default 40 ms, root frame defaults to 0    |
| `X` | `0`     | Composition mode for frame creation/editing; `1` = overwrite instead of alpha blend               |
| `Y` | `0`     | Background color for unset pixels, 32-bit RGBA                                                    |

**Animation frame composition**

| Key | Default | Meaning                                             |
|-----|---------|-----------------------------------------------------|
| `c` | `0`     | 1-based destination frame                           |
| `r` | `0`     | 1-based source frame                                |
| `x` | `0`     | Left edge (px) of the destination rectangle         |
| `y` | `0`     | Top edge (px) of the destination rectangle          |
| `w` | `0`     | Rectangle width (px); `0` = full width              |
| `h` | `0`     | Rectangle height (px); `0` = full height            |
| `X` | `0`     | Left edge (px) of the source rectangle              |
| `Y` | `0`     | Top edge (px) of the source rectangle               |
| `C` | `0`     | Composition mode; `1` = overwrite instead of blend  |

**Animation control**

| Key | Default | Meaning                                                                                  |
|-----|---------|------------------------------------------------------------------------------------------|
| `s` | `0`     | `1` = stop, `2` = run awaiting more frames, `3` = run and loop                           |
| `r` | `0`     | 1-based frame being affected                                                             |
| `z` | `0`     | Frame gap (ms); `0` ignored, negative = gapless                                          |
| `c` | `0`     | 1-based frame to make current                                                            |
| `v` | `0`     | Loops: `0` ignored, `1` = infinite (default), `n` = `n - 1` loops                        |
