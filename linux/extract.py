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
        `let`, `var`, `func` (all overloads) or a nested type; its body ends at the matching brace (for closures `}()`).
        The special member name `cases` copies all enum cases, e.g. to use an enum whose methods
        need CoreData. For an extension (e.g. `extension Swift.Double: RawRepresentable`) the conformances are
        dropped, as the members they require are not copied.

    extract.py copy <file>
        The whole file, with the same Linux adjustments as the other modes (see linux_compatible).

    extract.py without <file> <member>[,<member>...]
        The whole file except the listed members (at any depth), e.g. the test methods that need
        UIKit or CoreData, so the rest of a test file can still run. The file's imports are kept.
"""

import re
import sys


STRING_START = re.compile(r'(#*)("""|")')
_code_cache = {}


def code_lines(lines):
    """code_lines for a list of lines, computed once per list (generate.py reuses the lists)."""
    cached = _code_cache.get(id(lines))
    if cached is None or cached[0] is not lines:
        cached = (lines, _code_lines(lines))
        _code_cache[id(lines)] = cached
    return cached[1]


def _code_lines(lines):
    """The code of every line: string contents and comments removed, string delimiters kept as `""`.

    The state is carried across lines, so braces and keywords inside multi-line strings (triple quotes),
    raw strings (`#"…"#`), block comments (`/* */`, nested) and in interpolations (`\\(…)`, which
    are code again) are handled. Bracket counting and declaration matching use this instead of the
    raw text: a JSON fixture in a multi-line string, or a `}` in a comment, used to shift the
    depth and cut a declaration short or swallow the next one.
    """
    out = []
    # A stack of contexts: ('code', open parentheses) — the bottom one, or an interpolation —
    # and ('string', number of #, multi-line), and ('block', nesting depth).
    stack = [['code', 0]]
    for line in lines:
        code, i, n = [], 0, len(line)
        while i < n:
            top = stack[-1]
            c = line[i]
            if top[0] == 'block':
                if line.startswith('/*', i):
                    top[1] += 1
                    i += 2
                elif line.startswith('*/', i):
                    top[1] -= 1
                    if top[1] == 0:
                        stack.pop()
                    i += 2
                else:
                    i += 1
                continue
            if top[0] == 'string':
                hashes, multiline = top[1], top[2]
                if c == '\\' and line.startswith('#' * hashes, i + 1):
                    after = i + 1 + hashes
                    if after < n and line[after] == '(':
                        # Interpolation: code until the matching parenthesis.
                        stack.append(['code', 1])
                        code.append('(')
                        i = after + 1
                    else:
                        i = after + 1
                    continue
                closing = ('"""' if multiline else '"') + '#' * hashes
                if line.startswith(closing, i):
                    stack.pop()
                    code.append('"')
                    i += len(closing)
                    continue
                i += 1
                continue
            # code (the file itself or an interpolation)
            if line.startswith('//', i):
                break
            if line.startswith('/*', i):
                stack.append(['block', 1])
                i += 2
                continue
            match = STRING_START.match(line, i) if c in '#"' else None
            if match:
                hashes, delimiter = len(match.group(1)), match.group(2)
                stack.append(['string', hashes, delimiter == '"""'])
                code.append('"')
                i += len(match.group(0))
                continue
            if len(stack) > 1 and top[0] == 'code':
                if c == '(':
                    top[1] += 1
                elif c == ')':
                    top[1] -= 1
                    if top[1] == 0:
                        stack.pop()
                        code.append(')')
                        i += 1
                        continue
            code.append(c)
            i += 1
        # A single-line string cannot continue on the next line; recover instead of drifting.
        while stack[-1][0] == 'string' and not stack[-1][2] or (stack[-1][0] == 'code' and len(stack) > 1 and stack[-2][0] == 'string' and not stack[-2][2]):
            stack.pop()
        out.append(''.join(code))
    return out


def brace_delta(code):
    """Net brace count of a line of code (see code_lines)."""
    return code.count('{') - code.count('}')


def block_end(code, start):
    """Index of the last line of the declaration that starts at `start`.

    `code` is the output of code_lines. A declaration with a body ends at the brace that closes
    it; signatures may span several lines. One without a body (`let x = 1`, `case a`) ends at the
    first line where its brackets are balanced and the next line does not continue the expression.
    """
    depth, parens, opened = 0, 0, False
    for i in range(start, len(code)):
        line = code[i]
        parens += line.count('(') + line.count('[') - line.count(')') - line.count(']')
        if '{' in line:
            opened = True
        depth += brace_delta(line)
        if opened:
            if depth <= 0:
                return i
            continue
        following = code[i + 1].strip() if i + 1 < len(code) else ''
        continues = line.rstrip().endswith((',', '(', '[', '=', '->', ':')) or \
            following.startswith(('.', '->', 'where', '{', '?', ':', '&&', '||', '+', '-', '*'))
        if parens <= 0 and not continues:
            return i
    return len(code) - 1


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
    code = code_lines(lines)
    out, found = [], set()
    for name in names:
        pattern = re.compile(rf'^{MODIFIERS}{KEYWORDS}\s+{re.escape(name)}\b')
        for i, line in enumerate(code):
            if pattern.match(line):
                out.extend(lines[leading_comments(lines, i):block_end(code, i) + 1])
                out.append('')
                found.add(name)
    return out, found


def members(lines, type_name, names):
    code = code_lines(lines)
    header = re.compile(rf'^{MODIFIERS}(struct|enum|class|extension)\s+((?:\w+\.)?{re.escape(type_name)})\b')
    start = next((i for i, l in enumerate(code) if header.match(l)), None)
    if start is None:
        sys.exit(f'extract.py: type {type_name} not found')
    end = block_end(code, start)
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
            if depth == 1 and re.match(r'^\s*case\s', code[i]):
                out.append(lines[i])
                found.add('cases')
            depth += brace_delta(code[i])
    for name in (n for n in names if n != 'cases'):
        pattern = re.compile(rf'^\s*{MEMBER_MODIFIERS}(?:let|var|func|enum|struct|class|typealias)\s+{re.escape(name)}\b')
        # Every overload with this name is copied: a call may need any of them.
        i = start + 1
        while i < end:
            if pattern.match(code[i]):
                last = block_end(code, i)
                out.extend(lines[leading_comments(lines, i):last + 1])
                found.add(name)
                i = last
            i += 1
    out.append('}')
    return out, found


def without(lines, names):
    code = code_lines(lines)
    out, found, skip_until = [], set(), -1
    patterns = {name: re.compile(rf'^\s*{MEMBER_MODIFIERS}(?:let|var|func|enum|struct|class)\s+{re.escape(name)}\b')
                for name in names}
    for i, line in enumerate(lines):
        if i <= skip_until:
            continue
        name = next((n for n, p in patterns.items() if p.match(code[i])), None)
        if name:
            start = leading_comments(lines, i)
            del out[len(out) - (i - start):]
            skip_until = block_end(code, i)
            found.add(name)
            continue
        out.append(line)
    return out, found


def linux_compatible(line):
    """Drops `@objc` and `dynamic`: there is no Objective-C runtime on Linux. Used for KVO-observable
    `UserDefaults` properties, which behave as plain computed properties without it."""
    return re.sub(r'@objc(?:\([^)]*\))?\s+|\bdynamic\s+(?=(?:var|func)\b)', '', line)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    mode, path = sys.argv[1], sys.argv[2]
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    # On Linux URLRequest, URLSession etc. live in FoundationNetworking; Apple platforms have no such module.
    print('#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif')
    if mode == 'copy':
        print('\n'.join(linux_compatible(line) for line in lines), end='')
        return
    if len(sys.argv) < 4:
        sys.exit(__doc__)
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
