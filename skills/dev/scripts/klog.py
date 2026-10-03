#!/usr/bin/env python3
r"""klog - failure knowledge base for the dev skill.

Captures failing/warning shell commands through a PTY runner, curates them
into `symptom | cause | fix` entries, greps across the session scratch log
and the skill's shipped database, and exports scratch entries into a merged
database copy at session end.

Storage:
  scratch (session, writable): $KLOG_SCRATCH (default /mnt/agents/failure-log)
    inbox.jsonl    raw captures produced by `run`
    entries.jsonl  curated entries (`add`/`promote`) and overlays (`fix`/`bump`
                   applied to a shipped DB entry copy it here as an overlay)
    export/        default output of `export`
  database (shipped, read-only): $KLOG_DB (default <skill>/references/failure-db)
    <category>.txt header line `[display name]`, then one entry per line:
      `ID (xn) | symptom | cause | fix`   (`(xn)` shown only when hits > 1)
      literal backslash / pipe / newline escaped as `\\`, `\|`, `\n`

The shipped DB may live on a read-only mount: nothing writes to it. `export`
merges scratch into a fresh copy under the output directory; the wrap-up flow
then swaps that copy into a skill working copy and repackages the skill.
"""

import argparse
import json
import os
import pty
import re
import select
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
DB_DIR = Path(os.environ.get("KLOG_DB", str(SKILL_DIR / "references" / "failure-db")))
SCRATCH_DIR = Path(os.environ.get("KLOG_SCRATCH", "/mnt/agents/failure-log"))
INBOX = SCRATCH_DIR / "inbox.jsonl"
ENTRIES = SCRATCH_DIR / "entries.jsonl"
EXPORT_DIR = SCRATCH_DIR / "export"

SIM_WARN = 0.5     # warn on add/promote when a similar entry exists
SIM_MERGE = 0.6    # auto-merge on export at or above this containment score
PROMOTE_HITS = 3   # entries at this hit count are SKILL.md promotion candidates
MAX_CAPTURE = 12000  # chars of command output kept per raw capture
SYMPTOM_MAX = 240

WARNING_RE = re.compile(r"(?i)(?:^|\s)(?:warning|deprecat\w*)\s*:")
ERROR_LINE_RE = re.compile(r"(?i)\berror\b\s*:")
ANSI_RE = re.compile(
    r"\x1b\[[0-9;?]*[a-zA-Z]"                # CSI sequences (colors, cursor)
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"    # OSC sequences
    r"|\x1b[()][0-2]"                        # charset selections
)
ID_RE = re.compile(r"^([A-Z]+-\d+)(?: \(×(\d+)\))? \| (.*)$")
ENTRY_ID_RE = re.compile(r"^([A-Z]+)-(\d+)$")


# ---------------------------------------------------------------------------
# text hygiene

def sanitize(text):
    """Strip ANSI codes and normalize line endings of captured output."""
    text = ANSI_RE.sub("", text)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = "\n".join(ln.rstrip() for ln in text.split("\n"))
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip("\n")


def esc(text):
    """Escape a field for storage in a pipe-delimited DB line."""
    return text.replace("\\", "\\\\").replace("|", "\\|").replace("\n", "\\n")


def unesc(text):
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            n = text[i + 1]
            if n == "n":
                out.append("\n")
            elif n in ("\\", "|"):
                out.append(n)
            else:
                out.append(c)
                out.append(n)
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def split_fields(text):
    """Split an escaped DB payload on unescaped ` | ` delimiters."""
    fields, buf = [], []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            buf.append(text[i:i + 2])
            i += 2
        elif text[i:i + 3] == " | ":
            fields.append("".join(buf))
            buf = []
            i += 3
        else:
            buf.append(c)
            i += 1
    fields.append("".join(buf))
    return [unesc(f).strip() for f in fields]


def trim_capture(text):
    if len(text) <= MAX_CAPTURE:
        return text
    half = MAX_CAPTURE // 2
    return text[:half] + "\n...[trimmed]...\n" + text[-half:]


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# persistence: scratch jsonl

def load_jsonl(path):
    if not path.exists():
        return []
    rows = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                rows.append(json.loads(ln))
    return rows


def append_jsonl(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, ensure_ascii=False) + "\n")


def rewrite_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------------------
# persistence: database txt files

def render_entry(e):
    hits = f" (×{e['hits']})" if e.get("hits", 1) > 1 else ""
    return "{} | {} | {} | {}".format(
        e["id"] + hits, esc(e["symptom"]), esc(e.get("cause", "")), esc(e.get("fix", ""))
    )


def parse_db_line(line):
    m = ID_RE.match(line)
    if not m:
        return None
    fields = split_fields(m.group(3))
    while len(fields) < 3:
        fields.append("")
    return {
        "id": m.group(1),
        "hits": int(m.group(2) or 1),
        "symptom": fields[0],
        "cause": fields[1],
        "fix": fields[2],
    }


def load_db(db_dir):
    """{slug: {"name", "entries", "path"}} for every *.txt in db_dir."""
    db = {}
    if not db_dir.exists():
        return db
    for path in sorted(db_dir.glob("*.txt")):
        name = path.stem.replace("-", " ")
        entries = []
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        if lines and lines[0].startswith("[") and lines[0].endswith("]"):
            name = lines[0][1:-1]
        for lineno, ln in enumerate(lines[1:], 2):
            ln = ln.strip()
            if ln:
                e = parse_db_line(ln)
                if e:
                    e["lineno"] = lineno
                    entries.append(e)
        db[path.stem] = {"name": name, "entries": entries, "path": path}
    return db


def write_db_file(cat_dir, slug, cat):
    path = cat_dir / f"{slug}.txt"
    lines = ["[{}]".format(cat["name"])]
    lines.extend(render_entry(e) for e in cat["entries"])
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def cat_slug(name):
    slug = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return slug or "misc"


def id_prefix(cat):
    parts = [p for p in re.split(r"[^a-z0-9]+", cat.lower()) if p]
    return ("".join(p[0] for p in parts)[:3] or "X").upper()


def next_id(cat, scratch_entries, db):
    """Next stable ID for a category: max over scratch + shipped DB, +1."""
    prefix = None
    highest = 0
    candidates = [e for e in scratch_entries if e["cat"] == cat]
    if cat in db:
        candidates += db[cat]["entries"]
    for e in candidates:
        m = ENTRY_ID_RE.match(e["id"])
        if m:
            if prefix is None:
                prefix = m.group(1)
            highest = max(highest, int(m.group(2)))
    return "{}-{:03d}".format(prefix or id_prefix(cat), highest + 1)


def merged_view(db):
    """DB entries overlaid by scratch entries sharing their ID, then
    scratch-only entries. Each item: (entry, source) where source is
    'db:<slug>:<line>' or 'scratch'."""
    scratch = load_jsonl(ENTRIES)
    overlay_ids = {e["id"] for e in scratch}
    view = []
    for slug, cat in db.items():
        for e in cat["entries"]:
            if e["id"] not in overlay_ids:
                view.append((e, f"db:{slug}:{e.get('lineno', '?')}"))
    for e in scratch:
        src = "scratch-overlay" if any(
            e["id"] == d["id"] for c in db.values() for d in c["entries"]
        ) else "scratch"
        view.append((e, src))
    return view, scratch


# ---------------------------------------------------------------------------
# similarity

def tokens(text):
    text = re.sub(r"/[\w.\-/]+", " ", text.lower())  # drop paths
    toks = re.findall(r"[a-z0-9_]+", text)
    return {t for t in toks if len(t) > 1 and not t.isdigit()}


def similarity(a, b):
    ta, tb = tokens(a), tokens(b)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / min(len(ta), len(tb))


def best_match(symptom, candidates):
    best, score = None, 0.0
    for e in candidates:
        s = similarity(symptom, e["symptom"])
        if s > score:
            best, score = e, s
    return best, score


def warn_if_similar(entry, db, scratch_entries):
    candidates = [e for e in scratch_entries if e["id"] != entry["id"]]
    if entry["cat"] in db:
        candidates += db[entry["cat"]]["entries"]
    match, score = best_match(entry["symptom"], candidates)
    if match and score >= SIM_WARN:
        print(
            f"klog: note: similar to {match['id']} (score {score:.2f}): "
            f"{match['symptom'][:120]}\n"
            f"      consider `klog.py bump {match['id']}` instead of a duplicate",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------
# capture (run)

def extract_symptom(output):
    lines = [ln.strip() for ln in output.splitlines() if ln.strip()]
    if not lines:
        return "(no output)"
    pick = None
    for ln in lines:
        if ERROR_LINE_RE.search(ln):
            pick = ln
            break
    if pick is None:
        for ln in lines:
            if WARNING_RE.search(ln):
                pick = ln
                break
    if pick is None:
        pick = lines[-1]
    if len(pick) > SYMPTOM_MAX:
        pick = pick[: SYMPTOM_MAX - 1] + "…"
    return pick


def run_command(argv):
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        print("klog run: no command given", file=sys.stderr)
        return 2
    if len(argv) == 1:
        proc_argv = ["bash", "-c", argv[0]]
        display = argv[0]
    else:
        proc_argv = argv
        display = shlex.join(argv)

    master, slave = pty.openpty()
    try:
        proc = subprocess.Popen(
            proc_argv, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
            close_fds=True,
        )
    except FileNotFoundError:
        os.close(master)
        os.close(slave)
        print(f"klog run: command not found: {proc_argv[0]}", file=sys.stderr)
        return 127
    os.close(slave)

    buf = bytearray()
    idle = 0
    while True:
        r, _, _ = select.select([master], [], [], 0.1)
        if master in r:
            idle = 0
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf.extend(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        elif proc.poll() is not None:
            idle += 1
            if idle >= 3:
                break
    os.close(master)
    rc = proc.wait()

    text = sanitize(buf.decode("utf-8", errors="replace"))
    failed = rc != 0
    warned = not failed and bool(WARNING_RE.search(text))
    if failed or warned:
        n = len(load_jsonl(INBOX)) + 1
        append_jsonl(INBOX, {
            "ts": now_iso(),
            "cmd": display,
            "exit": rc,
            "trigger": "exit" if failed else "warning",
            "output": trim_capture(text),
            "promoted": False,
        })
        why = f"exit {rc}" if failed else "warning pattern"
        print(
            f"\nklog: captured as inbox #{n} ({why}). Curate with:\n"
            f"  klog.py promote {n} --cat <category> --cause \"<why it happens>\" "
            f"[--fix \"<fix>\"] [--symptom \"<override>\"]",
            file=sys.stderr,
        )
    return rc


# ---------------------------------------------------------------------------
# curation commands

def make_entry(cat, symptom, cause, fix, db):
    scratch = load_jsonl(ENTRIES)
    entry = {
        "id": next_id(cat, scratch, db),
        "cat": cat,
        "symptom": symptom,
        "cause": cause or "",
        "fix": fix or "",
        "hits": 1,
        "ts": now_iso(),
    }
    warn_if_similar(entry, db, scratch)
    append_jsonl(ENTRIES, entry)
    return entry


def cmd_add(args, db):
    entry = make_entry(args.cat, args.symptom, args.cause, args.fix, db)
    print(f"added {entry['id']} -> scratch ({entry['cat']})")
    print(render_entry(entry))
    return 0


def cmd_promote(args, db):
    inbox = load_jsonl(INBOX)
    idx = args.n - 1
    if idx < 0 or idx >= len(inbox):
        print(f"klog promote: inbox #{args.n} does not exist "
              f"({len(inbox)} entries)", file=sys.stderr)
        return 1
    raw = inbox[idx]
    symptom = args.symptom or extract_symptom(raw["output"])
    entry = make_entry(args.cat, symptom, args.cause, args.fix, db)
    raw["promoted"] = True
    rewrite_jsonl(INBOX, inbox)
    print(f"promoted inbox #{args.n} -> {entry['id']} ({entry['cat']})")
    print(render_entry(entry))
    return 0


def find_entry(eid, db, scratch):
    """Locate an entry by ID. Returns (entry, origin) where origin is
    ('scratch', index) or ('db', slug) or None."""
    for i, e in enumerate(scratch):
        if e["id"] == eid:
            return e, ("scratch", i)
    for slug, cat in db.items():
        for e in cat["entries"]:
            if e["id"] == eid:
                return e, ("db", slug)
    return None, None


def cmd_fix(args, db):
    scratch = load_jsonl(ENTRIES)
    entry, origin = find_entry(args.id, db, scratch)
    if entry is None:
        print(f"klog fix: no entry {args.id}", file=sys.stderr)
        return 1
    if origin[0] == "scratch":
        entry["fix"] = args.fix
        rewrite_jsonl(ENTRIES, scratch)
    else:
        overlay = {k: entry[k] for k in ("id", "symptom", "cause", "fix", "hits")}
        overlay["cat"] = origin[1]
        overlay["fix"] = args.fix
        overlay["ts"] = now_iso()
        append_jsonl(ENTRIES, overlay)
        entry = overlay
        print(f"klog: {args.id} lives in the read-only DB; recorded overlay in scratch")
    print(render_entry(entry))
    return 0


def cmd_bump(args, db):
    scratch = load_jsonl(ENTRIES)
    entry, origin = find_entry(args.id, db, scratch)
    if entry is None:
        print(f"klog bump: no entry {args.id}", file=sys.stderr)
        return 1
    if origin[0] == "scratch":
        entry["hits"] = entry.get("hits", 1) + args.by
        rewrite_jsonl(ENTRIES, scratch)
    else:
        overlay = {k: entry[k] for k in ("id", "symptom", "cause", "fix", "hits")}
        overlay["cat"] = origin[1]
        overlay["hits"] = overlay.get("hits", 1) + args.by
        overlay["ts"] = now_iso()
        append_jsonl(ENTRIES, overlay)
        entry = overlay
        print(f"klog: {args.id} lives in the read-only DB; recorded overlay in scratch")
    print(render_entry(entry))
    return 0


# ---------------------------------------------------------------------------
# retrieval commands

def show_entry(e, source):
    hits = f" (×{e['hits']})" if e.get("hits", 1) > 1 else ""
    fix = e.get("fix", "") or "—"
    print(f"{e['id']}{hits} [{source}]")
    print(f"  symptom: {e['symptom']}")
    print(f"  cause:   {e.get('cause', '') or '—'}")
    print(f"  fix:     {fix}")


def cmd_grep(args, db):
    terms = [t.lower() for t in args.terms]
    view, _ = merged_view(db)
    found = 0
    for e, src in view:
        hay = f"{e['symptom']} {e.get('cause', '')} {e.get('fix', '')}".lower()
        if all(t in hay for t in terms):
            show_entry(e, src)
            found += 1
    if args.inbox:
        for i, raw in enumerate(load_jsonl(INBOX), 1):
            hay = f"{raw['cmd']}\n{raw['output']}".lower()
            if all(t in hay for t in terms):
                mark = "promoted" if raw.get("promoted") else "raw"
                first = extract_symptom(raw["output"])
                print(f"inbox #{i} [{mark}, exit {raw['exit']}] {raw['cmd']}")
                print(f"  {first}")
                found += 1
    if not found:
        print(f"klog: no entries matching {' '.join(args.terms)}")
    return 0


def cmd_pending(args, db):
    view, _ = merged_view(db)
    found = 0
    for e, src in view:
        if not e.get("fix"):
            print(f"{e['id']} [{src}] {e['symptom']}")
            found += 1
    if not found:
        print("klog: no pending entries (everything has a fix)")
    return 0


def cmd_brief(args, db):
    view, _ = merged_view(db)
    by_cat = {}
    for e, src in view:
        by_cat.setdefault(e.get("cat") or _slug_of(db, e), []).append((e, src))
    total = sum(len(v) for v in by_cat.values())
    print(f"klog: {total} entries in {len(by_cat)} categories "
          f"(db: {DB_DIR}, scratch: {SCRATCH_DIR})")
    for cat in sorted(by_cat):
        rows = by_cat[cat]
        open_n = sum(1 for e, _ in rows if not e.get("fix"))
        print(f"\n[{cat}] {len(rows)} entries" + (f", {open_n} open" if open_n else ""))
        for e, src in sorted(rows, key=lambda r: -r[0].get("hits", 1)):
            hits = f" (×{e['hits']})" if e.get("hits", 1) > 1 else ""
            symptom = e["symptom"]
            if len(symptom) > 110:
                symptom = symptom[:109] + "…"
            tag = "*" if src.startswith("scratch") else " "
            print(f" {tag}{e['id']}{hits} {symptom}")
    print("\n(* = session scratch; everything else is shipped DB)")
    return 0


def _slug_of(db, entry):
    for slug, cat in db.items():
        if entry in cat["entries"]:
            return slug
    return "?"


# ---------------------------------------------------------------------------
# export (session wrap-up)

def cmd_export(args, db):
    scratch = load_jsonl(ENTRIES)
    out_dir = Path(args.out) if args.out else EXPORT_DIR

    work = {
        slug: {"name": cat["name"], "entries": [dict(e) for e in cat["entries"]]}
        for slug, cat in db.items()
    }
    db_ids = {e["id"] for c in db.values() for e in c["entries"]}

    new_n = merged_n = overlay_n = 0
    for e in scratch:
        slug = e["cat"]
        if slug not in work:
            work[slug] = {"name": slug.replace("-", " "), "entries": []}
        entries = work[slug]["entries"]
        if e["id"] in db_ids:  # overlay of a shipped entry
            for base in entries:
                if base["id"] == e["id"]:
                    base.update({k: e[k] for k in ("symptom", "cause", "fix")})
                    base["hits"] = e.get("hits", base["hits"])
                    overlay_n += 1
                    print(f"overlay {e['id']} ({slug})")
                    break
            continue
        match, score = best_match(e["symptom"], entries)
        if match and score >= SIM_MERGE:
            match["hits"] = match.get("hits", 1) + e.get("hits", 1)
            if not match.get("cause") and e.get("cause"):
                match["cause"] = e["cause"]
            if not match.get("fix") and e.get("fix"):
                match["fix"] = e["fix"]
            merged_n += 1
            print(f"merged  {e['id']} -> {match['id']} (×{match['hits']}, score {score:.2f})")
        else:
            entries.append(dict(e))
            new_n += 1
            print(f"new     {e['id']} ({slug})")

    if args.dry_run:
        print(f"\ndry run: {new_n} new, {merged_n} merged, {overlay_n} overlays; "
              f"would write {len(work)} category files to {out_dir}")
    else:
        if out_dir.exists():
            shutil.rmtree(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        for slug, cat in sorted(work.items()):
            write_db_file(out_dir, slug, cat)
        archive = SCRATCH_DIR / "archive" / datetime.now().strftime("%Y%m%d-%H%M%S")
        archive.mkdir(parents=True, exist_ok=True)
        for f in (INBOX, ENTRIES):
            if f.exists():
                shutil.move(str(f), archive / f.name)
        print(f"\nwrote {len(work)} category files to {out_dir}")
        print(f"archived scratch to {archive}")
        print(f"next: copy {out_dir}/*.txt over the skill's references/failure-db/, "
              f"then repackage the skill")

    pending = [e["id"] for c in work.values() for e in c["entries"] if not e.get("fix")]
    if pending:
        print(f"\npending fixes: {', '.join(pending)}")
    hot = [e for c in work.values() for e in c["entries"] if e.get("hits", 1) >= PROMOTE_HITS]
    if hot:
        print("promotion candidates (×%d+, consider a 'Known Traps' block in SKILL.md):"
              % PROMOTE_HITS)
        for e in sorted(hot, key=lambda x: -x["hits"]):
            print(f"  {e['id']} (×{e['hits']}) {e['symptom'][:100]}")
    return 0


# ---------------------------------------------------------------------------
# main

def main():
    ap = argparse.ArgumentParser(
        prog="klog.py",
        description="failure knowledge base: capture, curate, grep, export",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("run", help="run a command under a PTY; capture failures/warnings")
    p.add_argument("argv", nargs=argparse.REMAINDER,
                   help="command + args, or one quoted string for compound commands")

    p = sub.add_parser("add", help="add a curated entry to the scratch log")
    p.add_argument("--cat", required=True, help="category slug, e.g. crystal-language-quirks")
    p.add_argument("--symptom", required=True)
    p.add_argument("--cause", default="")
    p.add_argument("--fix", default="")

    p = sub.add_parser("promote", help="curate raw inbox capture #N into an entry")
    p.add_argument("n", type=int)
    p.add_argument("--cat", required=True)
    p.add_argument("--symptom", default=None, help="override the auto-extracted symptom")
    p.add_argument("--cause", default="")
    p.add_argument("--fix", default="")

    p = sub.add_parser("fix", help="set the fix text of an entry (scratch or DB)")
    p.add_argument("id")
    p.add_argument("--fix", required=True)

    p = sub.add_parser("bump", help="increment an entry's hit counter")
    p.add_argument("id")
    p.add_argument("--by", type=int, default=1)

    p = sub.add_parser("grep", help="search entries (all terms must match, case-insensitive)")
    p.add_argument("terms", nargs="+")
    p.add_argument("--inbox", action="store_true", help="also search raw captures")

    sub.add_parser("pending", help="list entries with no fix yet")
    sub.add_parser("brief", help="one-line digest of all entries, grouped by category")

    p = sub.add_parser("export", help="merge scratch into a fresh DB copy (wrap-up)")
    p.add_argument("--out", default=None, help=f"output dir (default {EXPORT_DIR})")
    p.add_argument("--dry-run", action="store_true")

    args = ap.parse_args()
    db = load_db(DB_DIR)

    if args.cmd == "run":
        return run_command(args.argv)
    return {
        "add": cmd_add,
        "promote": cmd_promote,
        "fix": cmd_fix,
        "bump": cmd_bump,
        "grep": cmd_grep,
        "pending": cmd_pending,
        "brief": cmd_brief,
        "export": cmd_export,
    }[args.cmd](args, db) if args.cmd != "run" else 0


if __name__ == "__main__":
    sys.exit(main())
