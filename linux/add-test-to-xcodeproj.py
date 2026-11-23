#!/usr/bin/env python3
"""Registers a new file from `xDrip Tests/` in xdrip.xcodeproj so the test target compiles it.

Without Xcode (Linux sessions) a new test file would otherwise never run on macOS. This adds the
same four entries Xcode writes when a file is added to the xdripTests target: a PBXBuildFile, a
PBXFileReference, a child of the `xDrip Tests` group and an entry in the target's Sources phase.
Identifiers are derived from the file name, so running it twice is harmless.

Usage: linux/add-test-to-xcodeproj.py <FileName.swift | Subfolder/FileName.swift> [...]

A file in a subfolder of `xDrip Tests` (e.g. `Libre3/Libre3FooTests.swift`) is added next to an
already registered file of the same subfolder, so it lands in that subfolder's group.
"""

import hashlib
import os
import re
import sys

PROJECT = os.path.join(os.path.dirname(__file__), '..', 'xdrip.xcodeproj', 'project.pbxproj')
TESTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'xDrip Tests')
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


def anchors_for(relative_path):
    """Registered files to place a new file next to: same subfolder first, then the defaults."""
    folder = os.path.dirname(relative_path)
    if not folder:
        return ANCHORS
    directory = os.path.join(TESTS_DIR, folder)
    return sorted(name for name in os.listdir(directory) if name.endswith('.swift'))


def add(text, relative_path):
    name = os.path.basename(relative_path)
    if f'path = {name};' in text:
        print(f'{name}: already in the project')
        return text
    file_ref, build_file = identifier(relative_path, 'fileRef'), identifier(relative_path, 'buildFile')
    present = [anchor for anchor in anchors_for(relative_path) if anchor != name and f'path = {anchor};' in text]
    if not present:
        sys.exit(f'add-test-to-xcodeproj: no registered file to place {relative_path} next to')
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
        if not os.path.isfile(os.path.join(TESTS_DIR, name)):
            sys.exit(f'add-test-to-xcodeproj: xDrip Tests/{name} does not exist')
        text = add(text, name)
    with open(PROJECT, 'w', encoding='utf-8') as f:
        f.write(text)


if __name__ == '__main__':
    main()
