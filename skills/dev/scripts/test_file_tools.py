# test_file_tools.py
import os
import random
import string
import subprocess
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent
PROJECT = TOOLS / "project_bundler.py"
ADD, BUNDLE, UNBUNDLE = "add", "bundle", "unbundle"


def run(tool, *args, cwd, timeout=120):
    return subprocess.run(
        [sys.executable, str(PROJECT), tool, *map(str, args)],
        cwd=cwd, capture_output=True, text=True, timeout=timeout,
    )


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        path.write_bytes(content)
    else:
        path.write_text(content, encoding="utf-8")
    return path


def read(path):
    return path.read_text(encoding="utf-8")


class TestAddStyles:
    @pytest.mark.parametrize("name,content,expected", [
        ("a.py", "x = 1\n", "# a.py\nx = 1\n"),
        ("a.sh", "echo hi\n", "# a.sh\necho hi\n"),
        ("a.rb", "puts 1\n", "# a.rb\nputs 1\n"),
        ("a.yaml", "k: v\n", "# a.yaml\nk: v\n"),
        ("a.toml", "k = 1\n", "# a.toml\nk = 1\n"),
        ("a.go", "package main\n", "// a.go\npackage main\n"),
        ("a.rs", "fn main() {}\n", "// a.rs\nfn main() {}\n"),
        ("a.c", "int main;\n", "// a.c\nint main;\n"),
        ("a.java", "class A {}\n", "// a.java\nclass A {}\n"),
        ("a.ts", "let x: number;\n", "// a.ts\nlet x: number;\n"),
        ("a.sql", "SELECT 1;\n", "-- a.sql\nSELECT 1;\n"),
        ("a.lua", "local x = 1\n", "-- a.lua\nlocal x = 1\n"),
        ("a.hs", "main = pure ()\n", "-- a.hs\nmain = pure ()\n"),
        ("a.lisp", "(print 1)\n", "; a.lisp\n(print 1)\n"),
        ("a.ini", "[s]\nk=v\n", "; a.ini\n[s]\nk=v\n"),
        ("a.tex", "\\documentclass{article}\n", "% a.tex\n\\documentclass{article}\n"),
        ("a.erl", "-module(a).\n", "% a.erl\n-module(a).\n"),
        ("a.vim", "set number\n", '" a.vim\nset number\n'),
        ("a.bat", "@echo off\n", "REM a.bat\n@echo off\n"),
        ("Makefile", "all:\n\techo\n", "# Makefile\nall:\n\techo\n"),
        ("makefile", "all:\n\techo\n", "# makefile\nall:\n\techo\n"),
        ("GNUmakefile", "all:\n\techo\n", "# GNUmakefile\nall:\n\techo\n"),
        ("Dockerfile", "FROM alpine\n", "# Dockerfile\nFROM alpine\n"),
        ("Dockerfile.dev", "FROM alpine\n", "# Dockerfile.dev\nFROM alpine\n"),
        ("app.dockerfile", "FROM alpine\n", "# app.dockerfile\nFROM alpine\n"),
        ("CMakeLists.txt", "project(x)\n", "# CMakeLists.txt\nproject(x)\n"),
        (".gitignore", "*.pyc\n", "# .gitignore\n*.pyc\n"),
        (".env", "A=1\n", "# .env\nA=1\n"),
        ("Rakefile", "task :x\n", "# Rakefile\ntask :x\n"),
        ("build.mk", "x:\n\techo\n", "# build.mk\nx:\n\techo\n"),
    ])
    def test_comment_style(self, tmp_path, name, content, expected):
        write(tmp_path / name, content)
        result = run(ADD, ".", cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert read(tmp_path / name) == expected
        assert "added: 1" in result.stdout

    def test_unknown_extension_skipped(self, tmp_path):
        write(tmp_path / "data.xyz", "stuff\n")
        result = run(ADD, ".", cwd=tmp_path)
        assert result.returncode == 0
        assert read(tmp_path / "data.xyz") == "stuff\n"
        assert "skipped: 1" in result.stdout

    def test_extensionless_unknown_skipped(self, tmp_path):
        write(tmp_path / "README", "hello\n")
        result = run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "README") == "hello\n"


class TestAddInsertionPoint:
    def test_shebang(self, tmp_path):
        write(tmp_path / "s.py", "#!/usr/bin/env python3\nimport os\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "s.py") == "#!/usr/bin/env python3\n# s.py\nimport os\n"

    def test_shebang_only(self, tmp_path):
        write(tmp_path / "s.sh", "#!/bin/sh\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "s.sh") == "#!/bin/sh\n# s.sh\n"

    def test_encoding_cookie_with_shebang(self, tmp_path):
        write(tmp_path / "c.py", "#!/usr/bin/env python3\n# -*- coding: latin-1 -*-\nx = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "c.py") == (
            "#!/usr/bin/env python3\n# -*- coding: latin-1 -*-\n# c.py\nx = 1\n"
        )

    def test_encoding_cookie_without_shebang(self, tmp_path):
        write(tmp_path / "c.py", "# -*- coding: utf-8 -*-\nx = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "c.py") == "# -*- coding: utf-8 -*-\n# c.py\nx = 1\n"

    def test_cookie_not_pushed_to_line_three(self, tmp_path):
        write(tmp_path / "c.py", "#!/usr/bin/env python3\n# coding: latin-1\nx = 1\n")
        run(ADD, ".", cwd=tmp_path)
        lines = read(tmp_path / "c.py").splitlines()
        assert lines[1] == "# coding: latin-1"
        assert lines[2] == "# c.py"

    def test_rust_inner_attribute_not_shebang(self, tmp_path):
        write(tmp_path / "lib.rs", "#![allow(dead_code)]\nfn main() {}\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "lib.rs") == "// lib.rs\n#![allow(dead_code)]\nfn main() {}\n"

    def test_go_build_tag(self, tmp_path):
        write(tmp_path / "main.go", "//go:build linux\n\npackage main\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "main.go") == "// main.go\n//go:build linux\n\npackage main\n"

    def test_license_header_pushed_not_replaced(self, tmp_path):
        write(tmp_path / "a.py", "# Copyright 2024 Acme\nx = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "a.py") == "# a.py\n# Copyright 2024 Acme\nx = 1\n"

    def test_todo_comment_not_treated_as_path(self, tmp_path):
        write(tmp_path / "a.py", "# TODO: fix x/y\nx = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "a.py") == "# a.py\n# TODO: fix x/y\nx = 1\n"

    def test_other_filename_comment_not_replaced(self, tmp_path):
        write(tmp_path / "main.py", "# other.py\nx = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "main.py") == "# main.py\n# other.py\nx = 1\n"

    def test_lua_long_comment_not_treated_as_path(self, tmp_path):
        write(tmp_path / "a.lua", "--[[ module ]]\nlocal x = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "a.lua") == "-- a.lua\n--[[ module ]]\nlocal x = 1\n"

    def test_empty_file(self, tmp_path):
        write(tmp_path / "e.py", "")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "e.py") == "# e.py\n"

    def test_only_newlines(self, tmp_path):
        write(tmp_path / "e.py", "\n\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "e.py") == "# e.py\n\n\n"

    def test_no_trailing_newline_preserved(self, tmp_path):
        write(tmp_path / "n.py", "x = 1")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "n.py") == "# n.py\nx = 1"


class TestAddReplaceMove:
    def test_correct_comment_unchanged(self, tmp_path):
        write(tmp_path / "a.py", "# a.py\nx = 1\n")
        result = run(ADD, ".", cwd=tmp_path)
        assert "unchanged: 1" in result.stdout
        assert read(tmp_path / "a.py") == "# a.py\nx = 1\n"

    def test_stale_comment_replaced(self, tmp_path):
        write(tmp_path / "a.py", "# old/dir/a.py\nx = 1\n")
        result = run(ADD, ".", cwd=tmp_path)
        assert "replaced: 1" in result.stdout
        assert read(tmp_path / "a.py") == "# a.py\nx = 1\n"

    def test_misplaced_above_shebang_moved(self, tmp_path):
        write(tmp_path / "s.sh", "# s.sh\n#!/bin/bash\necho hi\n")
        result = run(ADD, ".", cwd=tmp_path)
        assert "moved: 1" in result.stdout
        assert read(tmp_path / "s.sh") == "#!/bin/bash\n# s.sh\necho hi\n"

    def test_nested_path_comment(self, tmp_path):
        write(tmp_path / "sub" / "deep" / "a.py", "x = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "sub" / "deep" / "a.py") == "# sub/deep/a.py\nx = 1\n"

    def test_nested_stale_replaced_with_relative(self, tmp_path):
        write(tmp_path / "sub" / "a.py", "# a.py\nx = 1\n")
        result = run(ADD, ".", cwd=tmp_path)
        assert "replaced: 1" in result.stdout
        assert read(tmp_path / "sub" / "a.py") == "# sub/a.py\nx = 1\n"

    def test_idempotent_second_run(self, tmp_path):
        write(tmp_path / "a.py", "x = 1\n")
        write(tmp_path / "b.go", "package b\n")
        run(ADD, ".", cwd=tmp_path)
        first_a = read(tmp_path / "a.py")
        first_b = read(tmp_path / "b.go")
        result = run(ADD, ".", cwd=tmp_path)
        assert "added: 0" in result.stdout
        assert "unchanged: 2" in result.stdout
        assert read(tmp_path / "a.py") == first_a
        assert read(tmp_path / "b.go") == first_b


class TestAddRobustness:
    def test_crlf_preserved(self, tmp_path):
        write(tmp_path / "w.c", b"int a;\r\nint b;\r\n")
        run(ADD, ".", cwd=tmp_path)
        assert (tmp_path / "w.c").read_bytes() == b"// w.c\r\nint a;\r\nint b;\r\n"

    def test_mixed_endings_normalized_to_crlf(self, tmp_path):
        write(tmp_path / "w.c", b"int a;\nint b;\r\n")
        run(ADD, ".", cwd=tmp_path)
        assert (tmp_path / "w.c").read_bytes() == b"// w.c\r\nint a;\r\nint b;\r\n"

    def test_bom_preserved(self, tmp_path):
        write(tmp_path / "b.py", "﻿x = 1\n".encode("utf-8"))
        run(ADD, ".", cwd=tmp_path)
        data = (tmp_path / "b.py").read_bytes()
        assert data.startswith(b"\xef\xbb\xbf# b.py\n")

    def test_binary_skipped(self, tmp_path):
        write(tmp_path / "bin.py", b"x = 1\x00\x02\x03")
        result = run(ADD, ".", cwd=tmp_path)
        assert (tmp_path / "bin.py").read_bytes() == b"x = 1\x00\x02\x03"
        assert "skipped: 1" in result.stdout

    def test_non_utf8_skipped(self, tmp_path):
        write(tmp_path / "latin.py", "x = 'é'\n".encode("latin-1"))
        result = run(ADD, ".", cwd=tmp_path)
        assert (tmp_path / "latin.py").read_bytes() == "x = 'é'\n".encode("latin-1")
        assert "skipped: 1" in result.stdout

    def test_symlink_file_skipped(self, tmp_path):
        outside = tmp_path / "outside"
        real = write(outside / "real.py", "x = 1\n")
        work = tmp_path / "work"
        work.mkdir()
        os.symlink(real, work / "link.py")
        run(ADD, ".", cwd=work)
        assert read(real) == "x = 1\n"

    def test_symlink_dir_skipped(self, tmp_path):
        outside = tmp_path / "outside"
        write(outside / "a.py", "x = 1\n")
        work = tmp_path / "work"
        work.mkdir()
        os.symlink(outside, work / "linked")
        run(ADD, ".", cwd=work)
        assert read(outside / "a.py") == "x = 1\n"

    @pytest.mark.parametrize("skipdir", [
        ".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build", "target",
    ])
    def test_skip_dirs(self, tmp_path, skipdir):
        write(tmp_path / skipdir / "a.py", "x = 1\n")
        result = run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / skipdir / "a.py") == "x = 1\n"
        assert "added: 0" in result.stdout

    def test_executable_bit_preserved(self, tmp_path):
        script = write(tmp_path / "run.sh", "#!/bin/sh\necho x\n")
        script.chmod(0o755)
        run(ADD, ".", cwd=tmp_path)
        assert script.stat().st_mode & 0o111

    def test_readonly_directory_reports_error(self, tmp_path):
        ro = tmp_path / "ro"
        write(ro / "a.py", "x = 1\n")
        ro.chmod(0o555)
        try:
            result = run(ADD, "ro", cwd=tmp_path)
            assert result.returncode == 1
            assert "error" in result.stderr.lower() or "error" in result.stdout.lower()
        finally:
            ro.chmod(0o755)

    def test_path_with_spaces(self, tmp_path):
        write(tmp_path / "my dir" / "a file.py", "x = 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "my dir" / "a file.py") == "# my dir/a file.py\nx = 1\n"
        result = run(ADD, ".", cwd=tmp_path)
        assert "unchanged: 1" in result.stdout

    def test_unicode_filename_and_content(self, tmp_path):
        write(tmp_path / "café.py", "x = 'héllo'\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "café.py") == "# café.py\nx = 'héllo'\n"

    def test_file_outside_cwd_gets_absolute_path(self, tmp_path):
        work = tmp_path / "work"
        work.mkdir()
        target = write(tmp_path / "out.py", "x = 1\n")
        run(ADD, str(target), cwd=work)
        assert read(target) == f"# {target}\nx = 1\n"

    def test_dry_run_writes_nothing(self, tmp_path):
        write(tmp_path / "a.py", "x = 1\n")
        result = run(ADD, ".", "--dry-run", cwd=tmp_path)
        assert result.returncode == 0
        assert "[dry run]" in result.stdout
        assert "added: 1" in result.stdout
        assert read(tmp_path / "a.py") == "x = 1\n"

    def test_verbose_shows_skipped_and_unchanged(self, tmp_path):
        write(tmp_path / "a.py", "# a.py\nx = 1\n")
        write(tmp_path / "b.xyz", "data\n")
        result = run(ADD, ".", "-v", cwd=tmp_path)
        assert "unchanged" in result.stdout
        assert "skipped" in result.stdout

    def test_multiple_dirs(self, tmp_path):
        write(tmp_path / "one" / "a.py", "x = 1\n")
        write(tmp_path / "two" / "b.py", "y = 2\n")
        result = run(ADD, "one", "two", cwd=tmp_path)
        assert result.returncode == 0
        assert read(tmp_path / "one" / "a.py") == "# one/a.py\nx = 1\n"
        assert read(tmp_path / "two" / "b.py") == "# two/b.py\ny = 2\n"

    def test_single_file_argument(self, tmp_path):
        write(tmp_path / "a.py", "x = 1\n")
        write(tmp_path / "b.py", "y = 2\n")
        run(ADD, "a.py", cwd=tmp_path)
        assert read(tmp_path / "a.py") == "# a.py\nx = 1\n"
        assert read(tmp_path / "b.py") == "y = 2\n"

    def test_nonexistent_path_errors(self, tmp_path):
        result = run(ADD, "nope", cwd=tmp_path)
        assert result.returncode == 1

    def test_no_arguments_is_usage_error(self, tmp_path):
        result = run(ADD, cwd=tmp_path)
        assert result.returncode == 2

    def test_help_works(self, tmp_path):
        assert run(ADD, "--help", cwd=tmp_path).returncode == 0


class TestBundle:
    @pytest.mark.parametrize("name,comment,language", [
        ("a.py", "# a.py", "py"),
        ("a.yml", "# a.yml", "yaml"),
        ("a.yaml", "# a.yaml", "yaml"),
        ("a.cr", "# a.cr", "crystal"),
        ("a.ex", "# a.ex", "elixir"),
        ("a.jl", "# a.jl", "julia"),
        ("a.ps1", "# a.ps1", "powershell"),
        ("a.m", "// a.m", "objectivec"),
        ("a.hpp", "// a.hpp", "cpp"),
        ("a.mjs", "// a.mjs", "javascript"),
        ("a.kt", "// a.kt", "kotlin"),
        ("a.clj", "; a.clj", "clojure"),
        ("a.erl", "% a.erl", "erlang"),
        ("a.fs", "// a.fs", "fsharp"),
        ("a.tex", "% a.tex", "latex"),
        ("a.tf", "# a.tf", "hcl"),
        ("Makefile", "# Makefile", "makefile"),
        ("Dockerfile", "# Dockerfile", "dockerfile"),
        ("CMakeLists.txt", "# CMakeLists.txt", "cmake"),
        ("Rakefile", "# Rakefile", "ruby"),
        (".gitignore", "# .gitignore", "gitignore"),
    ])
    def test_fence_languages(self, tmp_path, name, comment, language):
        write(tmp_path / name, f"{comment}\ncontent\n")
        result = run(BUNDLE, ".", cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert f"```{language}\n{comment}\ncontent\n```" in read(tmp_path / "bundle.md")

    def test_only_path_comment_files_bundled(self, tmp_path):
        write(tmp_path / "a.py", "# a.py\nx = 1\n")
        write(tmp_path / "b.py", "y = 2\n")
        result = run(BUNDLE, ".", "--no-add", cwd=tmp_path)
        assert "bundled: 1" in result.stdout
        bundle = read(tmp_path / "bundle.md")
        assert "# a.py" in bundle
        assert "y = 2" not in bundle

    def test_fence_widens_for_backticks(self, tmp_path):
        write(tmp_path / "f.py", "# f.py\nx = '''\n```python\nnested\n```\n'''\n".replace("'''", '"""'))
        run(BUNDLE, ".", cwd=tmp_path)
        bundle = read(tmp_path / "bundle.md")
        assert "````py\n" in bundle
        assert "\n````" in bundle

    def test_fence_widens_beyond_four(self, tmp_path):
        write(tmp_path / "f.py", "# f.py\nx = '````'\n")
        run(BUNDLE, ".", cwd=tmp_path)
        assert "`````py\n" in read(tmp_path / "bundle.md")

    def test_crlf_normalized_in_bundle(self, tmp_path):
        write(tmp_path / "w.c", b"// w.c\r\nint a;\r\n")
        run(BUNDLE, ".", cwd=tmp_path)
        assert b"\r" not in (tmp_path / "bundle.md").read_bytes()

    def test_missing_trailing_newline_fixed(self, tmp_path):
        write(tmp_path / "n.lua", "-- n.lua\nlocal x = 1")
        run(BUNDLE, ".", cwd=tmp_path)
        assert "-- n.lua\nlocal x = 1\n```" in read(tmp_path / "bundle.md")

    def test_binary_and_non_utf8_skipped(self, tmp_path):
        write(tmp_path / "bin.py", b"\x00\x01\x02")
        write(tmp_path / "latin.py", "x = 'é'\n".encode("latin-1"))
        result = run(BUNDLE, ".", "--no-add", "-v", cwd=tmp_path)
        assert "no files with path comments found" in result.stdout
        assert result.stderr.count("skipped") + result.stdout.count("skipped") >= 2

    def test_no_matching_files_writes_nothing(self, tmp_path):
        write(tmp_path / "a.py", "x = 1\n")
        result = run(BUNDLE, ".", "--no-add", cwd=tmp_path)
        assert result.returncode == 0
        assert "no files with path comments found" in result.stdout
        assert not (tmp_path / "bundle.md").exists()

    def test_custom_output(self, tmp_path):
        write(tmp_path / "a.py", "# a.py\nx = 1\n")
        run(BUNDLE, ".", "-o", "out.md", cwd=tmp_path)
        assert (tmp_path / "out.md").exists()
        assert not (tmp_path / "bundle.md").exists()

    def test_unwritable_output_errors(self, tmp_path):
        write(tmp_path / "a.py", "# a.py\nx = 1\n")
        result = run(BUNDLE, ".", "-o", "no/such/dir/out.md", cwd=tmp_path)
        assert result.returncode == 1

    def test_bundle_not_self_included(self, tmp_path):
        write(tmp_path / "a.py", "# a.py\nx = 1\n")
        run(BUNDLE, ".", cwd=tmp_path)
        result = run(BUNDLE, ".", cwd=tmp_path)
        assert "bundled: 1" in result.stdout

    def test_sorted_order(self, tmp_path):
        write(tmp_path / "z.py", "# z.py\n1\n")
        write(tmp_path / "a.py", "# a.py\n2\n")
        write(tmp_path / "sub" / "m.py", "# sub/m.py\n3\n")
        run(BUNDLE, ".", cwd=tmp_path)
        bundle = read(tmp_path / "bundle.md")
        assert bundle.index("# a.py") < bundle.index("# z.py") < bundle.index("# sub/m.py")

    def test_bom_stripped_in_bundle(self, tmp_path):
        write(tmp_path / "b.py", "﻿# b.py\nx = 1\n".encode("utf-8"))
        run(BUNDLE, ".", cwd=tmp_path)
        assert not (tmp_path / "bundle.md").read_bytes().startswith(b"\xef\xbb\xbf")

    def test_skip_dirs_respected(self, tmp_path):
        write(tmp_path / "node_modules" / "a.js", "// node_modules/a.js\n1\n")
        result = run(BUNDLE, ".", cwd=tmp_path)
        assert "no files with path comments found" in result.stdout
        assert not (tmp_path / "bundle.md").exists()


class TestUnbundle:
    def make_bundle(self, tmp_path, blocks):
        parts = []
        for language, content in blocks:
            parts.append(f"```{language}\n{content}\n```")
        return write(tmp_path / "bundle.md", "\n\n".join(parts) + "\n")

    def test_basic_restore(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [
            ("py", "# a.py\nx = 1"),
            ("lua", "-- sub/nested.lua\nlocal x = 1"),
            ("makefile", "# Makefile\nall:\n\techo"),
        ])
        out = tmp_path / "out"
        result = run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert read(out / "a.py") == "# a.py\nx = 1\n"
        assert read(out / "sub" / "nested.lua") == "-- sub/nested.lua\nlocal x = 1\n"
        assert read(out / "Makefile") == "# Makefile\nall:\n\techo\n"
        assert "written: 3" in result.stdout

    def test_shebang_preserved_in_block(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("sh", "#!/bin/sh\n# tool.sh\necho hi")])
        out = tmp_path / "out"
        run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert read(out / "tool.sh") == "#!/bin/sh\n# tool.sh\necho hi\n"

    def test_absolute_path_rejected(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("py", "# /tmp/evil_abs.py\nx = 1")])
        result = run(UNBUNDLE, bundle, "-o", tmp_path / "out", cwd=tmp_path)
        assert "skipped: 1" in result.stdout
        assert not Path("/tmp/evil_abs.py").exists()

    def test_dotdot_rejected(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("py", "# ../escape.py\nx = 1")])
        out = tmp_path / "out"
        run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert not (tmp_path / "escape.py").exists()
        assert not (out / "escape.py").exists()

    def test_symlink_escape_rejected(self, tmp_path):
        outside = tmp_path / "outside"
        outside.mkdir()
        out = tmp_path / "out"
        out.mkdir()
        os.symlink(outside, out / "link")
        bundle = self.make_bundle(tmp_path, [("py", "# link/evil.py\nx = 1")])
        result = run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert "escapes output directory" in result.stderr
        assert not (outside / "evil.py").exists()

    def test_backslash_path_normalized(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("py", "# sub\\win.py\nx = 1")])
        out = tmp_path / "out"
        run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert read(out / "sub" / "win.py") == "# sub\\win.py\nx = 1\n"

    def test_duplicate_block_first_wins(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [
            ("py", "# a.py\nFIRST"),
            ("py", "# a.py\nSECOND"),
        ])
        out = tmp_path / "out"
        result = run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert "duplicate" in result.stderr
        assert "FIRST" in read(out / "a.py")

    def test_block_without_path_comment_skipped(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("py", "x = 1"), ("", "plain text")])
        result = run(UNBUNDLE, bundle, "-o", tmp_path / "out", cwd=tmp_path)
        assert "skipped: 2" in result.stdout

    def test_style_mismatch_rejected(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("go", "# main.go\npackage main")])
        result = run(UNBUNDLE, bundle, "-o", tmp_path / "out", cwd=tmp_path)
        assert "skipped: 1" in result.stdout
        assert not (tmp_path / "out" / "main.go").exists()

    def test_language_tag_mismatch_tolerated(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("javascript", "# a.py\nx = 1")])
        out = tmp_path / "out"
        run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert (out / "a.py").exists()

    def test_unterminated_fence_warned(self, tmp_path):
        write(tmp_path / "bundle.md", "```py\n# a.py\nx = 1\n")
        result = run(UNBUNDLE, tmp_path / "bundle.md", "-o", tmp_path / "out", cwd=tmp_path)
        assert "unterminated" in result.stderr
        assert not (tmp_path / "out" / "a.py").exists()

    def test_tilde_fences(self, tmp_path):
        write(tmp_path / "bundle.md", "~~~py\n# a.py\nx = 1\n~~~\n")
        out = tmp_path / "out"
        run(UNBUNDLE, tmp_path / "bundle.md", "-o", out, cwd=tmp_path)
        assert read(out / "a.py") == "# a.py\nx = 1\n"

    def test_longer_closing_fence_accepted(self, tmp_path):
        write(tmp_path / "bundle.md", "```py\n# a.py\nx = 1\n`````\n")
        out = tmp_path / "out"
        run(UNBUNDLE, tmp_path / "bundle.md", "-o", out, cwd=tmp_path)
        assert (out / "a.py").exists()

    def test_four_backtick_block_with_nested_triple(self, tmp_path):
        write(tmp_path / "bundle.md", "````py\n# f.py\nx = '''\n```\n'''\n````\n".replace("'''", '"""'))
        out = tmp_path / "out"
        run(UNBUNDLE, tmp_path / "bundle.md", "-o", out, cwd=tmp_path)
        assert read(out / "f.py") == "# f.py\nx = \"\"\"\n```\n\"\"\"\n"

    def test_existing_identical_unchanged(self, tmp_path):
        out = tmp_path / "out"
        write(out / "a.py", "# a.py\nx = 1\n")
        bundle = self.make_bundle(tmp_path, [("py", "# a.py\nx = 1")])
        result = run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert "unchanged: 1" in result.stdout

    def test_existing_different_skipped_without_force(self, tmp_path):
        out = tmp_path / "out"
        write(out / "a.py", "local edit\n")
        bundle = self.make_bundle(tmp_path, [("py", "# a.py\nx = 1")])
        result = run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert "--force" in result.stderr
        assert read(out / "a.py") == "local edit\n"

    def test_force_overwrites(self, tmp_path):
        out = tmp_path / "out"
        write(out / "a.py", "local edit\n")
        bundle = self.make_bundle(tmp_path, [("py", "# a.py\nx = 1")])
        result = run(UNBUNDLE, bundle, "-o", out, "--force", cwd=tmp_path)
        assert "overwritten: 1" in result.stdout
        assert read(out / "a.py") == "# a.py\nx = 1\n"

    def test_dry_run_writes_nothing(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("py", "# a.py\nx = 1")])
        out = tmp_path / "out"
        result = run(UNBUNDLE, bundle, "-o", out, "--dry-run", cwd=tmp_path)
        assert "[dry run]" in result.stdout
        assert not (out / "a.py").exists()

    def test_missing_bundle_errors(self, tmp_path):
        result = run(UNBUNDLE, "nope.md", cwd=tmp_path)
        assert result.returncode == 1

    def test_invalid_utf8_bundle_errors(self, tmp_path):
        write(tmp_path / "bad.md", b"\xff\xfe\xff")
        result = run(UNBUNDLE, tmp_path / "bad.md", cwd=tmp_path)
        assert result.returncode == 1

    def test_idempotent_rerun(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("py", "# a.py\nx = 1"), ("go", "// b.go\npackage b")])
        out = tmp_path / "out"
        run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        result = run(UNBUNDLE, bundle, "-o", out, cwd=tmp_path)
        assert "unchanged: 2" in result.stdout
        assert "written: 0" in result.stdout

    def test_default_output_is_cwd(self, tmp_path):
        bundle = self.make_bundle(tmp_path, [("py", "# a.py\nx = 1")])
        work = tmp_path / "work"
        work.mkdir()
        run(UNBUNDLE, bundle, cwd=work)
        assert (work / "a.py").exists()


class TestRoundtrip:
    def normalize(self, text):
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        return text if text.endswith("\n") else text + "\n"

    def test_full_roundtrip(self, tmp_path):
        source = tmp_path / "src"
        files = {
            "a.py": "x = 1\n",
            "script.sh": "#!/bin/sh\necho hi\n",
            "coded.py": "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\nx = 1\n",
            "main.go": "//go:build linux\n\npackage main\n",
            "lib.rs": "#![allow(dead_code)]\nfn main() {}\n",
            "q.sql": "SELECT 1;\n",
            "win.c": "int a;\r\nint b;\r\n",
            "noeol.lua": "local x = 1",
            "empty.lua": "",
            "fences.py": "# fences docstring\nx = \"\"\"\n```\n\"\"\"\n",
            "Makefile": "all:\n\techo\n",
            "sub/deep/nested.ex": "defmodule X do end\n",
            "my dir/spaced.py": "x = 1\n",
        }
        for name, content in files.items():
            write(source / name, content)
        assert run(ADD, ".", cwd=source).returncode == 0
        assert run(BUNDLE, ".", cwd=source).returncode == 0
        restore = tmp_path / "restore"
        result = run(UNBUNDLE, source / "bundle.md", "-o", restore, cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert f"written: {len(files)}" in result.stdout
        for name in files:
            original = self.normalize(read(source / name))
            restored = read(restore / name)
            assert restored == original, f"{name} mismatch"

    def test_roundtrip_after_move(self, tmp_path):
        source = tmp_path / "src"
        write(source / "sub" / "a.py", "x = 1\n")
        run(ADD, ".", cwd=source)
        (source / "sub").rename(source / "renamed")
        run(ADD, ".", cwd=source)
        assert read(source / "renamed" / "a.py") == "# renamed/a.py\nx = 1\n"
        run(BUNDLE, ".", cwd=source)
        restore = tmp_path / "restore"
        run(UNBUNDLE, source / "bundle.md", "-o", restore, cwd=tmp_path)
        assert (restore / "renamed" / "a.py").exists()


class TestFuzzAndStress:
    def test_random_garbage_never_crashes(self, tmp_path):
        rng = random.Random(42)
        extensions = [".py", ".go", ".lua", ".c", ".rs", ".sh", ".sql", ".tex", ".vim", ".bat", ".xyz", ""]
        for i in range(60):
            name = f"f{i}{rng.choice(extensions)}"
            data = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 400)))
            write(tmp_path / name, data)
        for tool in (ADD, BUNDLE):
            result = run(tool, ".", cwd=tmp_path)
            assert result.returncode in (0, 1)
            assert "Traceback" not in result.stderr
        if (tmp_path / "bundle.md").exists():
            result = run(UNBUNDLE, tmp_path / "bundle.md", "-o", tmp_path / "out", cwd=tmp_path)
            assert result.returncode in (0, 1)
            assert "Traceback" not in result.stderr

    def test_random_valid_trees_roundtrip(self, tmp_path):
        rng = random.Random(7)
        extensions = [".py", ".go", ".lua", ".sh", ".sql"]
        source = tmp_path / "src"
        created = []
        for i in range(40):
            depth = rng.randrange(0, 3)
            parts = ["".join(rng.choice(string.ascii_lowercase) for _ in range(5)) for _ in range(depth)]
            name = f"file{i}{rng.choice(extensions)}"
            path = source / Path(*parts) / name
            lines = ["".join(rng.choice(string.printable[:80]) for _ in range(rng.randrange(30))) for _ in range(rng.randrange(1, 10))]
            write(path, "\n".join(lines) + "\n")
            created.append(path)
        assert run(ADD, ".", cwd=source).returncode == 0
        assert run(BUNDLE, ".", cwd=source).returncode == 0
        restore = tmp_path / "restore"
        result = run(UNBUNDLE, source / "bundle.md", "-o", restore, cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        for path in created:
            relative = path.relative_to(source)
            assert (restore / relative).exists(), f"missing {relative}"
            assert read(restore / relative) == read(path), f"content mismatch {relative}"

    def test_stress_large_tree(self, tmp_path):
        source = tmp_path / "src"
        count = 500
        for i in range(count):
            write(source / f"pkg{i % 25}" / f"mod{i}.py", f"x = {i}\n")
        result = run(ADD, ".", cwd=source)
        assert f"added: {count}" in result.stdout
        result = run(BUNDLE, ".", cwd=source)
        assert f"bundled: {count}" in result.stdout
        restore = tmp_path / "restore"
        result = run(UNBUNDLE, source / "bundle.md", "-o", restore, cwd=tmp_path)
        assert f"written: {count}" in result.stdout
        assert "errors: 0" in result.stdout
        assert read(restore / "pkg17" / "mod42.py") == "# pkg17/mod42.py\nx = 42\n"


class TestBundlePreOp:
    def test_bundle_stamps_unstamped_files(self, tmp_path):
        write(tmp_path / "a.py", "x = 1\n")
        write(tmp_path / "sub" / "b.go", "package b\n")
        result = run(BUNDLE, ".", cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert "pre-op add:" in result.stdout
        assert "bundled: 2" in result.stdout
        assert read(tmp_path / "a.py") == "# a.py\nx = 1\n"
        assert read(tmp_path / "sub" / "b.go") == "// sub/b.go\npackage b\n"
        bundle = read(tmp_path / "bundle.md")
        assert "```py\n# a.py\nx = 1\n```" in bundle
        assert "```go\n// sub/b.go\npackage b\n```" in bundle

    def test_preop_idempotent_on_second_bundle(self, tmp_path):
        write(tmp_path / "a.py", "x = 1\n")
        run(BUNDLE, ".", cwd=tmp_path)
        result = run(BUNDLE, ".", cwd=tmp_path)
        assert "added: 0" in result.stdout
        assert "unchanged: 1" in result.stdout
        assert "bundled: 1" in result.stdout

    def test_no_add_skips_unstamped(self, tmp_path):
        write(tmp_path / "a.py", "x = 1\n")
        result = run(BUNDLE, ".", "--no-add", cwd=tmp_path)
        assert "pre-op add:" not in result.stdout
        assert read(tmp_path / "a.py") == "x = 1\n"
        assert not (tmp_path / "bundle.md").exists()

    def test_preop_still_skips_binary(self, tmp_path):
        write(tmp_path / "bin.py", b"\x00\x01\x02")
        write(tmp_path / "a.py", "x = 1\n")
        result = run(BUNDLE, ".", cwd=tmp_path)
        assert "bundled: 1" in result.stdout
        assert (tmp_path / "bin.py").read_bytes() == b"\x00\x01\x02"


class TestCrystalEdgeCases:
    CRYSTAL_DOC = (
        "# Greeter with examples.\n"
        "#\n"
        "# ```crystal\n"
        "# g = Greeter.new\n"
        "# g.hello\n"
        "# ```\n"
        "class Greeter\n"
        "  def hello\n"
        "    puts \"hi\"\n"
        "  end\n"
        "end\n"
    )
    CRYSTAL_HEREDOC = (
        "class Greeter\n"
        "  DOC = <<-MD\n"
        "Raw fences inside a heredoc:\n"
        "\n"
        "```crystal\n"
        "puts 1\n"
        "```\n"
        "  MD\n"
        "end\n"
    )

    def test_crystal_doc_fences_roundtrip(self, tmp_path):
        write(tmp_path / "greeter.cr", self.CRYSTAL_DOC)
        assert run(BUNDLE, ".", cwd=tmp_path).returncode == 0
        assert read(tmp_path / "greeter.cr") == "# greeter.cr\n" + self.CRYSTAL_DOC
        restore = tmp_path / "restore"
        result = run(UNBUNDLE, tmp_path / "bundle.md", "-o", restore, cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert read(restore / "greeter.cr") == "# greeter.cr\n" + self.CRYSTAL_DOC

    def test_crystal_heredoc_raw_fences_roundtrip(self, tmp_path):
        write(tmp_path / "greeter.cr", self.CRYSTAL_HEREDOC)
        assert run(BUNDLE, ".", cwd=tmp_path).returncode == 0
        bundle = read(tmp_path / "bundle.md")
        assert "````crystal\n" in bundle
        restore = tmp_path / "restore"
        result = run(UNBUNDLE, tmp_path / "bundle.md", "-o", restore, cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert read(restore / "greeter.cr") == "# greeter.cr\n" + self.CRYSTAL_HEREDOC

    def test_crystal_shebang(self, tmp_path):
        write(tmp_path / "tool.cr", "#!/usr/bin/env crystal\nputs 1\n")
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "tool.cr") == "#!/usr/bin/env crystal\n# tool.cr\nputs 1\n"

    def test_five_backtick_content_gets_six(self, tmp_path):
        write(tmp_path / "f.cr", "x = \"`````\"\n")
        run(BUNDLE, ".", cwd=tmp_path)
        assert "``````crystal\n" in read(tmp_path / "bundle.md")


class TestLineEndingEdgeCases:
    def test_unicode_line_separators_preserved(self, tmp_path):
        content = "x = 'a\u2028b\u2029c\x0bd\x0ce'\n"
        write(tmp_path / "u.py", content)
        run(ADD, ".", cwd=tmp_path)
        assert read(tmp_path / "u.py") == "# u.py\n" + content

    def test_old_mac_cr_only_endings(self, tmp_path):
        write(tmp_path / "m.py", b"x = 1\ry = 2\r")
        run(ADD, ".", cwd=tmp_path)
        assert (tmp_path / "m.py").read_bytes() == b"# m.py\nx = 1\ny = 2\n"

    def test_crlf_bundle_file_restores_lf(self, tmp_path):
        write(tmp_path / "bundle.md", b"```py\r\n# a.py\r\nx = 1\r\n```\r\n")
        out = tmp_path / "out"
        result = run(UNBUNDLE, tmp_path / "bundle.md", "-o", out, cwd=tmp_path)
        assert result.returncode == 0, result.stderr
        assert (out / "a.py").read_bytes() == b"# a.py\nx = 1\n"


class TestSpecialFiles:
    def test_fifo_skipped_without_hanging(self, tmp_path):
        os.mkfifo(tmp_path / "pipe.py")
        write(tmp_path / "a.py", "x = 1\n")
        result = run(ADD, ".", cwd=tmp_path, timeout=15)
        assert result.returncode == 0
        assert "added: 1" in result.stdout
        result = run(BUNDLE, ".", cwd=tmp_path, timeout=15)
        assert result.returncode == 0
        assert "bundled: 1" in result.stdout

    def test_explicit_fifo_argument_skipped(self, tmp_path):
        os.mkfifo(tmp_path / "pipe.py")
        result = run(ADD, "pipe.py", cwd=tmp_path, timeout=15)
        assert result.returncode == 0
        assert "added: 0" in result.stdout

    def test_unbundle_directory_collision(self, tmp_path):
        out = tmp_path / "out"
        (out / "a.py").mkdir(parents=True)
        write(tmp_path / "bundle.md", "```py\n# a.py\nx = 1\n```\n")
        result = run(UNBUNDLE, tmp_path / "bundle.md", "-o", out, cwd=tmp_path)
        assert result.returncode == 0
        assert "directory exists" in result.stderr
        assert (out / "a.py").is_dir()


class TestTopLevelCLI:
    def test_no_subcommand_is_usage_error(self, tmp_path):
        result = subprocess.run(
            [sys.executable, str(PROJECT)], cwd=tmp_path, capture_output=True, text=True
        )
        assert result.returncode == 2

    def test_top_level_help(self, tmp_path):
        result = subprocess.run(
            [sys.executable, str(PROJECT), "--help"], cwd=tmp_path, capture_output=True, text=True
        )
        assert result.returncode == 0
        assert "add" in result.stdout and "bundle" in result.stdout and "unbundle" in result.stdout

    def test_subcommand_help(self, tmp_path):
        for sub in ("add", "bundle", "unbundle"):
            result = subprocess.run(
                [sys.executable, str(PROJECT), sub, "--help"],
                cwd=tmp_path, capture_output=True, text=True,
            )
            assert result.returncode == 0
