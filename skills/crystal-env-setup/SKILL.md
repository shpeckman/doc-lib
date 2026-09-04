---
name: crystal-env-setup
description: Set up a Crystal language development environment and clone GitHub repositories through the gh-proxy.com fast mirror. Use when the user needs to install the Crystal toolchain (crystal compiler, shards), compile or run Crystal code, build Crystal projects or shards dependencies, or clone GitHub repos quickly — especially when direct github.com access is slow or unreliable. Provides tested scripts install_crystal.py and clone_gh_repo.py.
---

# Crystal Env Setup

Fast setup for Crystal development: install the toolchain and clone GitHub repos via the `gh-proxy.com` mirror (with automatic fallback to direct github.com).

## Install the Crystal toolchain

```bash
python3 scripts/install_crystal.py                 # Crystal 1.21.0 -> /tmp/crystal
python3 scripts/install_crystal.py --version 1.16.3
python3 scripts/install_crystal.py --dir /opt/crystal
python3 scripts/install_crystal.py --no-mirror     # skip mirror, direct download
```

- Downloads the official `linux-x86_64-bundled` release tarball (bundled = includes `shards` and required static libs), extracts it, and verifies `crystal --version` and `shards --version`.
- Idempotent: re-running with the same version/dir reuses the existing install.
- On completion it prints the exact `export PATH="...:$PATH"` line — run it before invoking `crystal`/`shards` in later shell commands, or call the binaries by absolute path.
- `/tmp` (the default) is wiped between sessions; reinstalling is fast, or pass a persistent `--dir` if the filesystem allows exec.
- Crystal needs a C linker at compile time; if linking fails, install build tools (e.g. `apt-get install -y build-essential libpcre2-dev libgc-dev`).

## Clone a GitHub repo via the mirror

```bash
python3 scripts/clone_gh_repo.py shpeckman/unicode_grapheme --dest /tmp
python3 scripts/clone_gh_repo.py https://github.com/owner/repo --dest /tmp
python3 scripts/clone_gh_repo.py owner/repo --branch main --depth 1
python3 scripts/clone_gh_repo.py owner/repo --no-mirror
```

- Accepts `owner/name`, HTTPS, or SSH-style GitHub URLs.
- Clones through `gh-proxy.com`; on failure retries the canonical github.com URL automatically.
- After cloning, resets `origin` to the canonical `https://github.com/...` URL, so later `git fetch`/`push` go straight to GitHub — no further mirror handling needed.
- Prints the repo path and latest commits on success.

## Typical workflow

```bash
python3 scripts/install_crystal.py
export PATH="/tmp/crystal/crystal-1.21.0-1/bin:$PATH"   # use the line the installer prints
python3 scripts/clone_gh_repo.py owner/some-crystal-lib --dest /tmp
cd /tmp/some-crystal-lib && shards install && crystal spec
```
