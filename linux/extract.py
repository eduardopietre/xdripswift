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
        `let`, `var`, `func` or a nested type; its body ends at the matching brace (for closures `}()`).
        The special member name `cases` copies all enum cases, e.g. to use an enum whose methods
        need CoreData. For an extension (e.g. `extension Swift.Double: RawRepresentable`) the conformances are
        dropped, as the members they require are not copied.

    extract.py without <file> <member>[,<member>...]
        The whole file except the listed members (at any depth), e.g. the test methods that need
        UIKit or CoreData, so the rest of a test file can still run. The file's imports are kept.
"""

import re
import sys


def strip_strings_and_comments(line):
    """The code of a line without string literal contents and line comments, for bracket counting."""
    out, in_string, i = [], False, 0
    while i < len(line):
        c = line[i]
        if in_string:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_string = False
                out.append(c)
        elif line.startswith('//', i):
            break
        else:
            if c == '"':
                in_string = True
            out.append(c)
        i += 1
    return ''.join(out)


def brace_delta(line):
    """Net brace count of a line, ignoring braces inside string literals and line comments."""
    code = strip_strings_and_comments(line)
    return code.count('{') - code.count('}')


def block_end(lines, start):
    """Index of the last line of the declaration that starts at `start`.

    A declaration with a body ends at the brace that closes it; signatures may span several lines.
    One without a body (`let x = 1`, `case a`) ends at the first line where its brackets are
    balanced and the next line does not continue the expression.
    """
    depth, parens, opened = 0, 0, False
    for i in range(start, len(lines)):
        code = strip_strings_and_comments(lines[i])
        parens += code.count('(') + code.count('[') - code.count(')') - code.count(']')
        if '{' in code:
            opened = True
        depth += code.count('{') - code.count('}')
        if opened:
            if depth <= 0:
                return i
            continue
        following = lines[i + 1].strip() if i + 1 < len(lines) else ''
        continues = code.rstrip().endswith((',', '(', '[', '=', '->', ':')) or \
            following.startswith(('.', '->', 'where', '{', '?', ':', '&&', '||', '+', '-', '*'))
        if parens <= 0 and not continues:
            return i
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
MEMBER_MODIFIERS = rf'(?:(?:{MODIFIER}|static|class|lazy|override|dynamic|mutating|weak|unowned)\s+)*'


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
    # Conformances of an extension, and the superclass and protocols of a class, would require
    # members that are not copied, so they are dropped. Enums and structs keep theirs (raw types).
    if match.group(1) == 'extension':
        first = f'extension {match.group(2)} {{'
    elif match.group(1) == 'class':
        first = re.sub(r'\s*:[^{]*', ' ', lines[start], count=1)
    else:
        first = lines[start]
    out, found = [first], set()
    if 'cases' in names:
        # The enum cases only (direct children of the type), without the members that use them.
        depth = 0
        for i in range(start, end):
            if depth == 1 and re.match(r'^\s*case\s', lines[i]):
                out.append(lines[i])
                found.add('cases')
            depth += brace_delta(lines[i])
    for name in (n for n in names if n != 'cases'):
        pattern = re.compile(rf'^\s*{MEMBER_MODIFIERS}(?:let|var|func|enum|struct|class|typealias)\s+{re.escape(name)}\b')
        for i in range(start + 1, end):
            if pattern.match(lines[i]):
                out.extend(lines[leading_comments(lines, i):block_end(lines, i) + 1])
                found.add(name)
                break
    out.append('}')
    return out, found


def without(lines, names):
    out, found, skip_until = [], set(), -1
    patterns = {name: re.compile(rf'^\s*{MEMBER_MODIFIERS}(?:let|var|func|enum|struct|class)\s+{re.escape(name)}\b')
                for name in names}
    for i, line in enumerate(lines):
        if i <= skip_until:
            continue
        name = next((n for n, p in patterns.items() if p.match(line)), None)
        if name:
            start = leading_comments(lines, i)
            del out[len(out) - (i - start):]
            skip_until = block_end(lines, i)
            found.add(name)
            continue
        out.append(line)
    return out, found


def linux_compatible(line):
    """Drops `@objc` and `dynamic`: there is no Objective-C runtime on Linux. Used for KVO-observable
    `UserDefaults` properties, which behave as plain computed properties without it."""
    return re.sub(r'@objc(?:\([^)]*\))?\s+|\bdynamic\s+(?=(?:var|func)\b)', '', line)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    mode, path = sys.argv[1], sys.argv[2]
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    if mode == 'decl':
        names = [n.strip() for n in sys.argv[3].split(',') if n.strip()]
        out, found = decl(lines, names)
    elif mode == 'without':
        names = [n.strip() for n in sys.argv[3].split(',') if n.strip()]
        out, found = without(lines, names)
    elif mode == 'members' and len(sys.argv) == 5:
        names = [n.strip() for n in sys.argv[4].split(',') if n.strip()]
        out, found = members(lines, sys.argv[3].strip(), names)
    else:
        sys.exit(__doc__)
    missing = [n for n in names if n not in found]
    if missing:
        sys.exit(f'extract.py: not found in {path}: {", ".join(missing)}')
    if mode != 'without':
        print('import Foundation\n')
    print('\n'.join(linux_compatible(line) for line in out))


if __name__ == '__main__':
    main()
