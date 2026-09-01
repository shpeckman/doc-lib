#!/usr/bin/env python3
# scripts/crystal_preflight.py
"""Preflight linter for Crystal: catches the verified pitfalls in
references/crystal-pitfalls.md before they cost a compiler round-trip —
or worse, slip through as silent runtime bugs.

Usage: crystal_preflight.py [--fix] FILE.cr...
Exit 1 if any unfixed findings remain. Rule numbers match the pitfall list.
Auto-fixable: 1, 2, 4, 10, 14, 15. Warn-only: 5, 6, 9, 11, 12, 13, 16.
"""
import re
import sys

ABSTRACT = {"Int": "Int32", "UInt": "UInt32", "Float": "Float64"}
FINDINGS = []


def report(path, n, rule, msg, fixed=False):
    FINDINGS.append((path, n, rule, msg, fixed))


def block_end(lines, i):
    """Index of the line after the matching `end` for a block opened at i."""
    depth = 0
    opener = re.compile(r"^\s*(?:macro|def|class|module|struct|lib|enum|union|"
                        r"if|unless|case|begin|while|until|loop)\b|\bdo\b\s*(?:\|[^|]*\|)?\s*$")
    for j in range(i, len(lines)):
        depth += len(opener.findall(lines[j]))
        depth -= len(re.findall(r"^\s*end\b", lines[j]))
        if depth <= 0 and j > i:
            return j
    return len(lines) - 1


def scan_lib(lines, path, fix):
    i = 0
    while i < len(lines):
        if re.match(r"\s*lib\s+\w", lines[i]):
            end = block_end(lines, i)
            for j in range(i, end + 1):
                m = re.match(r"\s*fun\s+[\w=]+", lines[j])
                if m:
                    new = re.sub(r"(:\s*)\b(Int|UInt|Float)\b(?!\d)",
                                 lambda mo: mo.group(1) + ABSTRACT[mo.group(2)], lines[j])
                    if new != lines[j]:  # #1
                        report(path, j + 1, 1, f"abstract numeric in lib fun: {lines[j].strip()}", fix)
                        if fix:
                            lines[j] = new
            i = end
        i += 1


def scan_rules(lines, path, fix):
    i = 0
    while i < len(lines):
        line = lines[i]

        m = re.search(r"(\w+)\.pointer\.closure\b", line)  # #2
        if m:
            report(path, i + 1, 2, "Proc#pointer.closure is not the API — pass the proc directly", fix)
            if fix:
                lines[i] = line = line.replace(f"{m.group(1)}.pointer.closure", m.group(1))

        if re.search(r"\bTime\.monotonic\b", line):  # #10
            report(path, i + 1, 10, "Time.monotonic is deprecated in 1.21 — use Time.instant", fix)
            if fix:
                lines[i] = line = re.sub(r"\bTime\.monotonic\b", "Time.instant", line)

        if re.match(r"\s*when\s+\w+\s*=(?!=|~)", line):  # #6
            report(path, i + 1, 6, "assignment inside `when` compares the assigned value, "
                                   "rarely intended — restructure as if/else + case")

        m = re.match(r"(?!\s*(?:while|until|#)\b)(\s*)(\S(?:.*?\S)?)\s+(while|until)\s+(\S(?:.*\S)?)\s*$", line)
        if m and " do" not in line and not line.rstrip().endswith(("do", "{", "}")):  # #14
            ind, body, kw, cond = m.groups()
            report(path, i + 1, 14, f"no trailing `{kw}` modifier in Crystal", fix)
            if fix:
                lines[i:i + 1] = [f"{ind}{kw} {cond}", f"{ind}  {body}", f"{ind}end"]
                i += 3
                continue

        m = re.match(r"(\s*)raise\s+([^()]+?),\s*cause\s*:\s*(.+?)\s*$", line)  # #15
        if m:
            ind, first, cause = m.groups()
            head, _, rest = first.partition(",")
            if re.match(r"^[A-Z][\w:]*$", head.strip()) and rest.strip():
                new = f"{ind}raise {head.strip()}.new({rest.strip()}, cause: {cause})"
            else:
                new = f"{ind}raise Exception.new({first.strip()}, cause: {cause})"
            report(path, i + 1, 15, "raise takes no keyword args — wrap in an exception class", fix)
            if fix:
                lines[i] = line = new

        # #4: abstract numerics in union type DECLARATIONS (ivar/property/local).
        # Def parameter restrictions are fine — only declarations error.
        m = re.match(r"\s*(?:@@?\w+|(?:property|getter|setter|class_\w+)\b[^:]*|[a-z_]\w*)\s*:\s*([^=]+?)\s*(=|$)", line)
        if m and not re.match(r"\s*(def|fun)\b", line):
            texpr = m.group(1)
            if "|" in texpr and re.search(r"\b(Int|UInt|Float)\b(?!\d)", texpr):
                report(path, i + 1, 4, f"abstract numeric in union type declaration: {texpr.strip()}", fix)
                if fix:
                    lines[i] = line = line.replace(texpr, re.sub(
                        r"\b(Int|UInt|Float)\b(?!\d)", lambda m2: ABSTRACT[m2.group(1)], texpr), 1)

        if re.search(r"#.*(\{%|\{\{)", line):  # #12
            report(path, i + 1, 12, "macro tag inside `#` comment is still lexed — remove it")

        if re.search(r"\bIO\.select\b", line) and ".total_seconds" in line:  # #9
            report(path, i + 1, 9, "IO.select takes a Time::Span, not total_seconds")

        if re.search(r"(\.bytes\[|\bread_byte\b|\bnext_byte\b|\.to_u8\b)", line) \
                and re.search(r"(==|!=)\s*'.'", line):  # #5
            report(path, i + 1, 5, "UInt8 == Char compiles but is always false — "
                                   "compare to an int (b == 0x5B) or use '['.ord")

        if re.search(r"\bspawn\b.*\{[^}]*\byield\b", line):  # #13, single-line block
            report(path, i + 1, 13, "yield inside a captured block is illegal — "
                                    "name the block (def m(&block)) and call block.call")
        elif re.search(r"\bspawn\s+do\b", line):  # multi-line: look inside the block
            end = block_end(lines, i)
            if any(re.search(r"\byield\b", lines[k]) for k in range(i + 1, end)):
                report(path, i + 1, 13, "yield inside a captured block is illegal — "
                                        "name the block (def m(&block)) and call block.call")
            i = end

        if re.match(r"\s*macro\s+(included|method_missing)\b", line):  # #11
            end = block_end(lines, i)
            body = "\n".join(lines[i:end + 1])
            if "@type.instance_vars" in body and "verbatim" not in body:
                report(path, i + 1, 11, "@type.instance_vars is empty at include time — "
                                        "defer generation with {% verbatim do %}")
            i = end
        i += 1


def scan_bigfloat(lines, path):
    big = set()
    for i, line in enumerate(lines):
        for m in re.finditer(r"(\w+)\s*(?::\s*BigFloat)?\s*=\s*[^=]*\b(?:BigFloat\.new|to_big_f)\b", line):
            big.add(m.group(1))
        m = re.match(r"\s*(?:@?\w+)\s*:\s*BigFloat\b", line)
        if m:
            big.add(line.split(":")[0].strip().lstrip("@"))
        for v in big:
            if re.search(rf"\b{re.escape(v)}\.to_s\([^)]", line):  # #16
                report(path, i + 1, 16, "BigFloat#to_s takes no precision argument")
            if re.search(rf"\b{re.escape(v)}\.precision\b", line):
                report(path, i + 1, 16, "BigFloat has no #precision method")


def process(path, fix):
    lines = open(path).read().splitlines()
    scan_lib(lines, path, fix)
    scan_rules(lines, path, fix)
    scan_bigfloat(lines, path)
    if fix:
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")


def main():
    args = sys.argv[1:]
    fix = "--fix" in args
    files = [a for a in args if a != "--fix"]
    if not files:
        print(__doc__)
        return 2
    for p in files:
        process(p, fix)
    for path, n, rule, msg, fixed in FINDINGS:
        print(f"{path}:{n}: [#{rule}] {msg} [{'fixed' if fixed else 'WARN'}]")
    bad = [f for f in FINDINGS if not f[4]]
    print(f"\n{len(FINDINGS)} finding(s), {len(bad)} unfixed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
