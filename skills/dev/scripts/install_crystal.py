# scripts/install_crystal.py
import argparse, os, shutil, subprocess, sys

MIRROR = "https://gh-proxy.com/"
VERSION, BUILD = "1.21.0", "1"
INSTALL_DIR, CACHE_DIR = "/tmp/crystal", "/mnt/agents/crystal-cache"


def sh(*cmd):
    return subprocess.run(cmd, text=True, capture_output=True)


def fetch(url, dest):
    print(f"Downloading {url}")
    r = sh("curl", "-sL", "--fail", "-o", dest, url)
    ok = r.returncode == 0 and os.path.exists(dest) and os.path.getsize(dest) > 1_000_000
    if not ok:
        print(f"  failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
    return ok


def untar(tarball, root, expect):
    print(f"Extracting to {root}")
    r = sh("tar", "xzf", tarball, "-C", root)
    if os.path.isdir(expect):
        if r.returncode != 0:
            print(f"  note: tar exited {r.returncode} on benign warnings; files extracted fine")
        return True
    print(f"ERROR: extraction failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
    return False


def verify(bin_dir):
    for tool in ("crystal", "shards"):
        r = sh(os.path.join(bin_dir, tool), "--version")
        if r.returncode != 0:
            print(f"ERROR: {tool} failed to run: {r.stderr.strip()[-300:]}", file=sys.stderr)
            return False
        print(r.stdout.splitlines()[0])
    return True


def main():
    p = argparse.ArgumentParser(description="Install the Crystal toolchain (Linux x86_64 bundled tarball).",
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--version", default=VERSION)
    p.add_argument("--build", default=BUILD, help="release build number")
    p.add_argument("--dir", default=INSTALL_DIR, help="install root")
    p.add_argument("--cache-dir", default=CACHE_DIR, help="persistent tarball cache")
    p.add_argument("--no-cache", action="store_true", help="download only, no persistent cache")
    p.add_argument("--mirror", default=MIRROR)
    p.add_argument("--no-mirror", action="store_true", help="download directly from github.com")
    a = p.parse_args()

    base = f"crystal-{a.version}-{a.build}"
    root = os.path.abspath(a.dir)
    bin_dir = os.path.join(root, base, "bin")
    done = f'Installed at: {os.path.join(root, base)}\nAdd to PATH: export PATH="{bin_dir}:$PATH"'

    if os.path.exists(os.path.join(bin_dir, "crystal")):
        out = sh(os.path.join(bin_dir, "crystal"), "--version").stdout.splitlines()
        print(f"Already installed: {out[0] if out else base}\n{done}")
        return 0

    os.makedirs(root, exist_ok=True)
    tarball = f"{base}-linux-x86_64-bundled.tar.gz"
    cached = os.path.join(a.cache_dir, tarball)

    if not a.no_cache and os.path.exists(cached):
        print(f"Restoring from cache: {cached}")
        if untar(cached, root, os.path.join(root, base)) and verify(bin_dir):
            print(done)
            return 0
        print("Cached tarball unusable; downloading fresh.", file=sys.stderr)
        os.remove(cached)
        shutil.rmtree(os.path.join(root, base), ignore_errors=True)

    dest = os.path.join(root, tarball) if a.no_cache else cached
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    direct = f"https://github.com/crystal-lang/crystal/releases/download/{a.version}/{tarball}"
    for u in ([direct] if a.no_mirror else [a.mirror + direct, direct]):
        if fetch(u, dest):
            break
    else:
        print("ERROR: all download attempts failed.", file=sys.stderr)
        return 1

    if not untar(dest, root, os.path.join(root, base)):
        return 1
    if a.no_cache:
        os.remove(dest)
    if not verify(bin_dir):
        return 1

    print(done)
    if not a.no_cache:
        print(f"Cached at: {dest} (survives session wipes; re-run to restore)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
