#!/usr/bin/env python3
# scripts/project_bundler.py
import base64
import glob as globlib
import os
import re
import sys
import tempfile
from enum import Enum

HELP = """usage: project_bundler.py <command> [arguments]

commands:
  bundle [TARGETS...] [-ex PATTERN...]  pack files into one bundle file
                                        (default <name>-bundle.txt, named after the
                                        first target: directory name or file stem);
                                        literal binary targets are base64-encoded,
                                        binaries found by walks or globs are skipped
  unbundle [BUNDLE] [--no-force]        restore files from a bundle
                                        (default <name>-bundle.txt);
                                        differing files are overwritten by default

targets:
  a directory is handled recursively. a pattern containing * ? [ ] { } is
  glob-expanded and each match becomes a target. a literal file target is
  always handled, even if gitignored. directory walks and glob matches
  respect .gitignore files, starting at each target.
  -ex, --exclude PATTERN excludes paths on top of .gitignore (repeatable,
  gitignore-style); it filters walks and glob matches, never literal files.

options:
  -h, --help    show this help
  --no-force    unbundle skips files that exist with different content
                (default: overwrite them)

bundle first stamps every file it handles with its relative path comment
(e.g. `# src/a.cr`); unbundle relies on those comments to restore
language-tagged blocks.
"""

GLOB_CHARS = set("*?[]{}")
DEFAULT_EXCLUDE = [".gitignore", "LICENSE", "*.md"]

SKIP_DIRS = {
    ".git", ".hg", ".svn", ".idea", ".vscode", ".cache",
    "node_modules", "__pycache__", ".tox", ".mypy_cache", ".pytest_cache",
    ".venv", "venv", "dist", "build", "target", ".next",
}

UTF8_BOM = b"\xef\xbb\xbf"

SCAN_WINDOW = 4
BASE64_MARK = " base64"
BASE64_LINE_SIZE = 76

FENCE_OPEN_RE = re.compile(r"(`{3,}|~{3,})[ \t]*(.*)")
PATH_CHARS_RE = re.compile(r"[A-Za-z0-9_./\\~ -]+")
ENCODING_RE = re.compile(r"[ \t\f]*#.*?coding[:=][ \t]*[-_.a-zA-Z0-9]+")
REM_RE = re.compile(r"REM[ \t]+(.*)", re.IGNORECASE)


class Status(Enum):
    ADDED = "added"
    REPLACED = "replaced"
    MOVED = "moved"
    UNCHANGED = "unchanged"
    SKIPPED = "skipped"
    ERROR = "error"
    BUNDLED = "bundled"
    WRITTEN = "written"
    OVERWRITTEN = "overwritten"


class Result:
    __slots__ = ("status", "path", "detail")

    def __init__(self, status, path, detail=""):
        self.status = status
        self.path = path
        self.detail = detail


class BundleOutcome:
    def __init__(self, add_results, results, output, bundle_written):
        self.add_results = add_results
        self.results = results
        self.output = output
        self.bundle_written = bundle_written

    def count(self, status):
        return sum(1 for r in self.results if r.status is status)

    def add_count(self, status):
        return sum(1 for r in self.add_results if r.status is status)

    def error_count(self):
        return self.count(Status.ERROR) + self.add_count(Status.ERROR)


class UnbundleOutcome:
    def __init__(self, results, unterminated, block_count):
        self.results = results
        self.unterminated = unterminated
        self.block_count = block_count

    def count(self, status):
        return sum(1 for r in self.results if r.status is status)

    def error_count(self):
        return self.count(Status.ERROR)


class BundlerError(Exception):
    pass


def extname(path):
    ext = os.path.splitext(path)[1]
    return "" if ext == "." else ext


def walk_files(dir_path):
    dirs = []
    files = []
    try:
        with os.scandir(dir_path) as it:
            for entry in it:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if entry.name not in SKIP_DIRS:
                        dirs.append(entry.name)
                elif entry.is_file(follow_symlinks=False):
                    files.append(entry.name)
    except OSError:
        return
    files.sort()
    dirs.sort()
    for name in files:
        yield os.path.join(dir_path, name)
    for name in dirs:
        yield from walk_files(os.path.join(dir_path, name))


def collect_candidates(paths):
    candidates = []
    invalid = []
    for argument in paths:
        name = str(argument)
        if os.path.isdir(name):
            candidates.extend(walk_files(name))
        elif os.path.exists(name) or os.path.islink(name):
            candidates.append(name)
        else:
            invalid.append(name)
    return candidates, invalid


def write_file_atomic(path, data):
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    mode = None
    if os.path.exists(path) and not os.path.islink(path):
        mode = os.stat(path).st_mode & 0o7777
    tmp = tempfile.NamedTemporaryFile(
        mode="wb", prefix=".%s." % os.path.basename(path), suffix=".tmp",
        dir=parent, delete=False,
    )
    try:
        tmp.write(data)
        tmp.close()
        if mode is not None:
            os.chmod(tmp.name, mode)
        os.replace(tmp.name, path)
    except BaseException:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        raise


def valid_utf8(data):
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def has_bom(raw):
    return raw[:3] == UTF8_BOM


def decode_text(raw):
    if b"\x00" in raw[:8192]:
        return None
    payload = raw[3:] if has_bom(raw) else raw
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return None


def display_path_for(path, cwd):
    resolved = os.path.realpath(str(path))
    base = str(cwd)
    if resolved.startswith(base + "/"):
        return resolved[len(base) + 1:]
    return resolved


def resolve_lenient(path):
    current = str(path)
    rest = []
    while True:
        if os.path.lexists(current):
            try:
                real = os.path.realpath(current)
                if rest:
                    return os.path.join(real, *rest)
                return real
            except OSError:
                pass
        base = os.path.basename(current)
        parent = os.path.dirname(current)
        if base == "" or parent == current:
            break
        rest.insert(0, base)
        current = parent
    return os.path.abspath(str(path))


def within(target, root):
    target_string = str(target)
    root_string = str(root)
    if target_string == root_string:
        return True
    prefix = root_string if root_string.endswith("/") else root_string + "/"
    return target_string.startswith(prefix)


class IgnorePattern:
    __slots__ = ("regex", "dir_only", "negated")

    def __init__(self, regex, dir_only, negated):
        self.regex = regex
        self.dir_only = dir_only
        self.negated = negated


class IgnoreNode:
    __slots__ = ("base_dir", "patterns", "next_node")

    def __init__(self, base_dir, patterns=None, next_node=None):
        self.base_dir = base_dir
        self.patterns = patterns if patterns is not None else []
        self.next_node = next_node


def glob_to_regex(pattern):
    out = []
    i = 0
    n = len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            if i + 1 < n and pattern[i + 1] == "*":
                j = i + 2
                if j < n and pattern[j] == "/":
                    out.append("(?:.*/)?")
                    i = j + 1
                    continue
                out.append(".*")
                i = j
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = i + 1
            negate = False
            if j < n and (pattern[j] == "!" or pattern[j] == "^"):
                negate = True
                j += 1
            body = []
            closed = False
            while j < n:
                cc = pattern[j]
                if cc == "]":
                    closed = True
                    break
                if cc == "\\" and j + 1 < n:
                    body.append("\\" + pattern[j + 1])
                    j += 2
                    continue
                body.append(cc)
                j += 1
            if closed:
                out.append("[")
                if negate:
                    out.append("^")
                out.append("".join(body))
                out.append("]")
                i = j + 1
                continue
            out.append("\\[")
        elif c == "\\":
            if i + 1 < n:
                out.append(re.escape(pattern[i + 1]))
                i += 2
                continue
            out.append("\\\\")
        elif c in ".()+|^${}":
            out.append("\\" + c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def compile_pattern(raw):
    line = raw
    if not line:
        return None
    negated = False
    if line.startswith("!"):
        negated = True
        line = line[1:]
    line = line.rstrip()
    line = line.replace("\\ ", " ")
    if not line:
        return None
    dir_only = False
    if line.endswith("/"):
        dir_only = True
        line = line[:-1]
    anchored = False
    if line.startswith("/"):
        anchored = True
        line = line[1:]
    if "/" in line:
        anchored = True
    body = glob_to_regex(line)
    prefix = r"\A" if anchored else r"(?:\A|/)"
    regex = re.compile(prefix + body + r"(?:/|\Z)")
    return IgnorePattern(regex, dir_only, negated)


def gitignore_load(dir_path, parent):
    ignore_path = os.path.join(dir_path, ".gitignore")
    if not os.path.exists(ignore_path):
        return parent
    patterns = []
    try:
        with open(ignore_path, "r", encoding="utf-8", errors="replace", newline="") as f:
            text = f.read()
    except OSError:
        return parent
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        pattern = compile_pattern(line)
        if pattern is not None:
            patterns.append(pattern)
    if not patterns:
        return parent
    return IgnoreNode(dir_path, patterns, parent)


def _lchop_dot(value):
    if value.startswith("./"):
        return value[2:]
    return value


def relative_within(base_dir, path):
    normalized_base = "" if base_dir == "." else _lchop_dot(base_dir).rstrip("/")
    normalized_path = _lchop_dot(path)
    if normalized_base == "":
        return normalized_path
    prefix = normalized_base + "/"
    if normalized_path.startswith(prefix):
        return normalized_path[len(prefix):]
    return None


def gitignore_ignored(path, filename, is_dir, node):
    if filename == ".git" or "/.git/" in path:
        return True
    nodes = []
    curr = node
    while curr is not None:
        nodes.append(curr)
        curr = curr.next_node
    matched = False
    for entry in reversed(nodes):
        rel = relative_within(entry.base_dir, path)
        if rel is None:
            continue
        for pattern in entry.patterns:
            if pattern.dir_only and not is_dir:
                continue
            if pattern.regex.search(rel):
                matched = not pattern.negated
    return matched


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
    ".vim": "\"",
    ".bat": "REM", ".cmd": "REM",
}

FILENAME_STYLES = {
    "Makefile": "#", "makefile": "#", "GNUmakefile": "#", "Rakefile": "#",
    "Gemfile": "#", "Vagrantfile": "#", "CMakeLists.txt": "#",
    ".gitignore": "#", ".dockerignore": "#", ".env": "#",
    ".bashrc": "#", ".zshrc": "#", ".profile": "#",
    ".vimrc": "\"", "vimrc": "\"",
}

PREFIXES = ("#", "//", "--", ";", "%", "\"", "REM")


def style_for(name):
    base = os.path.basename(name)
    if base in FILENAME_STYLES:
        return FILENAME_STYLES[base]
    if base.startswith("Dockerfile"):
        return "#"
    return EXTENSION_STYLES.get(extname(base).lower())


def comment_body(line, prefix):
    stripped = line.strip()
    if prefix == "REM":
        match = REM_RE.match(stripped)
        return match.group(1).strip() if match else None
    if stripped.startswith(prefix):
        return stripped[len(prefix):].strip()
    return None


def path_comment(line, prefix, filename):
    body = comment_body(line, prefix)
    if body is None:
        return False
    if not PATH_CHARS_RE.fullmatch(body):
        return False
    if body == filename:
        return True
    if len(body) <= len(filename) or not body.endswith(filename):
        return False
    separator = body[len(body) - len(filename) - 1]
    return separator == "/" or separator == "\\"


def insertion_index(lines, prefix):
    index = 0
    if lines and lines[0].startswith("#!") and not lines[0].startswith("#!["):
        index = 1
    if prefix == "#" and index < len(lines) and ENCODING_RE.match(lines[index]):
        index += 1
    return index


def find_path_comment(lines, prefix, filename):
    for index, line in enumerate(lines[:SCAN_WINDOW]):
        if path_comment(line, prefix, filename):
            return index
    return None


def transform(text, prefix, filename, display_path):
    newline = "\r\n" if "\r\n" in text else "\n"
    if "\n" not in text:
        text = text.replace("\r", "\n")
    trailing = text.endswith("\n") or text == ""
    lines = text.split("\n") if text else []
    if trailing and lines:
        lines.pop()
    lines = [line[:-1] if line.endswith("\r") else line for line in lines]
    comment = "%s %s" % (prefix, display_path)
    existing = find_path_comment(lines, prefix, filename)
    if existing is not None:
        body = comment_body(lines[existing], prefix)
        del lines[existing]
        index = insertion_index(lines, prefix)
        if existing == index and body == display_path:
            return text, Status.UNCHANGED
        lines.insert(index, comment)
        status = Status.REPLACED if existing == index else Status.MOVED
    else:
        lines.insert(insertion_index(lines, prefix), comment)
        status = Status.ADDED
    result = newline.join(lines)
    if trailing:
        result += newline
    return result, status


def process_file(path, cwd, dry_run=False):
    name = str(path)
    if os.path.islink(name) or not os.path.isfile(name):
        return Result(Status.SKIPPED, name, "not a regular file")
    prefix = style_for(name)
    if prefix is None:
        return Result(Status.SKIPPED, name, "unknown file type")
    try:
        with open(name, "rb") as f:
            raw = f.read()
    except OSError as ex:
        return Result(Status.ERROR, name, str(ex))
    if b"\x00" in raw[:8192]:
        return Result(Status.SKIPPED, name, "binary file")
    bom = has_bom(raw)
    payload = raw[3:] if bom else raw
    if not valid_utf8(payload):
        return Result(Status.SKIPPED, name, "not valid UTF-8")
    text = payload.decode("utf-8")
    display_path = display_path_for(name, cwd)
    transformed, status = transform(text, prefix, os.path.basename(name), display_path)
    if status is Status.UNCHANGED or dry_run:
        return Result(status, name, display_path)
    data = (UTF8_BOM if bom else b"") + transformed.encode("utf-8")
    try:
        write_file_atomic(name, data)
    except OSError as ex:
        return Result(Status.ERROR, name, str(ex))
    return Result(status, name, display_path)


def stamp_add(paths, dry_run=False):
    cwd = os.path.realpath(os.getcwd())
    candidates, invalid = collect_candidates(paths)
    results = [Result(Status.ERROR, str(a), "not a file or directory") for a in invalid]
    for candidate in candidates:
        results.append(process_file(candidate, cwd, dry_run))
    return results


def fence_for(text):
    longest = 0
    for match in re.findall(r"`+", text):
        if len(match) > longest:
            longest = len(match)
    return "`" * max(3, longest + 1)


def default_bundle_name(path="."):
    raw = str(path)
    if os.path.isdir(raw):
        name = os.path.basename(os.path.realpath(raw))
    else:
        name = os.path.basename(raw)
        ext = extname(raw)
        if ext:
            name = name[:-len(ext)]
    if not name or any(char in "*?[]{}" for char in name):
        name = "bundle"
    return name + "-bundle.txt"


def bundle(paths, output=None, no_add=False, allow_binary=None):
    paths = [str(p) for p in paths]
    output_path = str(output) if output else default_bundle_name(paths[0] if paths else ".")
    if os.path.exists(output_path):
        output_resolved = os.path.realpath(output_path)
    else:
        output_resolved = os.path.abspath(output_path)
    cwd = os.path.realpath(os.getcwd())
    candidates, invalid = collect_candidates(paths)
    results = [Result(Status.ERROR, str(a), "not a file or directory") for a in invalid]
    binary_allowed = set()
    if allow_binary:
        for path in allow_binary:
            binary_allowed.add(os.path.abspath(str(path)))
    add_results = []
    if not no_add:
        for candidate in candidates:
            add_results.append(process_file(candidate, cwd, False))
    blocks = []
    for candidate in candidates:
        name = str(candidate)
        if os.path.islink(name) or not os.path.isfile(name):
            continue
        if os.path.realpath(name) == output_resolved:
            continue
        try:
            with open(name, "rb") as f:
                raw = f.read()
        except OSError as ex:
            results.append(Result(Status.ERROR, name, str(ex)))
            continue
        display_path = display_path_for(name, cwd)
        text = decode_text(raw)
        if text is not None:
            content = text.replace("\r\n", "\n").replace("\r", "\n")
            if not content.endswith("\n"):
                content += "\n"
            fence = fence_for(content)
            blocks.append("%s%s\n%s%s" % (fence, display_path, content, fence))
        elif os.path.abspath(name) in binary_allowed:
            encoded = encode_base64(raw)
            fence = fence_for(encoded)
            blocks.append("%s%s%s\n%s%s" % (fence, display_path, BASE64_MARK, encoded, fence))
        else:
            results.append(Result(Status.SKIPPED, name, "binary or not UTF-8"))
            continue
        results.append(Result(Status.BUNDLED, name))
    if not blocks:
        return BundleOutcome(add_results, results, output_path, False)
    with open(output_path, "w", encoding="utf-8", newline="") as f:
        f.write("\n\n".join(blocks) + "\n")
    return BundleOutcome(add_results, results, output_path, True)


def encode_base64(raw):
    encoded = base64.b64encode(raw).decode("ascii")
    return "".join(encoded[o:o + BASE64_LINE_SIZE] + "\n" for o in range(0, len(encoded), BASE64_LINE_SIZE))


def decode_base64(content):
    try:
        return base64.b64decode(re.sub(r"\s", "", "".join(content)), validate=True)
    except Exception:
        return None


def closing_fence(line, char, length):
    stripped = line.strip()
    return len(stripped) >= length and all(c == char for c in stripped)


def parse_blocks(text):
    blocks = []
    lines = text.split("\n")
    index = 0
    unterminated = 0
    while index < len(lines):
        match = FENCE_OPEN_RE.match(lines[index])
        if match is None or (match.group(1)[0] == "`" and "`" in match.group(2)):
            index += 1
            continue
        fence = match.group(1)
        info = match.group(2).strip()
        index += 1
        content = []
        while index < len(lines) and not closing_fence(lines[index], fence[0], len(fence)):
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
    if not body:
        return None
    if not PATH_CHARS_RE.fullmatch(body):
        return None
    if "/" not in body and extname(body) == "":
        return None
    candidate = body.replace("\\", "/")
    if candidate.startswith("/") or candidate.startswith("~"):
        return None
    parts = [part for part in candidate.split("/") if part and part != "."]
    if not parts or ".." in parts:
        return None
    return "/".join(parts)


def extract_path(content):
    for line in content[:SCAN_WINDOW]:
        for prefix in PREFIXES:
            body = comment_body(line, prefix)
            if body is None:
                continue
            body = body.strip()
            if not body:
                continue
            if not PATH_CHARS_RE.fullmatch(body):
                continue
            candidate = body.replace("\\", "/")
            if candidate.startswith("/"):
                continue
            parts = [part for part in candidate.split("/") if part and part != "."]
            if not parts or ".." in parts:
                continue
            if style_for(parts[-1]) != prefix:
                continue
            return "/".join(parts)
    return None


def _open_error_message(path, ex):
    if isinstance(ex, FileNotFoundError):
        reason = "No such file or directory"
    elif isinstance(ex, PermissionError):
        reason = "Permission denied"
    else:
        reason = ex.strerror or str(ex)
    return "Error opening file with mode 'rb': '%s': %s" % (path, reason)


def unbundle(bundle_path, output=".", force=True, dry_run=False):
    bundle_path = str(bundle_path)
    try:
        with open(bundle_path, "rb") as f:
            raw = f.read()
    except OSError as ex:
        raise BundlerError(_open_error_message(bundle_path, ex)) from ex
    payload = raw[3:] if has_bom(raw) else raw
    if not valid_utf8(payload):
        raise BundlerError("cannot read %s: not valid UTF-8" % bundle_path)
    text = payload.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    root = resolve_lenient(output)
    blocks, unterminated = parse_blocks(text)
    results = []
    seen = set()
    for info, content in blocks:
        binary = info.endswith(BASE64_MARK)
        if binary:
            info = info[:-len(BASE64_MARK)]
        relative = fence_path(info)
        if relative is None and not binary:
            relative = extract_path(content)
        if relative is None:
            results.append(Result(Status.SKIPPED, "", "no valid path"))
            continue
        rel_key = relative
        target = root
        for part in rel_key.split("/"):
            target = os.path.join(target, part)
        target = resolve_lenient(target)
        if not within(target, root):
            results.append(Result(Status.SKIPPED, rel_key, "path escapes output directory"))
            continue
        if rel_key in seen:
            results.append(Result(Status.SKIPPED, rel_key, "duplicate block, keeping first"))
            continue
        seen.add(rel_key)
        if binary:
            data = decode_base64(content)
            if data is None:
                results.append(Result(Status.ERROR, rel_key, "invalid base64 data"))
                continue
        else:
            data = ("\n".join(content) + "\n").encode("utf-8")
        if os.path.isdir(target):
            results.append(Result(Status.SKIPPED, rel_key, "a directory exists at that path"))
            continue
        if os.path.exists(target):
            try:
                with open(target, "rb") as f:
                    existing = f.read()
            except OSError as ex:
                results.append(Result(Status.ERROR, rel_key, str(ex)))
                continue
            if existing == data:
                results.append(Result(Status.UNCHANGED, rel_key))
                continue
            if not force:
                results.append(Result(Status.SKIPPED, rel_key, "exists with different content"))
                continue
            status = Status.OVERWRITTEN
        else:
            status = Status.WRITTEN
        if not dry_run:
            try:
                write_file_atomic(target, data)
            except OSError as ex:
                results.append(Result(Status.ERROR, rel_key, str(ex)))
                continue
        results.append(Result(status, rel_key))
    return UnbundleOutcome(results, unterminated, len(blocks))


def _brace_alts(inner):
    alts = []
    depth = 0
    start = 0
    found = False
    for i, c in enumerate(inner):
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        elif c == "," and depth == 0:
            alts.append(inner[start:i])
            start = i + 1
            found = True
    if not found:
        return [inner]
    alts.append(inner[start:])
    return alts


def brace_expand(pattern):
    depth = 0
    start = -1
    for i, c in enumerate(pattern):
        if c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0 and start >= 0:
                inner = pattern[start + 1:i]
                results = []
                for alt in _brace_alts(inner):
                    results.extend(brace_expand(pattern[:start] + alt + pattern[i + 1:]))
                return results
    return [pattern]


def crystal_glob(pattern):
    seen = set()
    matches = []
    for expanded in brace_expand(pattern):
        for match in globlib.glob(expanded, recursive=True):
            if match not in seen:
                seen.add(match)
                matches.append(match)
    return matches


def has_glob_chars(target):
    return any(char in GLOB_CHARS for char in target)


def exclude_node(excludes):
    patterns = [p for p in (compile_pattern(raw) for raw in excludes) if p is not None]
    if not patterns:
        return None
    return IgnoreNode(".", patterns)


def ignored_entry(path, name, is_dir, node, excludes):
    if gitignore_ignored(path, name, is_dir, node):
        return True
    if excludes is not None and gitignore_ignored(path, name, is_dir, excludes):
        return True
    return False


def ignore_chain_for(path):
    node = gitignore_load(".", None)
    parts = [part for part in path.split("/") if part and part != "."]
    for i in range(len(parts) - 1):
        node = gitignore_load("/".join(parts[:i + 1]), node)
    return node


def filtered(path, name, is_dir, excludes):
    return ignored_entry(path, name, is_dir, ignore_chain_for(path), excludes)


def expand_glob(pattern, excludes, files, seen, stderr):
    matches = crystal_glob(pattern)
    if not matches:
        print("error: %s: no matches" % pattern, file=stderr)
        return False
    matches.sort()
    for match in matches:
        name = os.path.basename(match)
        if os.path.isdir(match) and not os.path.islink(match):
            if filtered(match, name, True, excludes):
                continue
            walk_target(match, None, excludes, files, seen)
        else:
            if filtered(match, name, False, excludes):
                continue
            absolute = os.path.abspath(match)
            if absolute not in seen:
                seen.add(absolute)
                files.append(match)
    return True


def walk_target(dir_path, parent, excludes, files, seen):
    node = gitignore_load(dir_path, parent)
    dirs = []
    names = []
    try:
        with os.scandir(dir_path) as it:
            for entry in it:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if entry.name not in SKIP_DIRS:
                        dirs.append(entry.name)
                elif entry.is_file(follow_symlinks=False):
                    names.append(entry.name)
    except OSError:
        return
    dirs.sort()
    names.sort()
    for name in names:
        full = os.path.join(dir_path, name)
        if ignored_entry(full, name, False, node, excludes):
            continue
        absolute = os.path.abspath(full)
        if absolute not in seen:
            seen.add(absolute)
            files.append(full)
    for name in dirs:
        full = os.path.join(dir_path, name)
        if ignored_entry(full, name, True, node, excludes):
            continue
        walk_target(full, node, excludes, files, seen)


def collect_targets(targets, excludes, stderr):
    files = []
    literals = set()
    seen = set()
    status = 0
    for target in targets:
        if has_glob_chars(target):
            if not expand_glob(target, excludes, files, seen, stderr):
                status = 1
        elif os.path.isdir(target):
            walk_target(target, None, excludes, files, seen)
        elif os.path.exists(target) or os.path.islink(target):
            expanded = os.path.abspath(target)
            if expanded not in seen:
                seen.add(expanded)
                files.append(target)
                literals.add(expanded)
        else:
            print("error: %s: not a file or directory" % target, file=stderr)
            status = 1
    return files, literals, status


def cmd_bundle(args, stdout, stderr):
    targets = []
    excludes = list(DEFAULT_EXCLUDE)
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("-ex", "--exclude"):
            index += 1
            if index < len(args):
                excludes.append(args[index])
            else:
                print("error: -ex requires a pattern", file=stderr)
                return 2
        elif arg in ("-h", "--help"):
            stdout.write(HELP)
            return 0
        elif arg.startswith("-"):
            print("error: unknown option '%s'" % arg, file=stderr)
            return 2
        else:
            targets.append(arg)
        index += 1
    if not targets:
        targets.append(".")

    files, literals, status = collect_targets(targets, exclude_node(excludes), stderr)

    for result in stamp_add(files):
        if result.status is Status.ERROR:
            print("error: %s: %s" % (result.path, result.detail), file=stderr)
            status = 1
        elif result.status in (Status.ADDED, Status.REPLACED, Status.MOVED):
            print("stamped: %s" % result.path, file=stdout)

    outcome = bundle(files, output=default_bundle_name(targets[0]), no_add=True, allow_binary=literals)
    for result in outcome.results:
        if result.status is Status.ERROR:
            print("error: %s: %s" % (result.path, result.detail), file=stderr)
            status = 1
        elif result.status is Status.SKIPPED:
            print("skipped: %s (%s)" % (result.path, result.detail), file=stderr)
        elif result.status is Status.BUNDLED:
            print("bundled: %s" % result.path, file=stdout)
    if not outcome.bundle_written:
        print("error: nothing to bundle", file=stderr)
        return 1
    print("bundled %d file(s) into %s" % (outcome.count(Status.BUNDLED), outcome.output), file=stdout)
    return status


def cmd_unbundle(args, stdout, stderr):
    bundle_arg = None
    force = True
    for arg in args:
        if arg in ("-h", "--help"):
            stdout.write(HELP)
            return 0
        elif arg == "--no-force":
            force = False
        elif arg.startswith("-"):
            print("error: unknown option '%s'" % arg, file=stderr)
            return 2
        else:
            if bundle_arg is not None:
                print("error: unexpected argument '%s'" % arg, file=stderr)
                return 2
            bundle_arg = arg

    try:
        outcome = unbundle(bundle_arg or default_bundle_name(), force=force)
    except BundlerError as ex:
        print("error: %s" % ex, file=stderr)
        return 1

    for result in outcome.results:
        if result.status is Status.ERROR:
            print("error: %s: %s" % (result.path, result.detail), file=stderr)
        elif result.status is Status.SKIPPED:
            print("skipped: %s (%s)" % (result.path, result.detail), file=stderr)
        elif result.status is Status.OVERWRITTEN:
            print("overwritten: %s" % result.path, file=stdout)
        elif result.status is Status.WRITTEN:
            print("written: %s" % result.path, file=stdout)
        elif result.status is Status.UNCHANGED:
            print("unchanged: %s" % result.path, file=stdout)
    if outcome.unterminated > 0:
        print("warning: %d unterminated block(s) ignored" % outcome.unterminated, file=stderr)
    print("restored: %d written, %d overwritten, %d unchanged, %d skipped" % (
        outcome.count(Status.WRITTEN),
        outcome.count(Status.OVERWRITTEN),
        outcome.count(Status.UNCHANGED),
        outcome.count(Status.SKIPPED),
    ), file=stdout)
    return 0 if outcome.error_count() == 0 else 1


def run(args, stdout=sys.stdout, stderr=sys.stderr):
    if not args or args[0] in ("-h", "--help", "help"):
        stdout.write(HELP)
        return 0
    command = args[0]
    if command == "bundle":
        return cmd_bundle(args[1:], stdout, stderr)
    if command == "unbundle":
        return cmd_unbundle(args[1:], stdout, stderr)
    print("error: unknown command '%s'" % command, file=stderr)
    stderr.write(HELP)
    return 2


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
