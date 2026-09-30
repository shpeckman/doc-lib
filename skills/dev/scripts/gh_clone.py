# scripts/gh_clone.py
import argparse, os, re, shutil, subprocess, sys

MIRROR = "https://gh-proxy.com/"


def sh(*cmd):
    return subprocess.run(cmd, text=True, capture_output=True)


def repo_url(spec):
    m = re.fullmatch(r"([\w.-]+)/([\w.-]+)", spec)
    if m:
        return f"https://github.com/{m.group(1)}/{m.group(2)}.git"
    m = re.fullmatch(r"git@github\.com:([\w.-]+)/([\w.-]+?)(?:\.git)?", spec)
    if m:
        return f"https://github.com/{m.group(1)}/{m.group(2)}.git"
    if re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+?(?:\.git)?", spec):
        return spec if spec.endswith(".git") else spec + ".git"
    print(f"ERROR: cannot parse repo spec: {spec}", file=sys.stderr)
    return None


def clone(url, dest, args):
    cmd = ["git", "clone", "--single-branch"]
    if not args.full:
        cmd += ["--depth", str(args.depth)]
    if args.branch:
        cmd += ["--branch", args.branch]
    cmd += [url, dest]
    print(f"Cloning {url}")
    r = sh(*cmd)
    if r.returncode == 0:
        return True
    print(f"  failed: {(r.stderr or r.stdout).strip()[-300:]}", file=sys.stderr)
    shutil.rmtree(dest, ignore_errors=True)
    return False


def main():
    p = argparse.ArgumentParser(description="Fast GitHub clone: shallow + single-branch by default, with mirror fallback.",
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("repo", help="owner/repo, https://github.com/owner/repo, or git@github.com:owner/repo")
    p.add_argument("dest", nargs="?", help="target directory (default: repo name)")
    p.add_argument("--branch", help="clone this branch/tag instead of the default")
    p.add_argument("--depth", type=int, default=1, help="shallow clone depth")
    p.add_argument("--full", action="store_true", help="full clone with complete history")
    p.add_argument("--mirror", default=MIRROR)
    p.add_argument("--no-mirror", action="store_true", help="clone directly from github.com")
    a = p.parse_args()

    url = repo_url(a.repo)
    if not url:
        return 1
    dest = os.path.abspath(a.dest or re.sub(r"\.git$", "", url.rstrip("/")).rsplit("/", 1)[-1])
    if os.path.exists(dest):
        print(f"ERROR: destination already exists: {dest}", file=sys.stderr)
        return 1

    urls = [url] if a.no_mirror else [a.mirror + url, url]
    for u in urls:
        if clone(u, dest, a):
            break
    else:
        print("ERROR: all clone attempts failed.", file=sys.stderr)
        return 1

    head = sh("git", "-C", dest, "log", "-1", "--oneline").stdout.strip()
    print(f"Cloned to: {dest}")
    if head:
        print(f"HEAD: {head}")
    if not a.full:
        print("Shallow clone; deepen later with: git -C <dir> fetch --unshallow")
    return 0


if __name__ == "__main__":
    sys.exit(main())
