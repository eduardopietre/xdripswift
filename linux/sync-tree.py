#!/usr/bin/env python3
"""Makes <destination> hold exactly the files of <staging>, touching only what changed.

linux/xdrip-linux.sh generates every package from scratch on each run. Writing the result over the
previous package would give every file a new modification time, and the Swift driver would then
recompile the whole module even when nothing changed (74 s instead of ~1 s for all suites). This
copies a file only when its bytes differ and deletes generated files that are no longer produced,
so SwiftPM's incremental build sees real changes only. Build products (`.build*`) are left alone.

Usage: sync-tree.py <staging> <destination>
"""

import filecmp
import os
import shutil
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    staging, destination = sys.argv[1], sys.argv[2]
    wanted = set()
    for base, _, files in os.walk(staging):
        for name in files:
            source = os.path.join(base, name)
            relative = os.path.relpath(source, staging)
            wanted.add(relative)
            target = os.path.join(destination, relative)
            if os.path.isfile(target) and filecmp.cmp(source, target, shallow=False):
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(source, target)
    # Only generated content is pruned: Package.swift and everything under Sources/ and Tests/.
    for top in ('Sources', 'Tests'):
        for base, _, files in os.walk(os.path.join(destination, top), topdown=False):
            for name in files:
                path = os.path.join(base, name)
                if os.path.relpath(path, destination) not in wanted:
                    os.remove(path)
            if base != os.path.join(destination, top) and not os.listdir(base):
                os.rmdir(base)


if __name__ == '__main__':
    main()
