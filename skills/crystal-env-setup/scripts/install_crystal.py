#!/usr/bin/env python3
"""Install the Crystal language toolchain (Linux x86_64, bundled tarball).

Downloads the official Crystal release via the gh-proxy.com mirror (falls back
to direct GitHub on failure), extracts it, and verifies `crystal` and `shards`.

Persistence across session wipes: /tmp is wiped when a session ends, and the
persistent mount /mnt/agents does not support executing binaries. The installer
therefore caches the downloaded tarball under /mnt/agents (persistent) and
extracts to /tmp (exec-capable). After a wipe, re-running the installer
restores the toolchain from the cache in seconds — no network needed.

Examples:
    python3 install_crystal.py                      # Crystal 1.21.0 -> /tmp/crystal (cached)
    python3 install_crystal.py --version 1.16.3
    python3 install_crystal.py --dir /opt/crystal
    python3 install_crystal.py --no-mirror          # direct from github.com
    python3 install_crystal.py --no-cache           # old behavior: download, no persistent cache
"""

import argparse
import os
import shutil
import subprocess
import sys

MIRROR = "https://gh-proxy.com/"
DEFAULT_VERSION = "1.21.0"
DEFAULT_BUILD = "1"
DEFAULT_DIR = "/tmp/crystal"
DEFAULT_CACHE_DIR = "/mnt/agents/crystal-cache"


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def download(url: str, dest: str) -> bool:
    print(f"Downloading {url}")
    r = sh(["curl", "-sL", "--fail", "-o", dest, url])
    ok = r.returncode == 0 and os.path.exists(dest) and os.path.getsize(dest) > 1_000_000
    if not ok:
        print(f"  download failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
    return ok


def verify(bin_dir: str) -> bool:
    """Check that crystal and shards actually run; print their versions."""
    for tool in ("crystal", "shards"):
        r = sh([os.path.join(bin_dir, tool), "--version"])
        if r.returncode != 0:
            print(f"ERROR: {tool} failed to run: {r.stderr.strip()[-300:]}", file=sys.stderr)
            return False
        print(r.stdout.splitlines()[0])
    return True


def extract(tarball: str, install_root: str) -> bool:
    print(f"Extracting to {install_root}")
    r = sh(["tar", "xzf", tarball, "-C", install_root])
    if r.returncode != 0:
        print(f"ERROR: extraction failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
        return False
    return True


def main() -> int:
    p = argparse.ArgumentParser(description="Install the Crystal toolchain.")
    p.add_argument("--version", default=DEFAULT_VERSION, help=f"Crystal version (default: {DEFAULT_VERSION})")
    p.add_argument("--build", default=DEFAULT_BUILD, help=f"Release build number (default: {DEFAULT_BUILD})")
    p.add_argument("--dir", default=DEFAULT_DIR, help=f"Install root (default: {DEFAULT_DIR})")
    p.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR,
                   help=f"Persistent tarball cache (default: {DEFAULT_CACHE_DIR})")
    p.add_argument("--no-cache", action="store_true", help="Do not keep a persistent cached tarball")
    p.add_argument("--mirror", default=MIRROR, help=f"Mirror prefix (default: {MIRROR})")
    p.add_argument("--no-mirror", action="store_true", help="Download directly from github.com")
    a = p.parse_args()

    base = f"crystal-{a.version}-{a.build}"
    install_root = os.path.abspath(a.dir)
    bin_dir = os.path.join(install_root, base, "bin")
    crystal = os.path.join(bin_dir, "crystal")

    # Idempotent: reuse an existing install (same session).
    if os.path.exists(crystal):
        out = sh([crystal, "--version"]).stdout.splitlines()
        print(f"Already installed: {out[0] if out else base}")
        print(f"Add to PATH: export PATH=\"{bin_dir}:$PATH\"")
        return 0

    os.makedirs(install_root, exist_ok=True)
    tarball_name = f"{base}-linux-x86_64-bundled.tar.gz"
    cached = os.path.join(a.cache_dir, tarball_name)

    # Restore from the persistent cache (survives session wipes, no network).
    if not a.no_cache and os.path.exists(cached):
        print(f"Restoring from cache: {cached}")
        if extract(cached, install_root) and verify(bin_dir):
            print(f"\nInstalled at: {os.path.join(install_root, base)}")
            print(f"Add to PATH: export PATH=\"{bin_dir}:$PATH\"")
            return 0
        print("Cached tarball is unusable; removing it and downloading fresh.", file=sys.stderr)
        os.remove(cached)
        shutil.rmtree(os.path.join(install_root, base), ignore_errors=True)

    # Download (to the cache location unless --no-cache).
    dest = cached if not a.no_cache else os.path.join(install_root, tarball_name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    direct = (
        f"https://github.com/crystal-lang/crystal/releases/download/"
        f"{a.version}/{tarball_name}"
    )
    urls = [direct] if a.no_mirror else [a.mirror + direct, direct]

    for url in urls:
        if download(url, dest):
            break
    else:
        print("ERROR: all download attempts failed.", file=sys.stderr)
        return 1

    if not extract(dest, install_root):
        return 1
    if a.no_cache:
        os.remove(dest)

    if not verify(bin_dir):
        return 1

    print(f"\nInstalled at: {os.path.join(install_root, base)}")
    if not a.no_cache:
        print(f"Cached at:   {dest} (survives session wipes; re-run this script to restore)")
    print(f"Add to PATH: export PATH=\"{bin_dir}:$PATH\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
