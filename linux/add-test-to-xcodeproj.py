#!/usr/bin/env python3
"""Registers a new file from `xDrip Tests/` in xdrip.xcodeproj so the test target compiles it.

Without Xcode (Linux sessions) a new test file would otherwise never run on macOS. This adds the
same four entries Xcode writes when a file is added to the xdripTests target: a PBXBuildFile, a
PBXFileReference, a child of the `xDrip Tests` group and an entry in the target's Sources phase.
Identifiers are derived from the file name, so running it twice is harmless.

Usage: linux/add-test-to-xcodeproj.py <FileName.swift> [FileName.swift ...]
"""

import hashlib
import os
import re
import sys

PROJECT = os.path.join(os.path.dirname(__file__), '..', 'xdrip.xcodeproj', 'project.pbxproj')
# Files known to be in the test target; the first one present shows where new entries belong.
ANCHORS = ['LibreLinkUpDownloadChainTests.swift', 'GlucoseRangeDistributionTests.swift', 'BgReadingTrendTests.swift']


def identifier(name, kind):
    """A stable 24-hex-digit identifier, unique per file name and entry kind."""
    return hashlib.sha1(f'xdripTests/{kind}/{name}'.encode()).hexdigest()[:24].upper()


def insert_after(text, pattern, line):
    match = re.search(pattern, text, flags=re.M)
    if not match:
        sys.exit(f'add-test-to-xcodeproj: anchor not found: {pattern}')
    end = text.index('\n', match.end()) + 1
    return text[:end] + line + '\n' + text[end:]


def add(text, name):
    if f'path = {name};' in text:
        print(f'{name}: already in the project')
        return text
    file_ref, build_file = identifier(name, 'fileRef'), identifier(name, 'buildFile')
    present = [name for name in ANCHORS if f'path = {name};' in text]
    if not present:
        sys.exit('add-test-to-xcodeproj: none of the anchor test files is in the project')
    anchor = re.escape(present[0])
    text = insert_after(text, rf'^\s*\w+ /\* {anchor} in Sources \*/ = {{isa = PBXBuildFile;',
        f'\t\t{build_file} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref} /* {name} */; }};')
    text = insert_after(text, rf'^\s*\w+ /\* {anchor} \*/ = {{isa = PBXFileReference;',
        f'\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
    text = insert_after(text, rf'^\s*\w+ /\* {anchor} \*/,$',
        f'\t\t\t\t{file_ref} /* {name} */,')
    text = insert_after(text, rf'^\s*\w+ /\* {anchor} in Sources \*/,$',
        f'\t\t\t\t{build_file} /* {name} in Sources */,')
    print(f'{name}: added')
    return text


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(PROJECT, encoding='utf-8') as f:
        text = f.read()
    for name in sys.argv[1:]:
        if not os.path.isfile(os.path.join(os.path.dirname(PROJECT), '..', 'xDrip Tests', name)):
            sys.exit(f'add-test-to-xcodeproj: xDrip Tests/{name} does not exist')
        text = add(text, name)
    with open(PROJECT, 'w', encoding='utf-8') as f:
        f.write(text)


if __name__ == '__main__':
    main()
