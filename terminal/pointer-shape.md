# Pointer Shapes

A reference for changing the terminal's mouse pointer shape from applications: setting shapes, a push/pop stack for temporary overrides, querying support, and interaction with other terminal state. Useful for buttons, links, drag-to-resize affordances, and similar UI.

## Notation

- `OSC` is the Operating System Command introducer (`ESC ]`); the terminator is `ESC \`.
- Spaces inside the wire formats below are for readability only and are not part of the protocol.
- Shape names consist only of characters from the set `a-z0-9_-`.

## Wire Format

`OSC 22 ; <optional first char> <comma-separated list of shape names> ESC \`

```
OSC 22 ; pointer ESC \          set the pointer to a pointing hand
OSC 22 ; ESC \                  reset the pointer to default
OSC 22 ; >wait ESC \            push a shape, making it current
OSC 22 ; < ESC \                pop a shape, restoring the previous one
OSC 22 ; ?__current__ ESC \     query the currently set shape
```

## Setting the Pointer Shape

For set operations the first char is `=` or omitted, followed by the shape name:

`OSC 22 ; =pointer ESC \`

## Pushing and Popping the Shape Stack

The terminal maintains a stack of shapes:

- `>` pushes all listed names onto the stack; the last name becomes the top of the stack and the current shape. When the stack is full, the bottom entry is evicted. Implementations choose the maximum size, with a minimum of 16.
- `<` pops the top of the stack; the name list is ignored. Popping an empty stack has no effect; an empty stack means the terminal may use whatever shape it likes.

## Querying

With `?` as the first char, the name list is a query, answered with an OSC 22 response:

- `?__current__` — replies with the current shape's name, or `0` if the stack is empty (no shape set):

```
OSC 22 ; ?__current__ ESC \   →   OSC 22 ; shape_name ESC \
```

- `?<name>,<name>,…` — replies with a comma-separated list of `0`/`1` flags indicating support per name:

```
OSC 22 ; ?pointer,crosshair,no-such-name,wait ESC \   →   OSC 22 ; 1,1,0,1 ESC \
```

Special query names:

| Name          | Response                                              |
|---------------|-------------------------------------------------------|
| `__current__` | The currently set shape, or `0` if none               |
| `__default__` | The shape the terminal uses by default                |
| `__grabbed__` | The shape used when the mouse is "grabbed"            |

## Interaction with Other Terminal State

- The terminal maintains **separate shape stacks for the main and alternate screens**, so full-screen programs (the main consumers) can suspend back to the shell without managing pointer state.
- Resetting the terminal empties both stacks.
- During text-selection drags the terminal may ignore the requested shape in favor of a drag-appropriate one; likewise when hovering URLs or OSC 8 hyperlinks.
- The feature is independent of mouse reporting: shapes apply whether or not the application has enabled mouse reporting.

## Shape Names

The mandatory set is based on the CSS `cursor` property names, giving system-independent, well-defined shapes:

|               |               |               |               |
|---------------|---------------|---------------|---------------|
| `alias`       | `cell`        | `copy`        | `crosshair`   |
| `default`     | `e-resize`    | `ew-resize`   | `grab`        |
| `grabbing`    | `help`        | `move`        | `n-resize`    |
| `ne-resize`   | `nesw-resize` | `no-drop`     | `not-allowed` |
| `ns-resize`   | `nw-resize`   | `nwse-resize` | `pointer`     |
| `progress`    | `s-resize`    | `se-resize`   | `sw-resize`   |
| `text`        | `vertical-text` | `w-resize`  | `wait`        |
| `zoom-in`     | `zoom-out`    |               |               |

## Legacy xterm Compatibility

The original xterm proposal used shape names from X11's `cursorfont.h`. Terminals wishing to stay xterm-compatible may implement those names as aliases for the CSS-based names above. The simplest form of this code — no leading character and a single shape name — is compatible with xterm.
