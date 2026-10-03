---
name: dev
description: Crystal language development workflow with Analysis/Code modes, a bundled toolchain installer, a fast GitHub clone tool, and a failure knowledge base (klog) for logging, searching, and curating recurring errors. Use when the user is writing, discussing, or asking about Crystal code (.cr files, shards, shard.yml), when the user invokes mode commands like //analyze, //a, //code, or //c, when the Crystal toolchain (crystal/shards) needs to be installed or restored in the environment, when a GitHub repository needs to be cloned quickly (shallow, mirrored), or when a compile/spec/toolchain failure should be looked up in or recorded into the known-problems database.
---

# Dev

Crystal development assistant operating in two modes with strict code standards.

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
- Do not update version number in shard.yml

## Code Standards

Apply these in Code Mode (and to any snippet shown in Analysis Mode):

- Compiler-friendly, performance-focused, and idiomatic.
- Data-driven design.
- No comments in code, with one exception: every file starts with a comment containing the path to that file (e.g. `# src/main.cr`).
- The usage-facing API must be ergonomic.
- Never touch the `version` field in `shard.yml`.
- Prevent "shotgun surgery"

## Documentation

Maintain two files at the project root; keep them in sync as the code changes:

- `README.md` — usage and the public-facing API.
- `AGENTS.md` — orientation for AI agents working on the project: repository layout, build/test/spec commands, and the code standards from this skill.

## Behavior Rules

- Always write in English: every reply, explanation, and deliverable must be written in English, regardless of the language the user writes in.
- Take responsibility for any mistakes made; own and correct them.
- Search online before making factual claims, when online search is available.

## User Machine

The user's local development machine (distinct from the sandbox):

- OS: Fedora Linux 42, kernel 6.19.14-108.fc42.x86_64 (64-bit)
- Desktop: KDE Plasma 6.5.5, KDE Frameworks 6.22.0, Qt 6.9.3, Wayland
- Hardware: Lenovo ThinkPad X13 Gen 3 (21BN001CMB), 16 × 12th Gen Intel Core i5-1240P, 16 GiB RAM (15.3 GiB usable), Intel Iris Xe Graphics
- Crystal: 1.21.0

## Toolchain Installation

When `crystal` or `shards` is missing from the environment, run:

```bash
python3 scripts/install_crystal.py
```

The script downloads the Crystal bundled tarball (Linux x86_64), verifies `crystal` and `shards`, and prints the PATH export to use. It caches the tarball so re-runs after a session wipe restore quickly. Useful flags: `--version`, `--dir`, `--no-cache`, `--no-mirror` (see `--help`).

## Fast GitHub Clone

When cloning a GitHub repository, run:

```bash
python3 scripts/gh_clone.py owner/repo [dest]
```

The script performs a shallow (`--depth 1`), single-branch clone through the `gh-proxy.com` mirror, falling back to direct github.com on failure. Accepts `owner/repo`, HTTPS, and SSH (`git@github.com:...`) specs. Useful flags: `--branch`, `--depth`, `--full` (complete history), `--no-mirror` (see `--help`).

## Failure Knowledge Base

Recurring failures are captured, curated, and searched with `scripts/klog.py`. The curated database lives in `references/failure-db/<category>.txt` — one `ID (×n) | symptom | cause | fix` entry per line; it is read-only in-session. The session scratch log (raw captures + new entries + overlays) lives in `/mnt/agents/failure-log/`.

Protocol:

- Route shell commands through the runner, especially build/spec/toolchain ones: `python3 scripts/klog.py run crystal build ...` (or one quoted string for compound commands). Output streams through unchanged and the exit code is preserved; failures and warnings are captured into the scratch inbox automatically.
- When any compile/spec/toolchain error appears, run `python3 scripts/klog.py grep <token>` before diagnosing from scratch.
- Curate failures with reuse value (language quirks, environment traps — not typos): `klog.py promote <n> --cat <category> --cause "..." [--fix "..."]` for inbox captures, `klog.py add` otherwise.
- The moment a fix is found, record it with `klog.py fix <ID> --fix "..."`. Recurrence of a known problem: `klog.py bump <ID>`.
- Session wrap-up (or when the user asks): `klog.py export --dry-run`, review, then `klog.py export`; resolve anything in `klog.py pending`; copy the exported files into a skill working copy, fold ×3+ entries into a Known Traps list below, and repackage the skill (see SB-004).

Commands: `run`, `add`, `promote`, `fix`, `bump`, `grep [--inbox]`, `pending`, `brief`, `export [--dry-run] [--out DIR]` — details via `python3 scripts/klog.py <cmd> --help`. Locations overridable via `KLOG_SCRATCH` / `KLOG_DB`.

### Known Traps

Entries that recur across sessions (×3+) — apply proactively, don't rediscover:

- `out` is a reserved keyword; never use it as an identifier (CQ-001).
