#!/usr/bin/env python3
"""Fails when a Swift file in `xDrip Tests/` is not compiled by the `xdripTests` target.

There is no Xcode on Linux, so a test file written there and not registered in
xdrip.xcodeproj silently never runs on macOS (linux/add-test-to-xcodeproj.py registers one).
This parses the project file, resolves the target's Sources build phase to real paths through
the group hierarchy, and compares them with the files on disk. Files registered with a full path
or inside a subfolder group are recognised; a plain grep for the file name gives false positives
and negatives.

Usage: linux/check-test-registration.py
Exit code 0 when every file is registered and every registered file exists, 1 otherwise.
"""

import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
PROJECT = os.path.join(ROOT, 'xdrip.xcodeproj', 'project.pbxproj')
TESTS_DIR = 'xDrip Tests'
TARGET = 'xdripTests'

TOKEN = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"((?:[^"\\]|\\.)*)"|([^\s{}()=;,"]+)|([{}()=;,])', re.S)


def parse_plist(text):
    """Parses the old-style (OpenStep) property list that project.pbxproj is written in."""
    tokens = []
    for match in TOKEN.finditer(text):
        quoted, bare, symbol = match.groups()
        if quoted is not None:
            tokens.append(('str', re.sub(r'\\(.)', r'\1', quoted)))
        elif bare is not None:
            tokens.append(('str', bare))
        elif symbol is not None:
            tokens.append(('sym', symbol))
    position = 0

    def value():
        nonlocal position
        kind, text = tokens[position]
        position += 1
        if kind == 'str':
            return text
        if text == '{':
            result = {}
            while tokens[position] != ('sym', '}'):
                key = value()
                position += 1  # =
                result[key] = value()
                position += 1  # ;
            position += 1
            return result
        if text == '(':
            result = []
            while tokens[position] != ('sym', ')'):
                result.append(value())
                if tokens[position] == ('sym', ','):
                    position += 1
            position += 1
            return result
        raise ValueError(f'unexpected {text!r} in {PROJECT}')

    return value()


def main():
    with open(PROJECT, encoding='utf-8') as f:
        objects = parse_plist(f.read())['objects']

    parents = {}
    for identifier, entry in objects.items():
        if entry.get('isa') in ('PBXGroup', 'PBXVariantGroup'):
            for child in entry.get('children', []):
                parents[child] = identifier

    def full_path(identifier):
        """Path relative to the project root, following `<group>`-relative parents."""
        entry = objects[identifier]
        path = entry.get('path', '')
        if entry.get('sourceTree') == '<group>' and identifier in parents:
            return os.path.join(full_path(parents[identifier]), path)
        return path

    target = next((entry for entry in objects.values()
                   if entry.get('isa') == 'PBXNativeTarget' and entry.get('name') == TARGET), None)
    if target is None:
        sys.exit(f'check-test-registration: target {TARGET} not found')
    sources_phase = next(objects[i] for i in target['buildPhases'] if objects[i].get('isa') == 'PBXSourcesBuildPhase')
    registered = set()
    for build_file in sources_phase.get('files', []):
        file_ref = objects.get(build_file, {}).get('fileRef')
        if file_ref in objects:
            registered.add(os.path.normpath(full_path(file_ref)))

    on_disk = set()
    for base, _, files in os.walk(os.path.join(ROOT, TESTS_DIR)):
        for name in files:
            if name.endswith('.swift'):
                on_disk.add(os.path.relpath(os.path.join(base, name), ROOT))

    missing = sorted(on_disk - registered)
    stale = sorted(path for path in registered - on_disk if path.startswith(TESTS_DIR + os.sep))
    for path in missing:
        print(f'not compiled by {TARGET}: {path}  (fix: linux/add-test-to-xcodeproj.py {os.path.relpath(path, TESTS_DIR)})')
    for path in stale:
        print(f'registered in {TARGET} but missing on disk: {path}')
    problems = f', {len(missing)} not registered, {len(stale)} missing on disk' if missing or stale else ''
    print(f'{len(on_disk)} test files, {len(registered & on_disk)} compiled by {TARGET}{problems}')
    return 1 if missing or stale else 0


if __name__ == '__main__':
    sys.exit(main())
