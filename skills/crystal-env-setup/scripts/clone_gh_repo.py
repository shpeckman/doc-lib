#!/usr/bin/env python3
"""Clone a GitHub repository via the gh-proxy.com mirror.

Clones through the fast mirror (falls back to direct github.com on failure),
then resets `origin` to the canonical GitHub URL so later fetch/push work
normally.

Examples:
    python3 clone_gh_repo.py shpeckman/unicode_grapheme
    python3 clone_gh_repo.py https://github.com/crystal-lang/shards --dest /tmp
    python3 clone_gh_repo.py owner/repo --branch main --depth 1
    python3 clone_gh_repo.py owner/repo --no-mirror
"""

import argparse
import os
import re
import subprocess
import sys

MIRROR = "https://gh-proxy.com/"


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def canonical_url(repo: str) -> str:
    """Normalize owner/name, SSH, or HTTPS forms to a canonical HTTPS URL."""
    repo = repo.strip().removesuffix(".git").rstrip("/")
    m = re.match(r"^(?:git@github\.com:|https?://github\.com/)?([\w.-]+/[\w.-]+)$", repo)
    if not m:
        sys.exit(f"ERROR: cannot parse repo '{repo}'. Use owner/name or a GitHub URL.")
    return f"https://github.com/{m.group(1)}.git"


def clone(url: str, args: argparse.Namespace, dest_dir: str) -> bool:
    cmd = ["git", "clone", "--progress"]
    if args.branch:
        cmd += ["--branch", args.branch]
    if args.depth:
        cmd += ["--depth", str(args.depth)]
    cmd += [url]
    print(f"Cloning {url} -> {dest_dir}")
    r = subprocess.run(cmd, cwd=dest_dir, text=True, capture_output=True)
    if r.returncode != 0:
        print(f"  clone failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
        return False
    return True


def main() -> int:
    p = argparse.ArgumentParser(description="Clone a GitHub repo via the gh-proxy.com mirror.")
    p.add_argument("repo", help="owner/name, SSH, or HTTPS GitHub URL")
    p.add_argument("--dest", default=".", help="Parent directory for the clone (default: cwd)")
    p.add_argument("--branch", help="Branch or tag to check out")
    p.add_argument("--depth", type=int, help="Shallow clone depth (e.g. 1)")
    p.add_argument("--mirror", default=MIRROR, help=f"Mirror prefix (default: {MIRROR})")
    p.add_argument("--no-mirror", action="store_true", help="Clone directly from github.com")
    a = p.parse_args()

    url = canonical_url(a.repo)
    name = url.rsplit("/", 1)[-1].removesuffix(".git")
    dest_dir = os.path.abspath(a.dest)
    repo_dir = os.path.join(dest_dir, name)

    if os.path.isdir(os.path.join(repo_dir, ".git")):
        print(f"Already cloned: {repo_dir}")
    else:
        os.makedirs(dest_dir, exist_ok=True)
        attempts = [url] if a.no_mirror else [a.mirror + url, url]
        for u in attempts:
            if clone(u, a, dest_dir):
                break
        else:
            print("ERROR: all clone attempts failed.", file=sys.stderr)
            return 1

    # Restore origin to the canonical URL so future fetch/push bypass the mirror.
    r = sh(["git", "-C", repo_dir, "remote", "set-url", "origin", url])
    if r.returncode != 0:
        print(f"WARNING: could not reset origin: {r.stderr.strip()[-200:]}", file=sys.stderr)

    log = sh(["git", "-C", repo_dir, "log", "--oneline", "-3"]).stdout.strip()
    print(f"\nRepo ready at: {repo_dir}")
    print(f"Origin: {url}")
    if log:
        print(f"Latest commits:\n{log}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
