# Clipboard

A combined reference for clipboard access from terminal programs: reading and writing arbitrary MIME-typed data via OSC 5522 (an extension of the legacy OSC 52 plain-text protocol), payload encoding and chunking, permission handling, unsolicited paste-event notifications via private mode 5522, and terminal multiplexer support.

## Notation

- `OSC` is the Operating System Command introducer (`ESC ]`); `ST` is the string terminator (`ESC \` or `BEL`).
- `CSI` is the Control Sequence Introducer (`ESC [`). DEC private modes are set with `CSI ? mode h` and reset with `CSI ? mode l`.
- *metadata* is a colon-separated list of `key=value` pairs; *payload* is base64-encoded data.
- The metadata keys documented as base64-encoded (`mime`, `name`, `pw`) use the same encoding as payloads.

## Protocol Overview

The legacy `OSC 52` escape code lets terminal programs read and write plain-text clipboard data. `OSC 5522` extends it to:

- Copy arbitrary data — images, rich-text documents, etc. — keyed by MIME type
- Let the terminal ask the user for permission to access the clipboard, and report permission denied

**Wire format:**  
`OSC 5522;metadata;payload ST`  

## Encoding of Payloads

- All payloads, in both directions, use standard RFC 4648 base64 with the standard alphabet. Padding is required: every encoded value is a multiple of four bytes.
- Terminals should reject invalid base64 — characters outside the alphabet (including whitespace and line breaks) or incorrect padding — and must not silently discard invalid characters, since that turns corrupted data into apparently valid data.
- A write request rejected for invalid base64 aborts with `EINVAL`; read requests have no error status, so a rejected read is simply ignored.
- When one MIME type's data is split over multiple `wdata` packets, only the concatenation of its payloads must be correctly padded; an individual chunk need not be a multiple of four bytes.

## Reading

**Request:**  
`OSC 5522;type=read;<base64 space-separated MIME type list> ST`  

- To read plain text and PNG data, for example, the payload is the base64 encoding of `text/plain image/png`.
- To read from the primary selection instead of the clipboard, add `loc=primary` to the metadata.
- To list the MIME types available on the clipboard, the payload is just `.` (base64).

**Reply sequence:**

```
OSC 5522;type=read:status=OK ST
OSC 5522;type=read:status=DATA:mime=<base64 MIME type>;<base64 data> ST
OSC 5522;type=read:status=DATA:mime=<base64 MIME type>;<base64 data> ST
...
OSC 5522;type=read:status=DONE ST
```

- `status=DATA` packets deliver the base64-encoded bytes of each MIME type, chunked to **no more than 4096 bytes per chunk** (measured before base64 encoding).
- All chunks for a given type are transmitted sequentially; chunks for the next type follow only once it is done. `status=DONE` marks the end of data.

**Errors.** On failure the terminal sends a single `status=ERRORCODE` packet in place of the opening `status=OK`:

| Status          | Meaning                                                                                            |
|-----------------|----------------------------------------------------------------------------------------------------|
| `status=ENOSYS` | Requested clipboard type not available (e.g. `loc=primary` on a system with no primary selection)  |
| `status=EPERM`  | Read permission denied by the system or the user                                                   |
| `status=EBUSY`  | Temporary problem, such as competing clients in a multiplexer                                      |

> Terminals should ask the user's permission before allowing a read. A request that only lists the available MIME types should proceed without a prompt, so the user is not prompted twice — once for the list, once for the data.

## Writing

**Packet sequence:**

```
OSC 5522;type=write ST
OSC 5522;type=wdata:mime=<base64 MIME type>;<base64 data chunk> ST
OSC 5522;type=wdata:mime=<base64 MIME type>;<base64 data chunk> ST
...
OSC 5522;type=wdata ST
```

- The final `type=wdata` packet — no `mime`, no payload — marks end of transmission.
- Data for each MIME type is split into chunks of no more than 4096 bytes (before base64 encoding); all chunks for one type are sent sequentially before the next type begins.
- On success the terminal replies: `OSC 5522;type=write:status=DONE ST`
- To write to the primary selection, add `loc=primary` to the initial `type=write` packet.

**Errors.** The terminal may send `OSC 5522;type=write:status=ERRORCODE ST` at any time:

| Status          | Meaning                                                                                                                            |
|-----------------|------------------------------------------------------------------------------------------------------------------------------------|
| `status=EIO`    | I/O error while processing the data                                                                                                |
| `status=EINVAL` | Invalid packet — usually invalid base64 or a missing MIME type; the terminal discards all data received for the current write      |
| `status=ENOSYS` | `loc=primary` requested on a system with no primary selection                                                                      |
| `status=EPERM`  | Write permission denied by the system or the user                                                                                  |
| `status=EBUSY`  | Temporary problem, such as competing clients in a multiplexer                                                                      |
| `status=EFBIG`  | Data exceeds the terminal's storage limit; terminals may impose a limit to avoid denial of service, but must accept at least 64 MB |

- After an error, the terminal ignores all further write-related packets until a new `type=write` packet begins a fresh request.

### MIME Type Aliasing

A `type=walias` packet exposes additional MIME types sharing already-transmitted data:

`OSC 5522;type=walias:mime=<base64 target MIME type>;<base64 space-separated alias list> ST`

The clipboard makes every alias available with the same data as the target — one transmission, multiple references. Alias packets may be sent any time after the initial `type=write` and before the end-of-data packet.

## Avoiding Repeated Permission Prompts

Programs that use the clipboard frequently (an editor, for example) would otherwise prompt the user on every read request. To avoid this, `type=write` and `type=read` requests may carry two extra metadata keys:

- `pw` — a base64-encoded UTF-8 password. Programs should ideally use a password randomly generated at startup, such as a UUID4; terminals may also implement permanent, user-configured passwords for trusted programs.
- `name` — a base64-encoded UTF-8 human-friendly name for the program.

The terminal can then offer to allow all future requests using that password; if the user agrees, later requests on the same tty are allowed automatically. A password sent without a name is equivalent to no password, and the terminal must treat the request as though it had none.

## Paste Events (Private Mode 5522)

Bracketed paste (mode 2004) distinguishes pasted content from typed input but delivers plain text only, with no MIME type information. Private mode 5522 instead makes each paste event trigger an *unsolicited* MIME type listing over this protocol; the application is then free to request whatever MIME data it wants from the list. Standard bracketed paste is not used.

> The mode requires terminal support for the clipboard protocol (OSC 5522); conforming terminals must support the extension in its entirety.

### Detection and Mode Control

**Query (DECRQM):**  
`CSI ? 5522 $ p`  

**Response (DECRPM):**  
`CSI ? 5522 ; Ps $ y`  

A `Ps` value of `0` or `4` means the mode is not supported.

**Enable / Disable:**  
`CSI ? 5522 h` / `CSI ? 5522 l`  

### Notification Format

When the user pastes, the terminal sends the same sequence it would send for a read request of the MIME type `.` (base64 `Lg==`), plus a single-use password:

```
OSC 5522;type=read:status=OK[:loc=primary][:pw=<base64 password>] ST
OSC 5522;type=read:status=DATA:mime=Lg==[:pw=<base64 password>];<base64 MIME list> ST
OSC 5522;type=read:status=DONE[:pw=<base64 password>] ST
```

- `loc=primary` is present only when the paste came from the primary selection; it is omitted for the default system clipboard.
- `pw` is a base64-encoded, single-use password generated by the terminal for this paste event; when repeated in the DATA and DONE packets it must carry the same value.
- The MIME list payload decodes to a whitespace-separated list; split on ASCII whitespace and ignore leading or trailing whitespace — never depend on the list ending with a newline.

The application then reads the desired types with a standard read request, reusing the location and password:

`OSC 5522;type=read[:loc=primary][:pw=<base64 password>:name=<base64 name>];<base64 MIME list> ST`

- The payload lists one or more desired MIME types; if at least one is available, the terminal must ignore unavailable requested types and return the rest in the standard chunked reply.
- When using a paste-event password, `name` should be `Paste event` (base64 `UGFzdGUgZXZlbnQ=`). A password without a name is ineffective.

### Behavior Rules

- The notification must include every MIME type available at the paste event's clipboard location.
- Mode 5522 takes precedence over bracketed paste: if both 5522 and 2004 are enabled, the terminal must use 5522 and must never send both sequence types for the same paste event.
- The password must be scoped to the clipboard location that caused the paste, must not authorize reads from any other location, and must be invalidated after use or after a short timeout.
- If the password is absent or invalid, the terminal falls back to its standard security behavior (e.g. prompting the user).
- MIME listings reveal only the available formats, not the actual content; listings never require a prompt, and clipboard data is transmitted only after an explicit read request.

### Example

Querying support, enabling the mode, and handling a plain-text paste of `Hello, world!` (password `secret123`, base64 `c2VjcmV0MTIz`):

```
A: CSI ? 5522 $ p
T: CSI ? 5522 ; 2 $ y                          supported, currently reset
A: CSI ? 5522 h

T: OSC 5522;type=read:status=OK:pw=c2VjcmV0MTIz ST
T: OSC 5522;type=read:status=DATA:mime=Lg==:pw=c2VjcmV0MTIz;dGV4dC9wbGFpbgo= ST
T: OSC 5522;type=read:status=DONE:pw=c2VjcmV0MTIz ST

A: OSC 5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg== ST

T: OSC 5522;type=read:status=OK ST
T: OSC 5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;SGVsbG8sIHdvcmxkIQ== ST
T: OSC 5522;type=read:status=DONE ST
```

A paste of HTML with a plain-text fallback from the primary selection (password `secret456`):

```
T: OSC 5522;type=read:status=OK:loc=primary:pw=c2VjcmV0NDU2 ST
T: OSC 5522;type=read:status=DATA:mime=Lg==:pw=c2VjcmV0NDU2;dGV4dC9odG1sIHRleHQvcGxhaW4K ST
T: OSC 5522;type=read:status=DONE:pw=c2VjcmV0NDU2 ST

A: OSC 5522;type=read:loc=primary:pw=c2VjcmV0NDU2:name=UGFzdGUgZXZlbnQ=;dGV4dC9odG1s ST

T: OSC 5522;type=read:status=OK ST
T: OSC 5522;type=read:status=DATA:mime=dGV4dC9odG1s;PGI+Qm9sZCB0ZXh0PC9iPg== ST
T: OSC 5522;type=read:status=DONE ST
```

(`SGVsbG8sIHdvcmxkIQ==` decodes to `Hello, world!`; `PGI+Qm9sZCB0ZXh0PC9iPg==` decodes to `<b>Bold text</b>`.)

## Multiplexer Support

Because this protocol is two-way communication between the terminal and the client, multiplexers need to know which window a response belongs to:

- The metadata may carry an `id` field; when present, the terminal must return it unchanged with every response.
- Valid ids use only characters from the set `[a-zA-Z0-9-_+.]`; the terminal strips any other characters before retransmitting.
- The system clipboard is a single global shared resource, so two programs can inevitably overwrite each other's requests. Responses can additionally get lost when multiple requests are in flight — well-designed multiplexers allow only one request at a time and abort others with `EBUSY`.
- Unsolicited paste-event notifications carry no `id`; the multiplexer forwards them to the currently active window.
