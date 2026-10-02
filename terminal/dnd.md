# Drag and Drop

A combined reference for drag-and-drop between terminal programs and the outside world: accepting drops, requesting dropped data (including from remote machines and directories), acting as a drag source with pre-sent data and drag images, and support detection. One escape-code form carries the whole protocol.

## Notation

- `OSC` is the Operating System Command introducer (`ESC ]`); `ST` is the string terminator (`ESC \`).
- *metadata* is a colon-separated list of `key=value` pairs; the *payload*'s meaning depends on the metadata.
- All integer values are 32-bit signed or unsigned, encoded in decimal.
- Error descriptions must contain only safe UTF-8 (no control characters).

## Wire Format

`OSC _dnd_code ; metadata ; payload ST`

Chunking:

- Payloads are limited to 4096 bytes; larger payloads are split across chunked escape codes. Every chunk but the last carries `m=1`; each chunk's payload is at most 4096 bytes.
- Only the first chunk is guaranteed to carry metadata other than `m`; later chunks may carry only `m` and `i`. The receiver uses the first chunk's metadata for the whole chain.
- While a chunked transfer is in progress, sending any other protocol codes except chunk continuations or queries (`t=q`) is a protocol error.
- Binary payloads are base64 (RFC 4648) encoded; the 4096-byte limit applies to the *encoded* bytes. Padding is optional and may appear only at the end of the last chunk.

## Accepting Drops

**Start accepting:**  
`OSC _dnd_code ; t=a ; payload ST`  

The payload is a space-separated list of accepted MIME types. It is optional — needed only for exotic or private MIME types on platforms (such as macOS) where the system does not deliver drop events for unregistered types.

**Stop accepting (also at exit):**  
`OSC _dnd_code ; t=A ST`  

### Move Events

While the user drags over the window, the terminal sends:

`OSC _dnd_code ; t=m:x=x:y=y:X=X:Y=Y:o=O ; optional MIME list ST`

- `x, y` — the cell under the drag (`0, 0` is the top-left cell); `X, Y` — pixel offsets from the top-left.
- `o` — the set of allowed operations: `1` copy, `2` move, `3` either, at the client's discretion.
- The MIME list is the space-separated list of types available for dropping; to avoid overhead the terminal sends it only with the first move event and afterwards only when it changes.

When the drag leaves the window, the terminal sends the same event with `x, y = -1, -1` and an empty MIME list. Negative coordinates are never sent for any other reason, and no further `t=m` events arrive until this drop or another re-enters the window.

### Accepting or Rejecting

Until the client responds, the terminal indicates to the OS that the drop is not accepted. The client answers:

`OSC _dnd_code ; t=m:o=O ; MIME list ST`

- `o` — the operation the client intends to perform: `1` copy, `2` move, `0` not accepted.
- The MIME list is the subset of offered types the client wants, ordered by decreasing preference; some platforms surface the first entry to the user. An absent list means no change to the offered set.

### The Drop

On an actual drop the terminal sends the move event's fields with `t=M` (uppercase) instead:

`OSC _dnd_code ; t=M:... ; MIME list ST`

The MIME list is mandatory here — the full list of types in the drop. No further `t=m` events arrive until a new drag enters the window. The client can now request data.

### Requesting Data

`OSC _dnd_code ; t=r:x=idx ST`

`idx` is the 1-based index into the `t=M` MIME list. The terminal responds with a series:

`OSC _dnd_code ; t=r:x=idx ; base64 data, possibly chunked ST`

End of data is an empty payload with `m=0`. On error:

`OSC _dnd_code ; t=R:x=idx ; POSIX error name:optional description ST`

The error name is a POSIX symbolic name (`ENOENT`, `EIO`, …) or `EUNKNOWN`. Unless otherwise noted, an error response terminates the drop.

Rules:

- Data may only be requested after an actual drop; requests before the `t=M` event fail with `EPERM` (this error does not terminate anything, as no drop is in progress).
- When a drag leaves the window without a drop, the terminal discards all session data (fetched URI lists, in-progress transfers, directory handles); requests referring to them fail.

### Completing the Drop

Once finished reading, the client sends a data request with no MIME type:

`OSC _dnd_code ; t=r:o=operation ST`

The terminal then reports drop completion to the OS and discards any queued data requests. `operation` is required and states what the client did with the data; unset (`0`) means the drop was canceled.

> On some platforms (macOS) there is no native `text/uri-list`; it is synthesized from structures such as file promises, and the referenced files are only guaranteed to exist while the drop is active. Copy them out before closing the drop.

### Dropping from Remote Machines

The client tells the terminal its machine id (see Machine Id) when enabling drops:

`OSC _dnd_code ; t=a:x=1 ; machine id ST`

The client first requests the `text/uri-list` (RFC 2483) MIME type from the drop. If the client sent its machine id and the terminal determines the client is on a different machine, the `t=r` responses gain the `X=1` key, telling the client it may request data for individual URI entries:

`OSC _dnd_code ; t=r:x=idx:y=subidx ST`

- `idx` — the 1-based index of the `text/uri-list` MIME type; `subidx` — the 1-based index into that list's entries.
- Responses mirror the request with `y=subidx` added: `OSC _dnd_code ; t=r:x=idx:y=subidx ; base64 data ST`, and errors likewise via `t=R:x=idx:y=subidx`.

Error rules:

| Condition                                              | Error      |
|--------------------------------------------------------|------------|
| `idx`/`subidx` out of bounds                           | `ENOENT`   |
| `text/uri-list` not requested first, or not in the drop | `EINVAL`   |
| Unsupported URI scheme (`file://` must be supported)   | `EUNKNOWN` |
| No permission to read the file                         | `EPERM`    |
| Not a regular file, symlink, or directory              | `EINVAL`   |
| File does not exist                                    | `ENOENT`   |
| I/O error                                              | `EIO`      |
| Drag originated in the same window as the drop         | `EPERM`    |
| Too many queued requests (denial-of-service guard)     | `EMFILE` — also ends the drop |

The same-window `EPERM` is defense in depth against a malicious program reading files by starting its own drag. Only regular files, symlinks, and directories are ever sent. Clients may pipeline multiple requests; terminals may answer in any order, including interleaved (FIFO is recommended), and responses are matched to requests via the `x`, `y`, and `Y` keys.

### Reading Remote Directories

When a `file://` URI points to a directory, the response is:

`OSC _dnd_code ; t=r:x=idx:y=subidx:X=handle ; base64 null-separated entry list ST`

The `X` key distinguishes entry kinds: `X=0` regular file, `X=1` symlink (payload is the target), any other value a directory *handle*. Directory payloads are base64-encoded, null-separated lists of entries (regular files, directories, symlinks), chunked if large.

Reading directory entries:

`OSC _dnd_code ; t=r:Y=handle:x=num ST`

`num` is the 1-based index into the previously sent entry list. Responses:

```
OSC _dnd_code ; t=r:Y=handle:x=num ; base64 file data ST
OSC _dnd_code ; t=r:Y=handle:x=num:X=1 ; base64 symlink target ST
OSC _dnd_code ; t=r:Y=handle:x=num:X=child-handle ; base64 sub-directory entry list ST
OSC _dnd_code ; t=R:Y=handle:x=num ; POSIX error name:optional description ST
```

`Y=handle` identifies the parent directory and `x=num` the entry within it. When done with a directory, the client sends `t=r:Y=handle`, freeing the terminal's resources; the handle is then invalid and further use fails with `EINVAL`. Clients should traverse breadth-first to minimize terminal resource usage; terminals may refuse traversal under resource pressure with `ENOMEM`.

## Starting Drags

**Offer drags / stop offering:**  
`OSC _dnd_code ; t=o:x=1 ; optional machine id ST`  
`OSC _dnd_code ; t=o:x=2 ST`  

The machine id enables dragging from remote machines (see Machine Id).

### The Drag Offer Flow

1. When the user performs the platform's drag gesture (typically holding the left button and dragging a short distance — the protocol mandates no specific gesture), the terminal sends `t=o` with `x, y, X, Y` set to the gesture's cell and pixel location.
2. If the client wants to start a drag there, it replies `t=o:o=flags` with a payload of the space-separated MIME types it offers. `flags`: `1` copy, `2` move, `3` either; chunk the list if long. The terminal may cancel with `t=E ; EFBIG` or `t=E ; ENOMEM` for an over-long list, or reject with `t=E ; EPERM` if the gesture already ended or the drag is inappropriate.
3. The drag has not started yet — the client can now pre-send data and drag images.

### Pre-sending Data

`OSC _dnd_code ; t=p:x=idx ; base64 data ST`

`idx` is the **zero-based** index into the offered MIME list; chunk with `m`, and end with an empty payload and `m=0`. Pre-send well-known types (`text/plain`, `text/uri-list`) unless very large — some platforms (macOS) need pre-sent data to interoperate with native programs. Terminals must accept at least 64 MB of pre-sent data and reply `t=E ; EFBIG`, canceling the drag, beyond their limit. Clients should only send the offer once the data is actually available.

### Drag Images

Associate images with the drag by sending `t=p` with negative `idx` values starting at `-1`, consecutively and in order. The `y` key selects the data format:

| `y`   | Format                                             |
|-------|----------------------------------------------------|
| `24`  | 24-bit RGB (sRGB)                                  |
| `32`  | 32-bit RGBA (sRGB)                                 |
| `100` | PNG                                                |
| `0`   | Base64-encoded UTF-8 text, rendered by the terminal |

`X` and `Y` give the pixel dimensions; a size mismatch fails with `t=E ; EINVAL`. With `y=0`, `X`/`Y` set the text size as `base_font_size * X/Y`; terminals may ignore newlines and render one line, so keep text short. The `o` key sets background opacity as `o/1024` (`0` transparent, `1024` fully opaque) — useful for drawing a Unicode symbol as the drag icon. Over-limit image data fails with `t=E ; EFBIG`, aborting the drag.

During the drag, change the image with:

`OSC _dnd_code ; t=P:x=idx ST`

`idx` is zero-based here; an out-of-bounds `idx` removes the drag image. By default the first image is used.

### Starting and Status Events

Once all data and images are sent, start the drag with `t=P:x=-1`. The terminal responds `t=E ; OK` on success; `t=E ; EPERM` if the user canceled or the drag is disallowed; `t=E ; EFBIG` if the converted image data is too large; other failures carry the appropriate POSIX error name.

As the drag progresses, the terminal reports status with `t=e`:

| Event                | Meaning                                                                                       |
|----------------------|-----------------------------------------------------------------------------------------------|
| `t=e:x=1:y=idx`      | The drag was accepted by a target; `idx` is the zero-based MIME index the target likely wants |
| `t=e:x=2:o=O`        | The target's likely action changed to `o`                                                      |
| `t=e:x=3`            | The drag was dropped on a target — data requests are likely to follow                          |
| `t=e:x=4:y=0 or 1`   | The drag is finished; `y=1` means the user canceled                                            |
| `t=e:x=5:y=idx`      | Data request for the MIME type at zero-based `idx`                                             |

Answering data requests:

`OSC _dnd_code ; t=e:y=idx:m=0 or 1 ; base64 data ST`

Chunk with `m`; end of data is `m=0` with an empty payload. On error the client sends `OSC _dnd_code ; t=E:y=idx ; POSIX error name:optional description ST` (`ENOENT` unknown type, `EIO` I/O error, …). To cancel the whole drag at any time: `OSC _dnd_code ; t=E:y=-1 ST`.

Sending `t=e`/`t=E` before the drag has started (before the terminal's `t=E ; OK`) fails with `t=E ; EINVAL` and aborts the drag.

### Dragging to Remote Machines

For remote targets the client **must** pre-send `text/uri-list`, and `file://` URLs pointing to directories **must** end with `/`. The terminal compares the machine id from the `t=o` offer and, for remote clients, requests URI-list entries directly:

`OSC _dnd_code ; t=k:x=idx ST`

`idx` is the 1-based index into the `text/uri-list` entries. The client responds:

```
OSC _dnd_code ; t=k:x=idx:m=0 or 1 ; base64 file data ST
OSC _dnd_code ; t=k:x=idx:X=1:m=0 or 1 ; base64 symlink target ST
OSC _dnd_code ; t=k:x=idx:X=handle:m=0 or 1 ; base64 null-separated directory entry list ST
```

As with remote drops, `X` marks regular files (absent/`0`), symlinks (`1`), and directories (a *handle*). Directory children are sent by adding `Y=parent-handle:y=num` (1-based entry index); the keys `x, y, Y` together identify an entry. Clients **must** send all directory children recursively (breadth-first recommended); terminals **must not** request children — only `text/uri-list` entries. End of data per entry is `m=0` with no payload. Terminals may pipeline requests; clients should answer FIFO.

If the client hits an error while reading, it informs the terminal with `OSC _dnd_code ; t=E ; POSIX error name:optional description ST` and the terminal aborts the drag. Terminals may impose resource limits and abort likewise (`EMFILE` for too many resources, `EIO` for I/O errors, …).

## Detecting Support

`OSC _dnd_code ; t=q:i=optional ST`

A supporting terminal **must** respond:

`OSC _dnd_code ; t=q:i=echoed ; payload ST`

The `i` key is optional and echoed back. The payload is a colon-separated list of `key=value` pairs describing optional/future features; it is currently empty. Send the query followed by a primary device attributes request: if the device-attributes response arrives before the query response, the terminal does not support the protocol.

## Multiplexers

When a `t=a` or `t=o` code carries an `i` key, the terminal includes the same `i` value in every code it sends back to that client, letting multiplexers route responses to the correct window.

## Metadata Reference

All integers are 32-bit; the *Default* column applies when the key is absent.

| Key | Values         | Default | Meaning |
|-----|----------------|---------|---------|
| `t` | single character | `a`   | Event type: `a` accept drops, `A` stop accepting, `m` drop move, `M` dropped, `r` request dropped data, `R` error report, `o` offer/start drags, `p` present drag-offer data, `P` change drag image or start drag, `e` drag-offer event, `E` drag-offer error, `k` data for uri-list entries in a drag offer, `q` query support |
| `m` | `0` or `1`     | `0`     | Chunking indicator                          |
| `i` | positive integer | `0`   | Multiplexer routing id; echoed in all responses of the session |
| `o` | positive integer | `0`   | Drop operation: `0` rejected, `1` copy, `2` move |
| `x` | integer        | `0`     | Cell x-coordinate (`0,0` at top left)       |
| `y` | integer        | `0`     | Cell y-coordinate                           |
| `X` | integer        | `0`     | Pixel x-coordinate                          |
| `Y` | integer        | `0`     | Pixel y-coordinate                          |

## Machine Id

The machine id detects when the drag source and destination are different machines. Its form is `version:ASCII printable chars`; the version prefix allows the format to change. The raw id per platform:

| Platform | Source                                                                 |
|----------|------------------------------------------------------------------------|
| macOS    | The `IOPlatformUUID` system value                                       |
| Windows  | The `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` registry value   |
| Other    | The contents of `/etc/machine-id`, trailing whitespace removed          |

The raw id is hashed with HMAC (RFC 2104) using SHA-256 (RFC 6234) and the ASCII key `tty-dnd-protocol-machine-id`, hiding the real id while producing a fixed-size, printable value:

`1:<hex-encoded HMAC-SHA256 of the machine id>`

If the terminal sees a version it does not understand, it must assume the machines differ — remote drag and drop still works, just with reduced performance.
