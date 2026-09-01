# project_bundler.py
import argparse
import codecs
import os
import re
import stat
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

EXTENSION_STYLES = {
    ".py": "#", ".pyw": "#", ".sh": "#", ".bash": "#", ".zsh": "#", ".fish": "#",
    ".rb": "#", ".pl": "#", ".pm": "#", ".cr": "#", ".yaml": "#", ".yml": "#",
    ".toml": "#", ".r": "#", ".jl": "#", ".ex": "#", ".exs": "#", ".nim": "#",
    ".tf": "#", ".tfvars": "#", ".ps1": "#", ".psm1": "#", ".psd1": "#",
    ".cmake": "#", ".mk": "#", ".env": "#", ".dockerfile": "#",
    ".c": "//", ".h": "//", ".cpp": "//", ".hpp": "//", ".cc": "//", ".hh": "//",
    ".cxx": "//", ".hxx": "//", ".cs": "//", ".java": "//", ".js": "//",
    ".mjs": "//", ".cjs": "//", ".ts": "//", ".mts": "//", ".cts": "//",
    ".tsx": "//", ".jsx": "//", ".go": "//", ".rs": "//", ".swift": "//",
    ".kt": "//", ".kts": "//", ".scala": "//", ".zig": "//", ".dart": "//",
    ".m": "//", ".mm": "//", ".groovy": "//", ".gradle": "//", ".d": "//",
    ".vala": "//", ".fs": "//", ".fsx": "//",
    ".sql": "--", ".lua": "--", ".hs": "--", ".lhs": "--", ".elm": "--",
    ".adb": "--", ".ads": "--",
    ".lisp": ";", ".lsp": ";", ".cl": ";", ".el": ";", ".scm": ";",
    ".rkt": ";", ".clj": ";", ".asm": ";", ".ini": ";",
    ".tex": "%", ".sty": "%", ".cls": "%", ".erl": "%", ".hrl": "%",
    ".vim": '"',
    ".bat": "REM", ".cmd": "REM",
}

FILENAME_STYLES = {
    "Makefile": "#", "makefile": "#", "GNUmakefile": "#", "Rakefile": "#",
    "Gemfile": "#", "Vagrantfile": "#", "CMakeLists.txt": "#",
    ".gitignore": "#", ".dockerignore": "#", ".env": "#",
    ".bashrc": "#", ".zshrc": "#", ".profile": "#",
    ".vimrc": '"', "vimrc": '"',
}

SKIP_DIRS = {
    ".git", ".hg", ".svn", ".idea", ".vscode", ".cache",
    "node_modules", "__pycache__", ".tox", ".mypy_cache", ".pytest_cache",
    ".venv", "venv", "dist", "build", "target", ".next",
}

PREFIXES = ("#", "//", "--", ";", "%", '"', "REM")
ENCODING_RE = re.compile(r"[ \t\f]*#.*?coding[:=][ \t]*[-_.a-zA-Z0-9]+")
PATH_CHARS_RE = re.compile(r"[\w./\\~ -]+")
REM_RE = re.compile(r"(?i)REM[ \t]+(.*)")
FENCE_OPEN_RE = re.compile(r"^(`{3,}|~{3,})[ \t]*(.*)")
SCAN_WINDOW = 4


@dataclass
class Result:
    status: str
    path: Path
    detail: str = ""


def style_for(path):
    name = path.name
    if name in FILENAME_STYLES:
        return FILENAME_STYLES[name]
    if name.startswith("Dockerfile"):
        return "#"
    return EXTENSION_STYLES.get(path.suffix.lower())


def comment_body(line, prefix):
    stripped = line.strip()
    if prefix == "REM":
        match = REM_RE.match(stripped)
        return match.group(1).strip() if match else None
    if stripped.startswith(prefix):
        return stripped[len(prefix):].strip()
    return None


def is_path_comment(line, prefix, filename):
    body = comment_body(line, prefix)
    if body is None or not PATH_CHARS_RE.fullmatch(body):
        return False
    if body == filename:
        return True
    return body.endswith(filename) and body[-len(filename) - 1] in "/\\"


def insertion_index(lines, prefix):
    index = 0
    if lines and lines[0].startswith("#!") and not lines[0].startswith("#!["):
        index = 1
    if prefix == "#" and index < len(lines) and ENCODING_RE.match(lines[index]):
        index += 1
    return index


def find_path_comment(lines, prefix, filename):
    for index, line in enumerate(lines[:SCAN_WINDOW]):
        if is_path_comment(line, prefix, filename):
            return index
    return None


def iter_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            name for name in dirnames
            if name not in SKIP_DIRS
            and not os.path.islink(os.path.join(dirpath, name))
        )
        for name in sorted(filenames):
            file_path = Path(dirpath) / name
            if not file_path.is_symlink() and file_path.is_file():
                yield file_path


def write_file_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() and not path.is_symlink() else None
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        if mode is not None:
            os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def transform(text, prefix, filename, display_path):
    newline = "\r\n" if "\r\n" in text else "\n"
    if "\n" not in text:
        text = text.replace("\r", "\n")
    trailing = text.endswith("\n") or not text
    lines = text.split("\n")
    if trailing:
        lines.pop()
    lines = [line[:-1] if line.endswith("\r") else line for line in lines]
    comment = f"{prefix} {display_path}"
    existing = find_path_comment(lines, prefix, filename)
    if existing is not None:
        body = comment_body(lines[existing], prefix)
        del lines[existing]
        index = insertion_index(lines, prefix)
        if existing == index and body == display_path:
            return text, "unchanged"
        lines.insert(index, comment)
        status = "replaced" if existing == index else "moved"
    else:
        lines.insert(insertion_index(lines, prefix), comment)
        status = "added"
    result = newline.join(lines)
    if trailing:
        result += newline
    return result, status


def display_path_for(path, cwd):
    resolved = path.resolve()
    try:
        return resolved.relative_to(cwd).as_posix()
    except ValueError:
        return resolved.as_posix()


def process_file(path, cwd, dry_run):
    if path.is_symlink() or not path.is_file():
        return Result("skipped", path, "not a regular file")
    prefix = style_for(path)
    if prefix is None:
        return Result("skipped", path, "unknown file type")
    try:
        raw = path.read_bytes()
    except OSError as exc:
        return Result("error", path, str(exc))
    if b"\0" in raw[:8192]:
        return Result("skipped", path, "binary file")
    bom = raw.startswith(codecs.BOM_UTF8)
    try:
        text = raw.decode("utf-8-sig" if bom else "utf-8")
    except UnicodeDecodeError:
        return Result("skipped", path, "not valid UTF-8")
    display_path = display_path_for(path, cwd)
    new_text, status = transform(text, prefix, path.name, display_path)
    if status == "unchanged" or dry_run:
        return Result(status, path, display_path)
    data = new_text.encode("utf-8-sig" if bom else "utf-8")
    try:
        write_file_atomic(path, data)
    except OSError as exc:
        return Result("error", path, str(exc))
    return Result(status, path, display_path)


def collect_candidates(paths):
    candidates = []
    invalid = []
    for argument in paths:
        if argument.is_dir():
            candidates.extend(iter_files(argument))
        elif argument.exists() or argument.is_symlink():
            candidates.append(argument)
        else:
            invalid.append(argument)
    return candidates, invalid


def cmd_add(args):
    cwd = Path.cwd().resolve()
    candidates, invalid = collect_candidates(args.paths)
    results = [Result("error", argument, "not a file or directory") for argument in invalid]
    for candidate in candidates:
        results.append(process_file(candidate, cwd, args.dry_run))

    counts = Counter(result.status for result in results)
    for result in results:
        if not (args.verbose or result.status in {"added", "replaced", "moved", "error"}):
            continue
        line = f"{result.status:>9}  {result.path}"
        if result.detail and (args.verbose or result.status in {"skipped", "error"}):
            line += f"  ({result.detail})"
        print(line, file=sys.stderr if result.status == "error" else sys.stdout)

    summary = ", ".join(
        f"{status}: {counts.get(status, 0)}"
        for status in ("added", "replaced", "moved", "unchanged", "skipped", "error")
    )
    label = "[dry run] " if args.dry_run else ""
    print(f"{label}{summary}  (total: {len(results)})")
    return 1 if counts.get("error") else 0


def read_bundle_candidate(path):
    raw = path.read_bytes()
    if b"\0" in raw[:8192]:
        return None
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None


def fence_for(text):
    longest = max((len(match.group(0)) for match in re.finditer(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def cmd_bundle(args):
    cwd = Path.cwd().resolve()
    output_path = args.output.resolve()
    candidates, invalid = collect_candidates(args.paths)
    errors = 0
    for argument in invalid:
        print(f"error: not a file or directory: {argument}", file=sys.stderr)
        errors += 1

    if not args.no_add:
        add_results = [process_file(candidate, cwd, dry_run=False) for candidate in candidates]
        add_counts = Counter(result.status for result in add_results)
        for result in add_results:
            if result.status == "error":
                print(f"error: {result.path}: {result.detail}", file=sys.stderr)
            elif args.verbose or result.status in {"added", "replaced", "moved"}:
                line = f"{result.status:>9}  {result.path}"
                if result.detail and args.verbose:
                    line += f"  ({result.detail})"
                print(line)
        errors += add_counts.get("error", 0)
        print("pre-op add: " + ", ".join(
            f"{status}: {add_counts.get(status, 0)}"
            for status in ("added", "replaced", "moved", "unchanged", "skipped", "error")
        ))

    blocks = []
    bundled = skipped = 0
    for candidate in candidates:
        if candidate.is_symlink() or not candidate.is_file():
            continue
        if candidate.resolve() == output_path:
            continue
        try:
            text = read_bundle_candidate(candidate)
        except OSError as exc:
            print(f"error: {candidate}: {exc}", file=sys.stderr)
            errors += 1
            continue
        if text is None:
            skipped += 1
            if args.verbose:
                print(f"skipped  {candidate}  (binary or not UTF-8)")
            continue
        display_path = display_path_for(candidate, cwd)
        content = text.replace("\r\n", "\n").replace("\r", "\n")
        if not content.endswith("\n"):
            content += "\n"
        fence = fence_for(content)
        blocks.append(f"{fence}{display_path}\n{content}{fence}")
        bundled += 1
        if args.verbose:
            print(f"bundled  {candidate}")

    if not blocks:
        print("no bundleable files found")
        return 1 if errors else 0
    try:
        args.output.write_text("\n\n".join(blocks) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"error: cannot write {args.output}: {exc}", file=sys.stderr)
        return 1
    print(f"bundled: {bundled}, skipped: {skipped}, errors: {errors} -> {args.output}")
    return 1 if errors else 0


def is_closing_fence(line, char, length):
    stripped = line.strip()
    return len(stripped) >= length and set(stripped) == {char}


def parse_blocks(text):
    blocks = []
    lines = text.split("\n")
    index = 0
    unterminated = 0
    while index < len(lines):
        match = FENCE_OPEN_RE.match(lines[index])
        if not match or (match.group(1)[0] == "`" and "`" in match.group(2)):
            index += 1
            continue
        fence, info = match.group(1), match.group(2).strip()
        index += 1
        content = []
        while index < len(lines) and not is_closing_fence(lines[index], fence[0], len(fence)):
            content.append(lines[index])
            index += 1
        if index >= len(lines):
            unterminated += 1
            break
        blocks.append((info, content))
        index += 1
    return blocks, unterminated


def fence_path(info):
    body = info.strip()
    if not body or not PATH_CHARS_RE.fullmatch(body):
        return None
    if "/" not in body and not PurePosixPath(body).suffix:
        return None
    normalized = body.replace("\\", "/")
    candidate = PurePosixPath(normalized)
    if candidate.is_absolute() or normalized.startswith("~") or ".." in candidate.parts or not candidate.name:
        return None
    return candidate


def extract_path(content):
    for line in content[:SCAN_WINDOW]:
        for prefix in PREFIXES:
            body = comment_body(line, prefix)
            if body is None:
                continue
            body = body.strip()
            if not body or not PATH_CHARS_RE.fullmatch(body):
                continue
            candidate = PurePosixPath(body.replace("\\", "/"))
            if candidate.is_absolute() or ".." in candidate.parts or not candidate.name:
                continue
            if style_for(Path(candidate.name)) != prefix:
                continue
            return candidate
    return None


def cmd_unbundle(args):
    try:
        text = args.bundle.read_bytes().decode("utf-8-sig")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"error: cannot read {args.bundle}: {exc}", file=sys.stderr)
        return 1
    text = text.replace("\r\n", "\n").replace("\r", "\n")

    root = args.output.resolve()
    blocks, unterminated = parse_blocks(text)
    if unterminated:
        print(f"warning: {unterminated} unterminated fence(s) ignored", file=sys.stderr)

    seen = set()
    written = overwritten = unchanged = skipped = errors = 0
    for info, content in blocks:
        relative = fence_path(info) or extract_path(content)
        if relative is None:
            skipped += 1
            if args.verbose:
                print(f" skipped  block ({info or 'no info'}): no valid path", file=sys.stderr)
            continue
        target = (root / Path(*relative.parts)).resolve()
        if not target.is_relative_to(root):
            skipped += 1
            print(f"warning: {relative}: path escapes output directory, skipped", file=sys.stderr)
            continue
        if relative in seen:
            skipped += 1
            print(f"warning: {relative}: duplicate block, keeping first", file=sys.stderr)
            continue
        seen.add(relative)
        data = ("\n".join(content) + "\n").encode("utf-8")
        if target.is_dir():
            skipped += 1
            print(f"warning: {relative}: a directory exists at that path, skipped", file=sys.stderr)
            continue
        if target.exists():
            try:
                if target.read_bytes() == data:
                    unchanged += 1
                    if args.verbose:
                        print(f"unchanged  {relative}")
                    continue
            except OSError as exc:
                errors += 1
                print(f"error: {relative}: {exc}", file=sys.stderr)
                continue
            if not args.force:
                skipped += 1
                print(f"warning: {relative}: exists with different content, skipped (use --force)", file=sys.stderr)
                continue
            status = "overwritten"
        else:
            status = "written"
        if not args.dry_run:
            try:
                write_file_atomic(target, data)
            except OSError as exc:
                errors += 1
                print(f"error: {relative}: {exc}", file=sys.stderr)
                continue
        if status == "overwritten":
            overwritten += 1
        else:
            written += 1
        print(f"{status:>11}  {relative}")

    label = "[dry run] " if args.dry_run else ""
    print(f"{label}written: {written}, overwritten: {overwritten}, unchanged: {unchanged}, "
          f"skipped: {skipped}, errors: {errors}  (blocks: {len(blocks)})")
    return 1 if errors else 0


def main():
    parser = argparse.ArgumentParser(
        prog="project_bundler.py",
        description="Stamp source files with path comments, bundle them into one Markdown file, and restore them back.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    add_parser = subparsers.add_parser("add", help="Insert or update path comments in source files.")
    add_parser.add_argument("paths", nargs="+", type=Path, help="Folders (or individual files) to process.")
    add_parser.add_argument("--dry-run", action="store_true", help="Report changes without writing anything.")
    add_parser.add_argument("--verbose", "-v", action="store_true", help="Report every file, including unchanged and skipped.")
    add_parser.set_defaults(func=cmd_add)

    bundle_parser = subparsers.add_parser("bundle", help="Stamp files with path comments (pre-op) and pack them into one Markdown file.")
    bundle_parser.add_argument("paths", nargs="+", type=Path, help="Folders (or individual files) to scan.")
    bundle_parser.add_argument("--output", "-o", type=Path, default=Path("bundle.md"), help="Bundle file to write (default: bundle.md).")
    bundle_parser.add_argument("--no-add", action="store_true", help="Skip the path-comment pre-op; only bundle files already stamped.")
    bundle_parser.add_argument("--verbose", "-v", action="store_true", help="Report every bundled and skipped file.")
    bundle_parser.set_defaults(func=cmd_bundle)

    unbundle_parser = subparsers.add_parser("unbundle", help="Restore files and directory structure from a bundle.")
    unbundle_parser.add_argument("bundle", type=Path, help="The bundle file to read.")
    unbundle_parser.add_argument("--output", "-o", type=Path, default=Path("."), help="Root directory to restore into (default: current directory).")
    unbundle_parser.add_argument("--force", action="store_true", help="Overwrite existing files whose content differs.")
    unbundle_parser.add_argument("--dry-run", action="store_true", help="Report actions without writing anything.")
    unbundle_parser.add_argument("--verbose", "-v", action="store_true", help="Report every block, including skipped ones.")
    unbundle_parser.set_defaults(func=cmd_unbundle)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
