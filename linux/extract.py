#!/usr/bin/env python3
"""Extracts parts of a Swift file for linux/xdrip-linux.sh.

Many app files mix platform-independent Swift with UIKit, SwiftUI or CoreData code. Copying only
the declarations a test needs keeps the Linux package small, and because the text is read from the
real file on every run it never drifts from the app.

Usage:
    extract.py decl    <file> <Name>[,<Name>...]
        Every top-level declaration (struct, enum, class, protocol, actor, extension, typealias,
        func) with one of the given names, from its first line up to the matching closing brace
        at column 0. A preceding `///` comment block and attributes are kept.

    extract.py members <file> <Type> <member>[,<member>...]
        A copy of the declaration line of <Type> containing only the listed members, e.g. a
        handful of strings from a large `Texts_*` class. A member is a `static let`, `static var`,
        `let`, `var` or `func`; its body ends at the matching brace (for closures `}()`).
        For an extension (e.g. `extension Swift.Double: RawRepresentable`) the conformances are
        dropped, as the members they require are not copied.
"""

import re
import sys


def brace_delta(line):
    """Net brace count of a line, ignoring braces inside string literals and line comments."""
    delta, in_string, i = 0, False, 0
    while i < len(line):
        c = line[i]
        if c == '\\' and in_string:
            i += 2
            continue
        if c == '"':
            in_string = not in_string
        elif not in_string:
            if line.startswith('//', i):
                break
            if c == '{':
                delta += 1
            elif c == '}':
                delta -= 1
        i += 1
    return delta


def block_end(lines, start):
    """Index of the last line of the block that opens at `start` (single line if no brace opens)."""
    depth, opened = 0, False
    for i in range(start, len(lines)):
        delta = brace_delta(lines[i])
        if '{' in lines[i]:
            opened = True
        depth += delta
        if opened and depth <= 0:
            return i
        if not opened and i > start and not lines[i].strip().startswith(('.', 'where', '->')):
            return i - 1
    return len(lines) - 1


def leading_comments(lines, start):
    """Moves `start` up over attached `///` comments and attributes."""
    while start > 0 and re.match(r'^\s*(///|@)', lines[start - 1]):
        start -= 1
    return start


KEYWORDS = r'(?:struct|enum|class|protocol|actor|extension|typealias|func)'
MODIFIER = r'(?:public|internal|fileprivate|private|final|indirect|nonisolated|@\w+(?:\([^)]*\))?)'
MODIFIERS = rf'(?:{MODIFIER}\s+)*'
# Member modifiers may appear in any order, e.g. `static private let`.
MEMBER_MODIFIERS = rf'(?:(?:{MODIFIER}|static|class|lazy|override)\s+)*'


def decl(lines, names):
    out, found = [], set()
    for name in names:
        pattern = re.compile(rf'^{MODIFIERS}{KEYWORDS}\s+{re.escape(name)}\b')
        for i, line in enumerate(lines):
            if pattern.match(line):
                out.extend(lines[leading_comments(lines, i):block_end(lines, i) + 1])
                out.append('')
                found.add(name)
    return out, found


def members(lines, type_name, names):
    header = re.compile(rf'^{MODIFIERS}(struct|enum|class|extension)\s+((?:\w+\.)?{re.escape(type_name)})\b')
    start = next((i for i, l in enumerate(lines) if header.match(l)), None)
    if start is None:
        sys.exit(f'extract.py: type {type_name} not found')
    end = block_end(lines, start)
    match = header.match(lines[start])
    # An extension's conformances would require members that are not copied, so they are dropped.
    first = f'extension {match.group(2)} {{' if match.group(1) == 'extension' else lines[start]
    out, found = [first], set()
    for name in names:
        pattern = re.compile(rf'^\s*{MEMBER_MODIFIERS}(?:let|var|func)\s+{re.escape(name)}\b')
        for i in range(start + 1, end):
            if pattern.match(lines[i]):
                out.extend(lines[leading_comments(lines, i):block_end(lines, i) + 1])
                found.add(name)
                break
    out.append('}')
    return out, found


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    mode, path = sys.argv[1], sys.argv[2]
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    if mode == 'decl':
        names = [n.strip() for n in sys.argv[3].split(',') if n.strip()]
        out, found = decl(lines, names)
    elif mode == 'members' and len(sys.argv) == 5:
        names = [n.strip() for n in sys.argv[4].split(',') if n.strip()]
        out, found = members(lines, sys.argv[3].strip(), names)
    else:
        sys.exit(__doc__)
    missing = [n for n in names if n not in found]
    if missing:
        sys.exit(f'extract.py: not found in {path}: {", ".join(missing)}')
    print('import Foundation\n')
    print('\n'.join(out))


if __name__ == '__main__':
    main()
