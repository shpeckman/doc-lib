# Desktop Notifications

A combined reference for showing desktop notifications from terminal programs via OSC 99: chunked title/body/icon/button payloads, activation and close reporting, updates and expiry, sounds, urgency, and support querying. Usable from plain shell scripts.

## Notation

- `OSC` is the Operating System Command introducer (`ESC ]`); the terminator is `ESC \`.
- *metadata* is a colon-separated list of `key=value` pairs. Keys are single characters from `a-zA-Z`; values are words drawn from `` a-zA-Z0-9-_/\+.,(){}[]*&^%$#@!`~ ``.
- The two semicolons **must** always be present, even with empty metadata.
- *Identifiers* are strings from the set `[a-zA-Z0-9_-+.]`, ideally globally unique (UUID-like). Terminals **must** sanitize ids received from clients before echoing them in responses — reject or strip out-of-set characters — to mitigate input-injection attacks.
- *Safe UTF-8* is valid RFC 3629 UTF-8 with no C0 or C1 control characters (U+0000–U+001F, U+007F, U+0080–U+009F) — in particular no newlines, carriage returns, or tabs.
- *base64* is RFC 4648. When chunking before encoding: at most 2048 raw bytes per chunk, padding required. When chunking after encoding: at most 4096 encoded bytes per chunk, padding optional on the last chunk — terminals must accept both.

## Wire Format

`OSC 99 ; metadata ; payload ESC \`

```
printf '\x1b]99;;Hello world\x1b\\'
printf '\x1b]99;i=1:d=0;Hello world\x1b\\'
printf '\x1b]99;i=1:p=body;This is cool\x1b\\'
```

The `p` key selects the payload type (`title` by default); the examples show a one-shot notification, then a title (`d=0`, not yet done) followed by its body.

Chunking is fundamental to the design, since escape-code length limits vary between terminals: `i` carries the notification id and `d` the *done* flag (`0` = hold off displaying, `1` = complete). Title or body may be sent multiple times; the terminal concatenates them, allowing arbitrarily long text (terminals may impose sane limits against denial of service). Payloads are at most 2048 bytes before encoding, or 4096 encoded bytes.

Title and body payloads are safe UTF-8, or base64-encoded UTF-8 with `e=1` in the metadata. Strictly plain text — no HTML or other markup. Unknown keys must be ignored (future extensibility); for unknown values of known keys the terminal should ignore the code or make a best-effort display.

## Filtering: Application Name and Type

Well-behaved applications identify themselves with `f` (application name) and `t` (notification type), letting users filter notifications. Both values are base64-encoded UTF-8; `t` may appear multiple times, as notifications can have several types (the freedesktop notification spec's categories are good examples).

> Set `f` to the application's desktop-file name (without `.desktop`) or its macOS bundle identifier — not strictly required, but it lets the terminal deduce an icon when none is specified.

## Activation Reporting

The `a` key controls what happens when the user clicks the notification — a comma-separated set of `focus` and `report`:

- `focus` (default) — focus the window the notification came from.
- `report` — send an escape code back to the application.

**Activation response:**  
`OSC 99 ; i=identifier ; ESC \`  

The identifier comes from the original `i` key; if none was sent, the terminal must use `i=0` (kept for backward compatibility — ideally `i` would be omitted). Prefix an action with `-` to disable it: `a=-focus` requests no action at all.

## Close Events

Send `c=1` with the notification to be informed when it closes:

```
OSC 99 ; i=mynotification:c=1 ; hello world ESC \
OSC 99 ; i=mynotification:p=close ; ESC \        sent when it closes
```

Without an id, the response uses `i=0`. With `a=report`, activation sends both the activation report and the close event. Updating a notification drops the close request unless the update re-requests it.

On platforms where the OS does not report notification closure (e.g. macOS), the terminal instead replies:

`OSC 99 ; i=mynotification:p=close ; untracked ESC \`

Applications can then poll for still-alive notifications:

```
OSC 99 ; i=myid:p=alive ; ESC \              query
OSC 99 ; i=myid:p=alive ; id1,id2,id3 ESC \  response: comma-separated live ids
```

`myid` is echoed for multiplexer routing.

## Updating and Closing

- **Update:** send a new notification with the same `i` id. If the original is still displayed it is replaced (progress indicators, etc.); otherwise a new one appears. Replacement smoothness depends on the OS (usually flicker-free on Linux, not on macOS). With no `i` key, no updating occurs — two id-less notifications are distinct *unidentified* notifications.
- **Close:** `OSC 99 ; i=<id>:p=close ; ESC \`. Unknown ids are ignored; a missing `i` makes this a no-op.

## Automatic Expiry

The `w` key sets auto-close in milliseconds: `-1` (default) follows OS policy, `0` means never expire (best-effort — some platforms ignore it), positive values are robust since the terminal can enforce them itself. The notification may still close earlier through user interaction or OS policy, but is guaranteed closed once the expiry passes.

## Icons

The `n` key names an icon (base64-encoded UTF-8); it may appear multiple times — the terminal uses the first name that resolves on the system. Conforming terminals must support these names:

| Name             | Description                                    |
|------------------|------------------------------------------------|
| `error`          | An error symbol                                |
| `warn`, `warning`| A warning symbol                               |
| `info`           | An informational-message symbol                |
| `question`       | A question symbol                              |
| `help`           | A help-message symbol                          |
| `file-manager`   | A generic file-manager application symbol      |
| `system-monitor` | A generic system-monitoring application symbol |
| `text-editor`    | A generic text-editor application symbol       |

Application icons use application identifiers — the `.desktop` filename on Linux, the bundle identifier on macOS; cross-platform applications should send both (e.g. `net.foo-bar-website.foobar` and `foo-bar`). With no icon specified but `f` present, the terminal should try `f`'s value for an icon.

### Transmitted Icon Data

`p=icon` makes the payload the icon image itself — PNG, JPEG, or GIF, recommended size 256x256, always sent encoded (`e=1`). When both name and data are given, the terminal must try the name first and fall back to the data, so users see their icon theme where possible.

The `g` key caches icon data under a globally unique identifier (UUID-like). Later notifications reference the same icon with `g` alone, without re-transmitting; the cache lives as long as the terminal runs. The `g` key refers only to icon data — different notifications with different names can share one `g`. Multiplexers must cache icon data themselves and refresh it in the underlying terminal on detach/reattach, so applications transmit each icon only once per run.

> Terminals may cap the icon cache and evict least-recently-used entries; the failure mode is simply that the icon does not display. Icon presentation depends on the OS — Linux typically shows one icon, macOS shows both the terminal's and the custom icon.

## Buttons

`p=buttons` makes the payload a list of button labels — UTF-8 text separated by U+2028 (bytes `0xe2 0x80 0xa8`), sent as safe UTF-8 or base64. With `a=report` enabled, clicking a button sends:

`OSC 99 ; i=identifier ; button_number ESC \`

`button_number` is 1-based. Activating the notification as a whole sends the plain activation response (`OSC 99 ; i=identifier ; ESC \`). Without an identifier, `i=0` is used. The terminal must not send any response unless `report` was requested.

> Button presentation is OS-dependent: individual buttons on most Linux systems, a hover drop-down menu on macOS. More than two or three buttons is not advisable.

## Sounds

The `s` key (base64-encoded UTF-8) names the sound to play. Known names:

| Name              | Description                                                     |
|-------------------|-----------------------------------------------------------------|
| `system`          | The platform's default notification sound (possibly silence)    |
| `silent`          | No sound                                                        |
| `error`           | Error-message sound                                             |
| `warn`, `warning` | Warning-message sound                                           |
| `info`            | Information-message sound                                       |
| `question`        | Question sound                                                  |

Other names are implementation-dependent (on Linux, likely the freedesktop standard sound names). Terminals should support at least `system` and `silent`; query support as below.

## Querying Support

**Query:**  
`OSC 99 ; i=<identifier>:p=? ; ESC \`  

**Response:**  
`OSC 99 ; i=<identifier>:p=? ; key=value : key=value ESC \`  

The identifier is echoed for multiplexer routing. Defined response keys:

| Key | Value                                                                                                  |
|-----|--------------------------------------------------------------------------------------------------------|
| `a` | Comma-separated list of implemented `a` actions; absent if none                                        |
| `c` | `c=1` if close events are supported, otherwise omitted                                                  |
| `o` | Comma-separated list of implemented `o` occasions; `o=always` if none beyond the default               |
| `p` | Comma-separated list of supported payload types; must contain at least `title`                         |
| `s` | Comma-separated list of supported standard sound names                                                  |
| `u` | Comma-separated list of implemented urgency values; absent if urgency is unsupported                    |
| `w` | `w=1` if auto-expiry is supported                                                                       |

Clients must ignore response keys they do not understand. As with other protocols, the robust support probe is this query followed by a primary device attributes request: a DA1 response with no query response means the protocol is unsupported.

## Key Reference

| Key | Value                                              | Default   | Meaning |
|-----|----------------------------------------------------|-----------|---------|
| `a` | Comma list of `report`, `focus`, optional leading `-` | `focus` | Action on click |
| `c` | `0` or `1`                                         | `0`       | Send an escape code when the notification closes |
| `d` | `0` or `1`                                         | `1`       | Non-zero = notification complete, display it |
| `e` | `0` or `1`                                         | `0`       | `1` = payload is base64-encoded UTF-8; otherwise safe UTF-8 |
| `f` | base64 application name                            | unset     | Sending application's name, for filtering |
| `g` | identifier                                         | unset     | Icon-data cache key; make globally unique |
| `i` | identifier                                         | unset     | Notification id; make globally unique for multiplexer routing. `i=0` is special (backward compatibility) and should not be used |
| `n` | base64 icon name                                   | unset     | Icon name; repeatable, first match wins |
| `o` | `always`, `unfocused`, `invisible`                 | `always`  | When to honor the request: always; only when the window lacks keyboard focus; only when also invisible (inactive tab, hidden OS window) |
| `p` | `title`, `body`, `close`, `icon`, `?`, `alive`, `buttons` | `title` | Payload type. No title → body serves as title; neither → ignored. Unknown types should be ignored for future expansion |
| `s` | base64 sound name                                  | `system`  | Sound to play; `silent` = none |
| `t` | base64 notification type                           | unset     | Type for filtering; repeatable |
| `u` | `0`, `1`, `2`                                      | unset     | Urgency: low, normal, critical; unset = normal |
| `w` | integer `>= -1`                                    | `-1`      | Auto-close after this many milliseconds |
