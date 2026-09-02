#!/usr/bin/env python3
# scripts/install_crystal.py
"""Idempotent Crystal installer for sandboxes without root.

Installs into CRYSTAL_HOME (defaults to $HOME/crystal). When the target is on a
noexec mount such as /mnt/agents, wrapper scripts are auto-patched to use the
dynamic linker so Crystal remains usable across sessions.
Download routes tried in order: direct GitHub (if the probe is fast),
gh-proxy.com mirror, openSUSE OBS .deb (fully static binaries).
Stdlib only. Run: python3 scripts/install_crystal.py
"""
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

VERSION = os.environ.get("CRYSTAL_VERSION", "1.21.0")
HOME = os.path.expanduser("~")
PREFIX = os.environ.get("CRYSTAL_HOME", os.path.join(HOME, "crystal"))
TARBALL = f"crystal-{VERSION}-1-linux-x86_64-bundled.tar.gz"
GH_URL = f"https://github.com/crystal-lang/crystal/releases/download/{VERSION}/{TARBALL}"
PROXY_URL = f"https://gh-proxy.com/{GH_URL}"
_mm = ".".join(VERSION.split(".")[:2])
OBS_DIR = ("https://download.opensuse.org/repositories/devel:/languages:/crystal/"
           "Debian_12/amd64/")
MIN_SPEED = 1_000_000  # B/s; below this, prefer the proxy


def log(msg):
    print(f"[install_crystal] {msg}", flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def crystal_bin():
    return os.path.join(PREFIX, "bin", "crystal")


def installed_ok():
    """True only if the binary exists AND runs (guards against half-wiped installs)."""
    try:
        r = run(crystal_cmd(["--version"]), timeout=30)
        return r.returncode == 0 and "Crystal" in r.stdout
    except OSError:
        return False


def executable_dir(path):
    """True if binaries created under path can actually execute (noexec check)."""
    try:
        fd, probe = tempfile.mkstemp(dir=path, prefix=".exec_probe")
        os.write(fd, b"#!/bin/sh\nexit 0\n")
        os.close(fd)
        os.chmod(probe, stat.S_IRWXU)
        ok = run([probe], timeout=5).returncode == 0
        os.unlink(probe)
        return ok
    except OSError:
        return False


def crystal_cmd(args):
    """Return the command list to invoke crystal, handling noexec mounts."""
    if executable_dir(os.path.dirname(crystal_bin())):
        return [crystal_bin()] + args
    # noexec mount — run the wrapper script via bash so the kernel never
    # tries to execute anything directly from the mount.
    return ["bash", crystal_bin()] + args


def fetch(url, dest=None, probe_secs=0, tries=3):
    """Download url to dest, resuming partial files across retries. With
    probe_secs, measure speed for that long and return bytes/sec instead.
    Returns bytes downloaded, or -1 on failure."""
    for attempt in range(tries):
        try:
            headers = {"User-Agent": "curl/8"}
            got = 0
            if dest and not probe_secs and os.path.exists(dest):
                got = os.path.getsize(dest)
                if got:
                    headers["Range"] = f"bytes={got}-"
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as r:
                if probe_secs:
                    start, n = time.monotonic(), 0
                    while time.monotonic() - start < probe_secs:
                        chunk = r.read(1 << 16)
                        if not chunk:
                            break
                        n += len(chunk)
                    return int(n / max(time.monotonic() - start, 0.01))
                if got and r.status != 206:  # server ignored Range: restart
                    got = 0
                with open(dest, "ab" if got else "wb") as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
            return os.path.getsize(dest)
        except Exception as e:
            log(f"download attempt {attempt + 1} failed ({url.split('/')[2]}): {e}")
    return -1


def obs_deb_url():
    """Find the newest crystal<major.minor> .deb on OBS (build suffixes change)."""
    import re
    req = urllib.request.Request(OBS_DIR, headers={"User-Agent": "curl/8"})
    html = urllib.request.urlopen(req, timeout=30).read().decode()
    debs = re.findall(rf'crystal{re.escape(_mm)}_([^"/]+)_amd64\.deb', html)
    if not debs:
        raise RuntimeError(f"no crystal{_mm} deb found on OBS")
    return OBS_DIR + f"crystal{_mm}_{sorted(debs)[-1]}_amd64.deb"


def install_tarball(path):
    tmp = os.path.dirname(path)
    with tarfile.open(path) as t:
        t.extractall(tmp, filter="data")
    # Top-level dir is crystal-<version>-1, but member names may start with
    # './' — locate it on disk instead of trusting the first member name.
    top = next(d for d in os.listdir(tmp)
               if d.startswith("crystal-") and os.path.isdir(os.path.join(tmp, d)))
    if os.path.isdir(PREFIX):
        shutil.rmtree(PREFIX)
    shutil.copytree(os.path.join(tmp, top), PREFIX, symlinks=True)


def ar_extract(deb, outdir):
    """Pure-python ar parser: pull data.tar.* out of a .deb (no dpkg needed)."""
    data = open(deb, "rb").read()
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    off = 8
    while off + 60 <= len(data):
        name, size = data[off:off + 16].decode().strip(), int(data[off + 48:off + 58])
        if name.startswith("data.tar"):
            p = os.path.join(outdir, name.replace("/", "_"))
            open(p, "wb").write(data[off + 60:off + 60 + size])
            return p
        off += 60 + size + (size % 2)
    raise RuntimeError("no data.tar in .deb")


def install_deb(path):
    tmp = os.path.dirname(path)
    if shutil.which("dpkg-deb"):
        r = run(["dpkg-deb", "-x", path, tmp])
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip())
    else:
        with tarfile.open(ar_extract(path, tmp)) as t:
            t.extractall(tmp, filter="data")
    if os.path.isdir(PREFIX):
        shutil.rmtree(PREFIX)
    shutil.copytree(os.path.join(tmp, "usr"), PREFIX)
    # OBS deb puts libgc.a directly in usr/lib/crystal, NOT lib/ — linking fails
    # with 'cannot find -lgc' unless these are exported for the session.
    os.environ["CRYSTAL_PATH"] = os.path.join(PREFIX, "share", "crystal", "src")
    os.environ["CRYSTAL_LIBRARY_PATH"] = os.path.join(PREFIX, "lib", "crystal")


def patch_noexec_wrappers(prefix):
    """Patch crystal/shards shell wrappers to invoke the real ELF binary via
    ld-linux, so they work on noexec mounts like /mnt/agents."""
    ld_linux = "/lib64/ld-linux-x86-64.so.2"
    if not os.path.exists(ld_linux):
        return  # Not available on this system; leave wrappers untouched

    for script_name in ("crystal", "shards"):
        path = os.path.join(prefix, "bin", script_name)
        if not os.path.exists(path):
            continue
        with open(path, "r") as f:
            content = f.read()

        # Only patch shell scripts that haven't been patched yet
        if "#!/bin/" not in content or "ld-linux" in content:
            continue

        lines = content.splitlines()
        new_lines = []
        patched = False
        for line in lines:
            # Match the exec line that launches the actual compiler binary
            if not patched and re.match(
                r'^\s*exec\s+"[^"]*bin/' + script_name + r'".*$', line
            ):
                # Insert ld-linux before the binary path
                new_line = re.sub(
                    r'^(\s*exec\s+)("[^"]*bin/' + script_name + r'".*)$',
                    rf'\1{ld_linux} \2',
                    line
                )
                new_lines.append(new_line)
                patched = True
            else:
                new_lines.append(line)

        if patched:
            with open(path, "w") as f:
                f.write("\n".join(new_lines) + "\n")
            log(f"Patched {script_name} wrapper for noexec mount")


def smoke_test():
    """Compile+run a real program — catches missing linker/libs immediately."""
    src = os.path.join(tempfile.gettempdir(), ".crystal_smoke.cr")
    with open(src, "w") as f:
        f.write('puts "crystal ok #{Crystal::VERSION}"\n')
    env = dict(os.environ, PATH=f"{os.path.dirname(crystal_bin())}:{os.environ['PATH']}")
    try:
        r = run(crystal_cmd(["run", src]), timeout=300, env=env)
    finally:
        os.unlink(src)
    if r.returncode != 0 or "crystal ok" not in r.stdout:
        raise RuntimeError(f"smoke test failed:\n{r.stdout}{r.stderr}")
    log(r.stdout.strip())


def main():
    if installed_ok():
        log(f"already installed at {PREFIX}")
    else:
        if not executable_dir(HOME):
            log(f"WARNING: {HOME} cannot execute binaries — install target may be noexec")
        if os.path.abspath(PREFIX).startswith("/mnt/agents"):
            log("WARNING: CRYSTAL_HOME is on /mnt/agents (noexec) — will patch wrappers after install")
        speed = fetch(GH_URL, probe_secs=10)
        fast = 0 < speed >= MIN_SPEED
        log(f"github probe: {speed} B/s -> {'direct' if fast else 'fallbacks'}")
        routes = ([(GH_URL, "tarball")] if fast else []) + [(PROXY_URL, "tarball")]
        try:
            routes.append((obs_deb_url(), "deb"))
        except Exception as e:
            log(f"OBS listing failed: {e}")
        tmp = tempfile.mkdtemp()
        try:
            for url, kind in routes:
                dest = os.path.join(tmp, TARBALL if kind == "tarball" else "crystal.deb")
                if os.path.exists(dest):
                    os.unlink(dest)  # stale partial from a previous route
                log(f"downloading {url}")
                if fetch(url, dest) <= 0:
                    continue
                magic = open(dest, "rb").read(8)
                want = b"\x1f\x8b" if kind == "tarball" else b"!<arch>\n"
                if not magic.startswith(want):
                    log("downloaded file is not a valid archive — trying next route")
                    continue
                (install_tarball if kind == "tarball" else install_deb)(dest)
                break
            else:
                log("FATAL: all download routes failed")
                return 1
            patch_noexec_wrappers(PREFIX)
            smoke_test()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    # OBS deb layout keeps libgc.a in lib/crystal (not lib/) — such an install
    # needs these exported every session or linking fails with 'cannot find -lgc'.
    lib_gc = os.path.join(PREFIX, "lib", "crystal", "libgc.a")
    if os.path.exists(lib_gc) and not os.path.isdir(os.path.join(PREFIX, "lib", "crystal", "lib")):
        print(f'export CRYSTAL_PATH="{os.path.join(PREFIX, "share", "crystal", "src")}"')
        print(f'export CRYSTAL_LIBRARY_PATH="{os.path.join(PREFIX, "lib", "crystal")}"')
    print(f'export PATH="{os.path.dirname(crystal_bin())}:$PATH"')
    if os.path.abspath(PREFIX).startswith("/mnt/agents"):
        print(f'# NOTE: {PREFIX} is on a noexec mount. Use: bash {crystal_bin()} ...')
    return 0


if __name__ == "__main__":
    sys.exit(main())
