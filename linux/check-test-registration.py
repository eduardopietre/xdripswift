#!/usr/bin/env python3
"""Fails when a Swift file in `xDrip Tests/` would silently not run somewhere.

1. On macOS: every file must be compiled by the `xdripTests` target.
2. On Linux: every file must be used by a suite in linux/suites, or be listed with its reason in
   linux/macos-only.txt, so leaving a new test out of the Linux run is a decision, not an accident.

There is no Xcode on Linux, so a test file written there and not registered in
xdrip.xcodeproj silently never runs on macOS (linux/add-test-to-xcodeproj.py registers one).
This parses the project file, resolves the target's Sources build phase to real paths through
the group hierarchy, and compares them with the files on disk. Files registered with a full path
or inside a subfolder group are recognised; a plain grep for the file name gives false positives
and negatives.

Usage: linux/check-test-registration.py
Exit code 0 when both hold and nothing listed is stale, 1 otherwise.
"""

import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
PROJECT = os.path.join(ROOT, 'xdrip.xcodeproj', 'project.pbxproj')
TESTS_DIR = 'xDrip Tests'
TARGET = 'xdripTests'
MACOS_ONLY = os.path.join(ROOT, 'linux', 'macos-only.txt')

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
    return 1 if missing or stale or not check_linux_inventory(on_disk) else 0


def check_linux_inventory(on_disk):
    """Every test file is used by a Linux suite or listed in macos-only.txt, and the list is current."""
    sys.dont_write_bytecode = True
    sys.path.insert(0, os.path.join(ROOT, 'linux'))
    import generate
    suites = sorted(name[:-4] for name in os.listdir(generate.SUITES_DIR) if name.endswith('.txt') and not name.startswith('_'))
    on_linux = set()
    for suite in suites:
        for kind, path, _, _ in generate.parse_suite(suite, set(), []):
            if kind in ('test', 'testdecl'):
                on_linux.add(os.path.normpath(path))
    listed = {}
    with open(MACOS_ONLY, encoding='utf-8') as f:
        for number, raw in enumerate(f, 1):
            path, _, reason = raw.partition('#')
            path = path.strip()
            if not path:
                continue
            if not reason.strip():
                print(f'{os.path.relpath(MACOS_ONLY, ROOT)}:{number}: {path} has no reason')
                listed[os.path.normpath(path)] = None
            else:
                listed[os.path.normpath(path)] = reason.strip()

    ok = True
    for path in sorted(on_disk - on_linux - set(listed)):
        print(f'not run on Linux and not in linux/macos-only.txt: {path}  (port it to a suite, or list it with the reason)')
        ok = False
    for path in sorted(set(listed) & on_linux):
        print(f'linux/macos-only.txt lists {path}, but a Linux suite runs it: remove the line')
        ok = False
    for path in sorted(set(listed) - on_disk):
        print(f'linux/macos-only.txt lists {path}, which does not exist')
        ok = False
    if any(reason is None for reason in listed.values()):
        ok = False
    print(f'{len(on_disk & on_linux)} test files run on Linux, {len(on_disk & set(listed))} listed as macOS only')
    return ok


if __name__ == '__main__':
    sys.exit(main())
