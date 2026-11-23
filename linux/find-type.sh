#!/usr/bin/env bash
# Shows where Swift types are declared and which modules each declaring file imports, to decide
# how to bring a dependency into a Linux suite (src, decl, members or a shim module).
#
# Usage: linux/find-type.sh <TypeName> [TypeName ...]
# Tip:   pipe a failed build through `grep -oE "cannot find (type )?'[A-Za-z0-9_]+'"` to get the names.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for type in "$@"; do
    found=0
    while IFS= read -r -d '' file; do
        found=1
        imports="$(grep -h '^import' "$file" | sed 's/import //' | paste -sd' ' || true)"
        echo "$type -> $file ($(wc -l < "$file") lines; imports: ${imports:-none})"
    done < <(grep -rlZE "^\s*((public|internal|fileprivate|private|final|indirect|@\w+)\s+)*(struct|enum|class|protocol|actor|typealias)\s+$type\b" \
                 --include='*.swift' xDrip "xDrip Widget" "xDrip Watch App" 2>/dev/null || true)
    [[ $found -eq 1 ]] || echo "$type -> not found (nested type, extension member or generated code?)"
done
