#!/usr/bin/env python3
"""Line coverage of the app code compiled into the Linux suites.

Called by `linux/xdrip-linux.sh coverage` after every suite has run with code coverage enabled.
For each suite it exports LCOV data with llvm-cov, keeps the files of the `xdrip` module (app
code, not tests or shim modules) and merges the hits per line:

- a whole copied file (`src`) has the same content in every suite, so its lines are merged
  across suites and a line counts as covered if any suite runs it;
- extracted pieces (`decl`, `members`, `extract`, `without`) differ per suite and are counted
  per suite.

Only code that is compiled on Linux is measured. Code that needs UIKit, CoreData, BLE etc. is
not part of any suite and therefore not part of the percentage.

Usage: coverage.py <build root> <llvm-cov> <suite> [suite ...] [--files N]
"""

import os
import re
import subprocess
import sys
from collections import defaultdict

EXTRACTED = re.compile(r'^(decl|members|extract|testdecl)_\d+_')


def lcov_for_suite(build_root, llvm_cov, suite):
    package = os.path.join(build_root, suite)
    profdata = os.path.join(package, '.build', 'debug', 'codecov', 'default.profdata')
    binary = os.path.join(package, '.build', 'debug', 'xdrip-linuxPackageTests.xctest')
    if not (os.path.isfile(profdata) and os.path.exists(binary)):
        sys.exit(f'coverage.py: no coverage data for suite {suite} (run it with coverage first)')
    return subprocess.run([llvm_cov, 'export', '-format=lcov', f'-instr-profile={profdata}', binary],
                          check=True, capture_output=True, text=True).stdout


def main():
    args = sys.argv[1:]
    top = 25
    if '--files' in args:
        index = args.index('--files')
        top = int(args[index + 1])
        del args[index:index + 2]
    if len(args) < 3:
        sys.exit(__doc__)
    build_root, llvm_cov, suites = args[0], args[1], args[2:]

    # key -> line -> hit count
    lines = defaultdict(dict)
    for suite in suites:
        current = None
        for row in lcov_for_suite(build_root, llvm_cov, suite).splitlines():
            if row.startswith('SF:'):
                path = row[3:]
                marker = os.sep + os.path.join(suite, 'Sources', 'xdrip') + os.sep
                if marker not in path:
                    current = None
                    continue
                name = os.path.basename(path)
                current = f'{suite}: {name}' if EXTRACTED.match(name) else name
            elif row.startswith('DA:') and current:
                number, hits = row[3:].split(',')[:2]
                lines[current][int(number)] = max(lines[current].get(int(number), 0), int(hits))

    def summary(selected):
        total = sum(len(v) for v in selected.values())
        covered = sum(1 for v in selected.values() for hits in v.values() if hits > 0)
        return total, covered, (100.0 * covered / total if total else 0)

    total, covered, percentage = summary(lines)
    print(f'App code compiled on Linux: {total} executable lines, {covered} covered '
          f'({percentage:.1f}%) in {len(lines)} files/pieces from {len(suites)} suites')
    # Texts_* files are tables of localized strings: one "line" per string, nothing to test there.
    logic = {key: value for key, value in lines.items() if '_Texts_' not in key}
    total, covered, percentage = summary(logic)
    print(f'Without localized string tables (Texts_*): {total} executable lines, {covered} covered ({percentage:.1f}%)')

    rows = sorted(((len(v) - sum(1 for h in v.values() if h > 0), len(v), key) for key, v in lines.items()), reverse=True)
    print(f'\nMost uncovered lines (top {top}):')
    print(f'{"uncovered":>9} {"lines":>6} {"cover":>6}  file')
    for uncovered, count, key in rows[:top]:
        print(f'{uncovered:>9} {count:>6} {100.0 * (count - uncovered) / count:>5.1f}%  {key}')


if __name__ == '__main__':
    main()
