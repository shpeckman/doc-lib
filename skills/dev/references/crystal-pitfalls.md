# Crystal pitfalls — verified in this sandbox (Crystal 1.21.0)

All items below were hit and fixed in real sessions (a 1.21.0 self-test battery on
2026-08-11, plus user-reported compiler errors from a kitty-graphics shard and an
agent-swarm shard). Read this before writing non-trivial Crystal.

## FFI / C bindings

1. **`lib ... fun` signatures only allow primitive/concrete types.** Bare `Int` is
   rejected: `Error: only primitive types, pointers, structs, unions, enums and tuples
   are allowed in lib declarations, not Int (did you mean LibC::Int?)`. Use `Int32`
   or the `LibC::*` alias — in parameter AND return positions.
2. **`Proc` callback params:** when a `fun` param is declared as a `Proc` type, pass
   the Crystal proc directly — the compiler auto-converts it to a C callback.
   `Proc#pointer.closure` is not the API.
3. **Linux shm/rt:** on glibc >= 2.34, `shm_open`/`shm_unlink` live in libc; keeping
   `@[Link("rt")]` as well preserves compatibility with older toolchains.

## Type system

4. **Abstract numerics can't be union members.** `Int | String` in a method signature
   fails with `can't use Int in unions yet, use a more specific type`. Use `Int32`
   (or another concrete type).
5. **`UInt8 == Char` compiles but is always false at runtime** (resolves to
   `Object#==`). Compare bytes to ints (`b == 0x5B`) or use `'['.ord`. Silent logic
   bug — the compiler will not warn.
6. **Assignment inside `when`** (`when route = routes[path]?`) compares the assigned
   value against the case subject, rarely what you want. Restructure as `if ... else
   case`.
7. **Exhaustive `case ... in`** works well; prefer it over long if/elsif on enums.

## Time

8. Keep **`Time` (a deadline) vs `Time::Span` (a duration)** straight — passing a
   `Time::Span` where a `Time` is expected (and vice versa) is a common compile
   error in timeout code. Pattern: `deadline = Time.instant + timeout`, then
   `remaining = deadline - Time.instant`.
9. `IO.select(read_ios, write_ios = nil, error_ios = nil, timeout : Time::Span?)` —
   pass the `Time::Span` itself, not `.total_seconds`.
10. `Time.monotonic` is deprecated in 1.21 — use `Time.instant` (`Time::Instant`).

## Macros

11. **`@type.instance_vars` is empty at `include` time** (type not finished). Defer
    generation with `{% verbatim do %}` so it runs at instantiation. A deferred
    for-loop must emit *whole statements* — splicing one inside a tuple literal
    fails to parse. Watch `{%` escaping levels (over-escaping leaves code literal).
12. **`{% ... %}` inside `#` comments is still lexed** — a literal macro tag in a
    comment can break compilation. Avoid macro syntax in comments.

## Syntax / stdlib edge cases

13. **`yield` inside a captured block is illegal** (`spawn { ch.send(yield x) }`).
    Name the block (`def m(&block : T -> U)`) and call `block.call(x)`.
14. **No trailing `while` modifier** (`i += 1 while cond`) — Ruby-ism Crystal rejects.
15. **`raise` takes no keyword args** — `raise msg, cause: ex` is invalid; use
    `raise MyError.new("msg", cause: ex)`.
16. **`BigFloat`:** `to_s(precision)` and `precision` don't exist — only `to_s` /
    `to_s(io : IO)`.
17. **Nilable fields in unions:** a `Foo | Nil` ivar fails `expected argument ... not
    (Foo | Nil)` — unwrap with `.not_nil!` or `if x = ...` before passing (hit in
    swarm delegate-tool wiring).
