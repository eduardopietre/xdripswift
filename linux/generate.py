#!/usr/bin/env python3
"""Writes the SwiftPM packages that linux/xdrip-linux.sh builds, in one process.

The directives of linux/suites/<suite>.txt are documented in CLAUDE.md and in xdrip-linux.sh. Each
source file is read once and kept in memory, every piece is produced with the functions of
extract.py, and a package is only touched where its content changed (see sync-tree.py), so an
unchanged package is not recompiled.

Two layouts:

- isolated (default): one package per suite in <build>/<suite>, as before. Suites may extract the
  same declarations, which is why they used to be built separately.
- merged (--merged NAME): all given suites in one package <build>/NAME. Requests for the same file
  are combined so nothing is declared twice:
    * a file brought in whole by any suite (`src`) wins over `decl`, `members` and `extract` of that
      file; with `| without`, only names that every suite leaves out (and nobody asks for by
      `decl` or `members`) stay out;
    * `decl` names are merged per file, `members` per type (dropped when the type itself is
      brought in by `decl`), and an `extract` range becomes `decl` of the declarations it holds;
    * a test file is added once, leaving out only tests that every suite leaves out.
  One package means the shared code is compiled once, one test binary is linked and one test
  process runs, instead of one per suite.

Usage:
    generate.py --build DIR [--merged NAME] [--snippet] SUITE [SUITE ...]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SUITES_DIR = os.path.join(HERE, 'suites')
SHIM_MODULES_DIR = os.path.join(HERE, 'shim-modules')
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True  # no __pycache__ in the repository
import extract  # noqa: E402  (extract.py, next to this file)

NETWORKING_HEADER = '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'


class GenerateError(Exception):
    pass


# MARK: - reading suites

_lines_cache = {}


def lines_of(path):
    """The lines of a repository file, read once per run."""
    if path not in _lines_cache:
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            raise GenerateError(f'missing file: {path}')
        with open(full, encoding='utf-8') as f:
            _lines_cache[path] = f.read().split('\n')
    return _lines_cache[path]


def split_names(text):
    """Names in their written order, without repeats (the order of decl output follows it)."""
    names = []
    for name in (part.strip() for part in text.split(',')):
        if name and name not in names:
            names.append(name)
    return tuple(names)


def parse_suite(suite, included, out):
    """Appends the directives of a suite to `out`, following `include` once per package."""
    file = os.path.join(SUITES_DIR, suite + '.txt')
    if not os.path.isfile(file):
        raise GenerateError(f"unknown suite '{suite}' (see: xdrip-linux.sh list)")
    with open(file, encoding='utf-8') as f:
        for raw in f:
            line = raw.split('#', 1)[0].strip()
            if not line:
                continue
            kind, _, rest = line.partition(' ')
            kind, rest = kind.strip(), rest.strip()
            if kind == 'include':
                # Counted like every directive, so piece numbers match the bash generator's.
                out.append(('include', rest, None, None))
                if rest not in included:
                    included.add(rest)
                    parse_suite(rest, included, out)
                continue
            if kind == 'module':
                out.append(('module', rest, None, None))
            elif kind in ('src', 'test'):
                path, _, names = rest.partition('|')
                names = names.strip()
                if names and not names.startswith('without'):
                    raise GenerateError(f"{suite}.txt: expected 'without' after '|' in: {line}")
                out.append((kind, path.strip(), split_names(names[len('without'):]), None))
            elif kind == 'extract':
                parts = [part.strip() for part in rest.split('|')]
                if len(parts) != 3:
                    raise GenerateError(f'{suite}.txt: extract needs <path> | <start> | <end>: {line}')
                out.append(('extract', parts[0], parts[1], parts[2]))
            elif kind in ('decl', 'testdecl'):
                path, _, names = rest.partition('|')
                out.append((kind, path.strip(), split_names(names), None))
            elif kind == 'members':
                parts = [part.strip() for part in rest.split('|')]
                if len(parts) != 3:
                    raise GenerateError(f'{suite}.txt: members needs <path> | <Type> | <names>: {line}')
                out.append(('members', parts[0], parts[1], split_names(parts[2])))
            else:
                raise GenerateError(f"{suite}.txt: unknown directive '{kind}'")
    return out


# MARK: - producing pieces

def flat(path):
    return path.replace('/', '_').replace(' ', '_')


def checked(result, path, what):
    out, found, names = result
    missing = [name for name in names if name not in found]
    if missing:
        raise GenerateError(f'{what}: not found in {path}: {", ".join(missing)}')
    return out


def copy_piece(path, without_names):
    lines = lines_of(path)
    if without_names:
        out, found = extract.without(lines, list(without_names))
        lines = checked((out, found, without_names), path, 'without')
        return NETWORKING_HEADER + '\n'.join(extract.linux_compatible(line) for line in lines) + '\n'
    return NETWORKING_HEADER + '\n'.join(extract.linux_compatible(line) for line in lines)


def decl_piece(path, names):
    out, found = extract.decl(lines_of(path), list(names))
    out = checked((out, found, names), path, 'decl')
    return NETWORKING_HEADER + 'import Foundation\n\n' + '\n'.join(extract.linux_compatible(line) for line in out) + '\n'


def members_piece(path, type_name, names):
    out, found = extract.members(lines_of(path), type_name, sorted(names))
    out = checked((out, found, names), path, f'members of {type_name}')
    return NETWORKING_HEADER + 'import Foundation\n\n' + '\n'.join(extract.linux_compatible(line) for line in out) + '\n'


def extract_range(path, start, end):
    """Lines from the first match of `start` up to, not including, the next match of `end`."""
    start_re, end_re = re.compile(start), re.compile(end)
    out, on = [], False
    for line in lines_of(path):
        if not on and start_re.search(line):
            on = True
        elif on and out and end_re.search(line):
            break
        if on:
            out.append(line)
    if not out:
        raise GenerateError(f'extract matched nothing in {path} (start: {start})')
    return out


TOP_LEVEL = re.compile(rf'^{extract.MODIFIERS}{extract.KEYWORDS}\s+(\w+)')


def declarations_in(lines):
    """Names of the top-level declarations in `lines`, for turning an extract into decl."""
    return {match.group(1) for match in map(TOP_LEVEL.match, lines) if match}


# MARK: - packages

TEST_METHOD = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:override|public|internal|final|nonisolated)\s+)*func\s+test\w*\s*\(\s*\)')


def count_tests(files):
    """Number of XCTest methods (`func testSomething()`) in the test files of a package.

    Counted on code lines, so commented-out tests and text in strings do not count. xdrip-linux.sh
    compares it with the number XCTest executed: a test that is generated but not run (a class
    XCTest does not discover, a `without` that removed more than intended, a file that silently
    lost its tests) then fails the run instead of going unnoticed.
    """
    total = 0
    for path, content in files.items():
        if path.startswith('Tests' + os.sep) and path.endswith('.swift'):
            total += sum(1 for line in extract.code_lines(content.split('\n')) if TEST_METHOD.match(line))
    return total

class Package:
    """The files of one generated package, kept in memory until written."""

    def __init__(self):
        self.files = {}      # relative path -> content
        self.modules = []    # shim modules, dependencies first
        self.pieces = 0

    def lib(self, name, content):
        self.files[os.path.join('Sources', 'xdrip', name)] = content

    def test(self, name, content):
        self.files[os.path.join('Tests', 'xdripTests', name)] = content

    def add_module(self, name):
        directory = os.path.join(SHIM_MODULES_DIR, name)
        if not os.path.isdir(directory):
            raise GenerateError(f'missing shim module: {name}')
        if name in self.modules:
            return
        for dependency in self.dependencies(name):
            self.add_module(dependency)
        for file in sorted(os.listdir(directory)):
            if file.endswith('.swift'):
                with open(os.path.join(directory, file), encoding='utf-8') as f:
                    self.files[os.path.join('Sources', name, file)] = f.read()
        self.modules.append(name)

    @staticmethod
    def dependencies(name):
        file = os.path.join(SHIM_MODULES_DIR, name, 'DEPENDENCIES')
        if not os.path.isfile(file):
            return []
        with open(file, encoding='utf-8') as f:
            return f.read().split()

    def finish(self, snippet):
        # Extracted pieces only import Foundation; let them see the shim modules like the originals.
        imports = ''.join(f'import {module}\n' for module in reversed(self.modules))
        for path, content in self.files.items():
            name = os.path.basename(path)
            if path.startswith(os.path.join('Sources', 'xdrip')) and re.match(r'(decl|members|extract)_', name):
                self.files[path] = imports + content
        targets = ''
        for module in self.modules:
            dependencies = ', '.join(f'"{d}"' for d in self.dependencies(module))
            targets += f'        .target(name: "{module}", dependencies: [{dependencies}], path: "Sources/{module}"),\n'
        module_names = ', '.join(f'"{module}"' for module in self.modules)
        snippet_target = ''
        if snippet:
            self.files[os.path.join('Sources', 'snippet', 'main.swift')] = 'import xdrip\n'
            snippet_target = '        .executableTarget(name: "snippet", dependencies: ["xdrip"], path: "Sources/snippet"),\n'
        self.files['Package.swift'] = (
            '// swift-tools-version:5.9\n'
            '// Generated by linux/xdrip-linux.sh. Do not edit: it is rewritten on every run.\n'
            'import PackageDescription\n\n'
            'let package = Package(\n'
            '    name: "xdrip-linux",\n'
            '    targets: [\n'
            f'{targets}'
            f'        .target(name: "xdrip", dependencies: [{module_names}], path: "Sources/xdrip",\n'
            '                swiftSettings: [.unsafeFlags(["-enable-testing"])]),\n'
            f'{snippet_target}'
            '        .testTarget(name: "xdripTests", dependencies: ["xdrip"], path: "Tests/xdripTests"),\n'
            '    ]\n'
            ')\n'
        )

    def write(self, destination):
        """Makes `destination` hold exactly these files, rewriting only files that changed."""
        os.makedirs(destination, exist_ok=True)
        with open(os.path.join(destination, 'expected-tests'), 'w', encoding='utf-8') as f:
            f.write(f'{count_tests(self.files)}\n')
        for relative, content in self.files.items():
            target = os.path.join(destination, relative)
            if os.path.isfile(target):
                with open(target, encoding='utf-8') as f:
                    if f.read() == content:
                        continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'w', encoding='utf-8') as f:
                f.write(content)
        for top in ('Sources', 'Tests'):
            for base, _, files in os.walk(os.path.join(destination, top), topdown=False):
                for name in files:
                    path = os.path.join(base, name)
                    if os.path.relpath(path, destination) not in self.files:
                        os.remove(path)
                if base != os.path.join(destination, top) and not os.listdir(base):
                    os.rmdir(base)
        # A staging directory left by the previous bash generator is no longer used.
        stale = destination + '.staging'
        if os.path.isdir(stale):
            shutil.rmtree(stale)


def isolated_package(suite, snippet):
    """One suite, laid out like the original bash generator did."""
    package = Package()
    members = {}
    for kind, path, a, b in parse_suite(suite, set(), []):
        package.pieces += 1
        if kind == 'include':
            continue
        if kind == 'module':
            package.add_module(path)
        elif kind == 'src':
            package.lib(flat(path), copy_piece(path, a))
        elif kind == 'test':
            package.test(flat(path), copy_piece(path, a))
        elif kind == 'extract':
            package.lib(f'extract_{package.pieces}_{flat(path)}', 'import Foundation\n' + '\n'.join(extract_range(path, a, b)) + '\n')
        elif kind == 'decl':
            package.lib(f'decl_{package.pieces}_{flat(path)}', decl_piece(path, a))
        elif kind == 'testdecl':
            package.test(f'testdecl_{package.pieces}_{flat(path)}', 'import XCTest\n@testable import xdrip\n' + decl_piece(path, a))
        elif kind == 'members':
            members.setdefault((path, a), set()).update(b)
    for (path, type_name), names in sorted(members.items()):
        package.pieces += 1
        package.lib(f'members_{package.pieces}_{flat(path)}', members_piece(path, type_name, names))
    package.finish(snippet)
    return package


def merged_package(suites, snippet):
    """All suites in one package, with the requests for each file combined (see the module doc)."""
    package = Package()
    src, tests, decl, testdecl, members, extracts = {}, {}, {}, {}, {}, {}
    for suite in suites:
        for kind, path, a, b in parse_suite(suite, set(), []):
            if kind == 'include':
                continue
            if kind == 'module':
                package.add_module(path)
            elif kind == 'src':
                src.setdefault(path, []).append(frozenset(a))
            elif kind == 'test':
                tests.setdefault(path, []).append(frozenset(a))
            elif kind == 'decl':
                decl.setdefault(path, set()).update(a)
            elif kind == 'testdecl':
                testdecl.setdefault(path, set()).update(a)
            elif kind == 'members':
                members.setdefault((path, a), set()).update(b)
            elif kind == 'extract':
                extracts.setdefault(path, []).append((a, b))

    # An extract range becomes decl of the declarations it holds, so it cannot repeat one.
    for path, ranges in extracts.items():
        if path in src:
            continue
        names = set()
        for start, end in ranges:
            names |= declarations_in(extract_range(path, start, end))
        if not names:
            raise GenerateError(f'extract in {path} holds no top-level declaration; cannot be merged')
        decl.setdefault(path, set()).update(names)

    for path in sorted(src):
        requested = decl.get(path, set()).union(*[n for (p, _), n in members.items() if p == path])
        left_out = frozenset.intersection(*src[path]) - requested
        package.lib(flat(path), copy_piece(path, left_out))
    for path in sorted(decl):
        if path not in src:
            package.pieces += 1
            package.lib(f'decl_{package.pieces}_{flat(path)}', decl_piece(path, sorted(decl[path])))
    for (path, type_name), names in sorted(members.items()):
        if path in src or type_name in decl.get(path, set()):
            continue
        package.pieces += 1
        package.lib(f'members_{package.pieces}_{flat(path)}', members_piece(path, type_name, names))
    for path in sorted(tests):
        package.test(flat(path), copy_piece(path, frozenset.intersection(*tests[path])))
    for path in sorted(testdecl):
        if path not in tests:
            package.pieces += 1
            package.test(f'testdecl_{package.pieces}_{flat(path)}', 'import XCTest\n@testable import xdrip\n' + decl_piece(path, sorted(testdecl[path])))
    package.finish(snippet)
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--build', required=True)
    parser.add_argument('--merged', metavar='NAME')
    parser.add_argument('--snippet', action='store_true')
    parser.add_argument('suites', nargs='+')
    args = parser.parse_args()
    try:
        if args.merged:
            merged_package(args.suites, args.snippet).write(os.path.join(args.build, args.merged))
        else:
            for suite in args.suites:
                isolated_package(suite, args.snippet).write(os.path.join(args.build, suite))
    except (GenerateError, SystemExit) as error:
        sys.exit(f'error: {error}')


if __name__ == '__main__':
    main()
