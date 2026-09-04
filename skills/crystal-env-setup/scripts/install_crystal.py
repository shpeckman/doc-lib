#!/usr/bin/env python3
"""Install the Crystal language toolchain (Linux x86_64, bundled tarball).

Downloads the official Crystal release via the gh-proxy.com mirror (falls back
to direct GitHub on failure), extracts it, and verifies `crystal` and `shards`.

Examples:
    python3 install_crystal.py                      # Crystal 1.21.0 -> /tmp/crystal
    python3 install_crystal.py --version 1.16.3
    python3 install_crystal.py --dir /opt/crystal
    python3 install_crystal.py --no-mirror          # direct from github.com
"""

import argparse
import os
import subprocess
import sys

MIRROR = "https://gh-proxy.com/"
DEFAULT_VERSION = "1.21.0"
DEFAULT_BUILD = "1"
DEFAULT_DIR = "/tmp/crystal"


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def download(url: str, dest: str) -> bool:
    print(f"Downloading {url}")
    r = sh(["curl", "-sL", "--fail", "-o", dest, url])
    ok = r.returncode == 0 and os.path.getsize(dest) > 1_000_000
    if not ok:
        print(f"  download failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
    return ok


def main() -> int:
    p = argparse.ArgumentParser(description="Install the Crystal toolchain.")
    p.add_argument("--version", default=DEFAULT_VERSION, help=f"Crystal version (default: {DEFAULT_VERSION})")
    p.add_argument("--build", default=DEFAULT_BUILD, help=f"Release build number (default: {DEFAULT_BUILD})")
    p.add_argument("--dir", default=DEFAULT_DIR, help=f"Install root (default: {DEFAULT_DIR})")
    p.add_argument("--mirror", default=MIRROR, help=f"Mirror prefix (default: {MIRROR})")
    p.add_argument("--no-mirror", action="store_true", help="Download directly from github.com")
    a = p.parse_args()

    base = f"crystal-{a.version}-{a.build}"
    install_root = os.path.abspath(a.dir)
    bin_dir = os.path.join(install_root, base, "bin")
    crystal = os.path.join(bin_dir, "crystal")

    # Idempotent: reuse an existing install.
    if os.path.exists(crystal):
        out = sh([crystal, "--version"]).stdout.splitlines()
        print(f"Already installed: {out[0] if out else base}")
        print(f"Add to PATH: export PATH=\"{bin_dir}:$PATH\"")
        return 0

    os.makedirs(install_root, exist_ok=True)
    tarball = os.path.join(install_root, f"{base}.tar.gz")
    direct = (
        f"https://github.com/crystal-lang/crystal/releases/download/"
        f"{a.version}/{base}-linux-x86_64-bundled.tar.gz"
    )
    urls = [direct] if a.no_mirror else [a.mirror + direct, direct]

    for url in urls:
        if download(url, tarball):
            break
    else:
        print("ERROR: all download attempts failed.", file=sys.stderr)
        return 1

    print(f"Extracting to {install_root}")
    r = sh(["tar", "xzf", tarball, "-C", install_root])
    if r.returncode != 0:
        print(f"ERROR: extraction failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
        return 1
    os.remove(tarball)

    for tool in ("crystal", "shards"):
        path = os.path.join(bin_dir, tool)
        r = sh([path, "--version"])
        if r.returncode != 0:
            print(f"ERROR: {tool} failed to run: {r.stderr.strip()[-300:]}", file=sys.stderr)
            return 1
        print(r.stdout.splitlines()[0])

    print(f"\nInstalled at: {os.path.join(install_root, base)}")
    print(f"Add to PATH: export PATH=\"{bin_dir}:$PATH\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
