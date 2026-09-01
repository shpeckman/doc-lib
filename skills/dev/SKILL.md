---
name: dev
description: Strict mode-based coding assistant behavior (Analysis Mode vs Code Mode) for software development work, with Crystal language support and file-bundle handling. Use whenever the user invokes `//analyze`, `//a`, `//code`, or `//c`, or when doing programming/code tasks where mode-driven behavior is expected. Also use when the user asks to write, run, test, or debug Crystal (.cr) code or use shards (Crystal is NOT preinstalled in the sandbox; this skill installs it without root). Also use when the user provides a file bundle (a Markdown file of fenced code blocks whose fence info strings name each file's path) to be unpacked, or asks to receive project files as a single bundle file. Enforces code quality standards (compiler-friendly, performance-focused, idiomatic, data-driven, no comments), full-file delivery without stubs, and mode stickiness until the user switches commands. Tuned for a Fedora 42 / KDE Plasma / Wayland environment with Crystal 1.21.0.
---

# Dev

Mode-based development assistant. Two modes exist — Analysis Mode and Code Mode — switched by user commands. Always operate in exactly one mode.

## Environment

Target system for all code, commands, and tooling advice:

- Fedora Linux 42
- KDE Plasma on Wayland
- 16 × 12th Gen Intel Core i5-1240P
- 16 GiB RAM (15.3 GiB usable)
- Intel Iris Xe Graphics
- Crystal 1.21.0

## Modes

### Mode Switching

- Default mode at conversation start: **Analysis Mode**
- `//analyze` or `//a` → switch to Analysis Mode
- `//code` or `//c` → switch to Code Mode
- Once a command is used, that mode is retained until a different command is used.
- Begin every message with either `ANALYSIS MODE` or `CODE MODE` to indicate the active mode.

### Analysis Mode

- Do not write code, except small snippets as examples to clarify a point.
- When the user provides code at the start of a conversation, describe what the source code does; do not scrutinize or critique it.

### Code Mode

- Do not add functionality the user did not ask for.
- When writing new files or updating existing files, deliver complete files: no stubs, no placeholders, with all discussed functionality fully implemented.

## Code Standards

Apply these in Code Mode (and to any snippet shown in Analysis Mode):

- Compiler-friendly, performance-focused, and idiomatic.
- Data-driven design.
- No comments in code, with one exception: every file starts with a comment containing the path to that file (e.g. `# src/main.cr`).
- The usage-facing API must be ergonomic.
- Do not cut corners — requested features should be the best they can be.

## Behavior Rules

- Take responsibility for any mistakes made; own and correct them.
- Search online before making factual claims, when online search is available.
- Do not write documentation unless the user explicitly requests it.

## File Bundles

`scripts/project_bundler.py` converts between a directory tree and a single Markdown bundle file. Each file in a bundle is a fenced code block whose info string carries the file's relative path (e.g. ```` ```src/main.py ````). Files that support comments also start with a path comment (e.g. `# src/main.py`) as a fallback and for in-editor orientation; comment-less formats (JSON, etc.) are bundled and restored via the fence path alone. Self-contained; runs on stock Python 3, no dependencies.

Three subcommands:

- `add DIR... [--dry-run] [-v]` — insert or update path comments in source files (idempotent; shebang/encoding-cookie aware; preserves CRLF, BOM, permissions)
- `bundle DIR... [-o bundle.md] [--no-add] [-v]` — stamp files (pre-op `add`, skip with `--no-add`) and pack them into one Markdown file
- `unbundle bundle.md [-o DIR] [--force] [--dry-run] [-v]` — restore files and directory structure from a bundle

### Receiving a bundle from the user

When the user provides a bundle file:

1. Restore it into a working directory: `python3 scripts/project_bundler.py unbundle <bundle> -o <workdir>`
2. Work on the restored files normally.
3. Re-run `unbundle` only against a fresh directory; without `--force` it refuses to overwrite files whose content differs.

### Presenting files to the user as a bundle

When the user asks for project files as one bundle file:

1. From the project root, run: `python3 scripts/project_bundler.py bundle . -o <name>.md` (the pre-op `add` stamps any unstamped files automatically)
2. Deliver the resulting `.md` file.

### Safety properties (do not weaken them)

- `unbundle` resolves each block's destination from the fence path first, falling back to the path comment; both sources get the same checks — rejects absolute paths, `..` traversal, and symlink escapes — never bypass them. Old language-tagged fences (e.g. ```` ```py ````) are not valid paths and fall through to the comment, so old bundles still unbundle.
- Fence width adapts to backticks in file content — do not hand-edit bundle fences.
- After any modification to `project_bundler.py`, run the test suite: `python3 -m pytest scripts/test_file_tools.py -q` (165 tests; must stay green).

## Crystal in this sandbox

### Why Crystal usually fails here (known environment constraints)

1. **Not preinstalled** — Debian 12 image; Crystal is not in apt and there is **no root/sudo**, so the official `install.sh`/apt route is impossible.
2. **Persistent storage cannot execute binaries** — `/mnt/agents` strips exec bits and refuses to run programs (`Permission denied`, exit 126). Never install Crystal there.
3. **Direct GitHub downloads are often ~KB/s** — release tarballs (~58 MB) time out. Use the `gh-proxy.com` mirror (the installer probes speed and falls back automatically).
4. **Non-persistent `$HOME`** — anything installed outside `/mnt/agents` is wiped when the sandbox is released. Re-run the installer at the start of every session that needs Crystal.

Everything else works: `gcc`/`cc`/`ld` are present and the bundled tarball's runtime libs (libgc, pcre2, ssl, yaml, event) link fine.

### Setup (run first, every session)

```bash
python3 <skill-dir>/scripts/install_crystal.py
export PATH="$HOME/crystal/bin:$PATH"
```

The Python installer (stdlib only) is idempotent: skips if `~/crystal/bin/crystal` runs, else downloads the pinned release (default 1.21.0; override with `CRYSTAL_VERSION`), extracts to `$HOME/crystal`, and smoke-tests a real compile. It probes direct-GitHub speed and falls back automatically: gh-proxy.com mirror → openSUSE OBS .deb (it discovers the current package name from the OBS listing and prints the extra `CRYSTAL_PATH`/`CRYSTAL_LIBRARY_PATH` exports the deb layout needs). Downloads resume partial files across retries, archives are magic-byte validated, and it refuses to install onto `/mnt/agents` (noexec). It prints the PATH line(s) on success — run it and export what it prints.

### Multi-agent / subagent sessions (verified 2026-08-11)

- **Subagents get fresh container views.** A spawned subagent does NOT see the main agent's `~/crystal` install or exported PATH. Any subagent that must compile or spec Crystal must run `install_crystal.py` itself — put the exact install command into the subagent prompt, don't assume inheritance.
- **Never share an install via `/mnt/agents`.** Copying the tree there fails: symlinks are rejected (`Operation not supported`), large copies die with I/O errors, and the mount is noexec anyway.
- **`$HOME` can be wiped mid-session** (observed: `crystal: command not found` after earlier success in the same session). If `crystal` suddenly vanishes, re-run the installer — it is idempotent.

### Fallback install route: openSUSE OBS .deb

The installer already includes this as its last-resort route (no `dpkg` needed — it parses the ar archive itself). The deb's binaries are fully static. Gotcha: the deb puts `libgc.a` directly in `usr/lib/crystal`, **not** in a `lib/` subdir — the installer detects this layout and prints the `CRYSTAL_LIBRARY_PATH`/`CRYSTAL_PATH` exports required, without which linking fails with `cannot find -lgc`.

### Usage

- Run: `crystal run file.cr` (compiles + runs)
- One-liner: `crystal eval 'puts 1 + 1'`
- Binary: `crystal build file.cr -o app` (add `--release` for optimized; build in `$HOME` or `/tmp`, not `/mnt/agents`)
- Deps: `shards install` works; GitHub fetching may be slow — vendor dependencies or expect delays
- Compiler cache defaults to `~/.cache/crystal` — fine; do not point it at `/mnt/agents`

Deliver `.cr` sources to `/mnt/agents/output/` normally (they are data, not executables), but always compile/run from `$HOME` or `/tmp`.

### Writing Crystal code

When authoring or debugging Crystal (especially FFI `lib` bindings, union types, macros), first read `references/crystal-pitfalls.md` — a verified list of compile/runtime gotchas hit in this sandbox (Crystal 1.21.0), e.g. bare `Int` rejected in `lib fun` signatures, `UInt8 == Char` silently always false, `yield` illegal inside captured blocks.

Before delivering any `.cr` file, run the preflight linter and fix what it reports:

```bash
python3 <skill-dir>/scripts/crystal_preflight.py --fix FILE.cr...
```

It detects 13 of the documented pitfalls (rule numbers match the pitfall list) and auto-fixes the safe ones: abstract numerics in `lib fun` signatures and union type declarations, `.pointer.closure`, `Time.monotonic`, trailing `while`/`until` modifiers, and `raise ..., cause:`. Warn-only findings (silent `UInt8 == Char`, assignment in `when`, `yield` in captured blocks, macro tags in comments, `@type.instance_vars` at include time, `BigFloat#to_s(precision)`, `IO.select` timeouts) need manual restructuring — see the referenced pitfall entry.
