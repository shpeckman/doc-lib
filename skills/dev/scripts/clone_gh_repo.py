# scripts/clone_gh_repo.py
import argparse, os, re, subprocess, sys

MIRROR = "https://gh-proxy.com/"


def sh(*cmd):
    return subprocess.run(cmd, text=True, capture_output=True)


def canonical_url(repo):
    m = re.match(r"^(?:git@github\.com:|https?://github\.com/)?([\w.-]+/[\w.-]+)$",
                 repo.strip().removesuffix(".git").rstrip("/"))
    if not m:
        sys.exit(f"ERROR: cannot parse repo '{repo}'. Use owner/name or a GitHub URL.")
    return f"https://github.com/{m.group(1)}.git"


def main():
    p = argparse.ArgumentParser(description="Clone a GitHub repo via the gh-proxy.com mirror.",
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("repo", help="owner/name, SSH, or HTTPS GitHub URL")
    p.add_argument("--dest", default=".", help="parent directory for the clone")
    p.add_argument("--branch", help="branch or tag to check out")
    p.add_argument("--depth", type=int, help="shallow clone depth")
    p.add_argument("--mirror", default=MIRROR)
    p.add_argument("--no-mirror", action="store_true", help="clone directly from github.com")
    a = p.parse_args()

    url = canonical_url(a.repo)
    dest = os.path.abspath(a.dest)
    repo_dir = os.path.join(dest, url.rsplit("/", 1)[-1].removesuffix(".git"))

    cmd = ["git", "clone", "--progress"]
    if a.branch:
        cmd += ["--branch", a.branch]
    if a.depth:
        cmd += ["--depth", str(a.depth)]

    if os.path.isdir(os.path.join(repo_dir, ".git")):
        print(f"Already cloned: {repo_dir}")
    else:
        os.makedirs(dest, exist_ok=True)
        for u in ([url] if a.no_mirror else [a.mirror + url, url]):
            print(f"Cloning {u} -> {dest}")
            if subprocess.run(cmd + [u], cwd=dest).returncode == 0:
                break
            print("  clone failed", file=sys.stderr)
        else:
            print("ERROR: all clone attempts failed.", file=sys.stderr)
            return 1

    r = sh("git", "-C", repo_dir, "remote", "set-url", "origin", url)
    if r.returncode != 0:
        print(f"WARNING: could not reset origin: {r.stderr.strip()[-200:]}", file=sys.stderr)

    log = sh("git", "-C", repo_dir, "log", "--oneline", "-3").stdout.strip()
    print(f"\nRepo ready at: {repo_dir}\nOrigin: {url}")
    if log:
        print(f"Latest commits:\n{log}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
