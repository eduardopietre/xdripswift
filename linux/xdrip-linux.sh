#!/usr/bin/env bash
# Runs the platform-independent parts of xDrip4iOS on Linux with the open-source Swift toolchain.
#
# The real sources and XCTest files are copied into a throwaway SwiftPM package whose library
# module is called `xdrip`, so the unchanged `@testable import xdrip` in the tests keeps working.
# Which files go in is listed per suite in linux/suites/*.txt (format documented in CLAUDE.md).
# Nothing in the Xcode project is modified.
#
# Usage:
#   linux/xdrip-linux.sh test    [suite ...]                 # swift test per suite (default: all)
#   linux/xdrip-linux.sh snippet <file.swift> [suite ...]    # run a script against the suites' sources
#                                                            # (suites are merged into one module, so
#                                                            # pick ones that do not overlap)
#   linux/xdrip-linux.sh list                                # list available suites
#
# Environment:
#   SWIFT_BIN          directory with the swift binary (default: /opt/swift/usr/bin, else PATH)
#   XDRIP_LINUX_BUILD  where the generated packages live (default: /tmp/xdrip-linux)
#   SWIFT_TEST_ARGS    extra arguments for `swift test`, e.g. "--filter Libre2"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES_DIR="$ROOT/linux/suites"
SHIM_MODULES_DIR="$ROOT/linux/shim-modules"
BUILD="${XDRIP_LINUX_BUILD:-/tmp/xdrip-linux}"

if [[ -x "${SWIFT_BIN:-/opt/swift/usr/bin}/swift" ]]; then
    export PATH="${SWIFT_BIN:-/opt/swift/usr/bin}:$PATH"
fi

die() { echo "error: $*" >&2; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
flat() { printf '%s' "$1" | tr '/ ' '__'; }

all_suites() { for f in "$SUITES_DIR"/[!_]*.txt; do basename "$f" .txt; done; }

# Copies one source into the package, flattening its path into a unique file name.
place() { # <repo-relative path> <destination dir>
    [[ -f "$ROOT/$1" ]] || die "missing file: $1"
    cp "$ROOT/$1" "$2/$(flat "$1")"
}

# Copies the lines from the first match of <start-regex> up to, not including, the first later
# match of <end-regex>. Used for files that mix pure Swift with Apple-only code.
extract() { # <repo-relative path> <start-regex> <end-regex> <destination file>
    [[ -f "$ROOT/$1" ]] || die "missing file: $1"
    {
        echo "import Foundation"
        awk -v s="$2" -v e="$3" '
            !on && $0 ~ s { on = 1 }
            on && started && $0 ~ e { exit }
            on { print; started = 1 }
        ' "$ROOT/$1"
    } > "$4"
    [[ $(wc -l < "$4") -gt 1 ]] || die "extract matched nothing in $1 (start: $2)"
}

# Adds the contents listed in linux/suites/<suite>.txt to the package. `include` nests suites;
# names starting with `_` are shared fragments that are never run on their own.
add_suite() { # <suite> <library dir> <tests dir>
    local suite="$1" lib="$2" tests="$3"
    local file="$SUITES_DIR/$suite.txt" line kind rest path start end names type out
    [[ -f "$file" ]] || die "unknown suite '$suite' (see: $0 list)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "${line%%#*}")"
        [[ -z "$line" ]] && continue
        kind="${line%%[[:space:]]*}"; rest="$(trim "${line#"$kind"}")"
        PIECES=$((PIECES + 1))
        case "$kind" in
            include)
                # Each fragment is added once, however many suites or fragments include it.
                if [[ " $INCLUDED " != *" $rest "* ]]; then
                    INCLUDED="$INCLUDED $rest"
                    add_suite "$rest" "$lib" "$tests"
                fi ;;
            module) add_module "$rest" "$lib/.." ;;
            src)  place "$rest" "$lib" ;;
            test)
                # `test <path> | without a, b` leaves out members that cannot run on Linux.
                IFS='|' read -r path names <<< "$rest"; path="$(trim "$path")"; names="$(trim "${names:-}")"
                if [[ -z "$names" ]]; then
                    place "$path" "$tests"
                else
                    [[ "$names" == without* ]] || die "$suite.txt: expected 'without' after '|' in: $line"
                    [[ -f "$ROOT/$path" ]] || die "missing file: $path"
                    python3 "$ROOT/linux/extract.py" without "$ROOT/$path" "${names#without}" \
                        > "$tests/$(flat "$path")" || die "$suite.txt: test without failed"
                fi ;;
            extract)
                IFS='|' read -r path start end <<< "$rest"; path="$(trim "$path")"
                extract "$path" "$(trim "$start")" "$(trim "$end")" "$lib/extract_${PIECES}_$(flat "$path")" ;;
            decl|testdecl)
                IFS='|' read -r path names <<< "$rest"; path="$(trim "$path")"
                [[ -f "$ROOT/$path" ]] || die "missing file: $path"
                if [[ "$kind" == decl ]]; then out="$lib"; else out="$tests"; fi
                out="$out/${kind}_${PIECES}_$(flat "$path")"
                python3 "$ROOT/linux/extract.py" decl "$ROOT/$path" "$names" > "$out" || die "$suite.txt: $kind failed"
                if [[ "$kind" == testdecl ]]; then
                    { echo "import XCTest"; echo "@testable import xdrip"; cat "$out"; } > "$out.tmp" && mv "$out.tmp" "$out"
                fi ;;
            members)
                # Collected and written once per type in generate(), so several suites and
                # fragments can each ask for the members they need from the same type.
                IFS='|' read -r path type names <<< "$rest"; path="$(trim "$path")"; type="$(trim "$type")"
                [[ -f "$ROOT/$path" ]] || die "missing file: $path"
                MEMBERS["$path|$type"]="${MEMBERS["$path|$type"]:-}${MEMBERS["$path|$type"]:+,}$names" ;;
            *) die "$suite.txt: unknown directive '$kind'" ;;
        esac
    done < "$file"
}

declare -A MEMBERS

# Adds a stand-in for an Apple module (linux/shim-modules/<Name>), so files keep their
# `import <Name>` unchanged. A DEPENDENCIES file lists other shim modules it builds on.
add_module() { # <name> <sources dir>
    local name="$1" sources="$2" dependency
    [[ -d "$SHIM_MODULES_DIR/$name" ]] || die "missing shim module: $name"
    [[ " $MODULES " == *" $name "* ]] && return 0
    if [[ -f "$SHIM_MODULES_DIR/$name/DEPENDENCIES" ]]; then
        for dependency in $(cat "$SHIM_MODULES_DIR/$name/DEPENDENCIES"); do add_module "$dependency" "$sources"; done
    fi
    mkdir -p "$sources/$name"
    cp "$SHIM_MODULES_DIR/$name"/*.swift "$sources/$name/"
    MODULES="$MODULES $name"
}

# Writes the package for the given suites into <dir>.
generate() { # <dir> <suite ...>
    local dir="$1"; shift
    rm -rf "$dir/Sources" "$dir/Tests" "$dir/Package.swift"
    mkdir -p "$dir/Sources/xdrip" "$dir/Tests/xdripTests" "$dir/Sources/snippet"
    local lib="$dir/Sources/xdrip" tests="$dir/Tests/xdripTests"
    PIECES=0 MODULES="" INCLUDED=""
    MEMBERS=()
    local suite key
    for suite in "$@"; do add_suite "$suite" "$lib" "$tests"; done
    for key in "${!MEMBERS[@]}"; do
        PIECES=$((PIECES + 1))
        python3 "$ROOT/linux/extract.py" members "$ROOT/${key%%|*}" "${key#*|}" \
            "$(printf '%s' "${MEMBERS[$key]}" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u | paste -sd,)" \
            > "$lib/members_${PIECES}_$(flat "${key%%|*}")" || die "members of ${key#*|} failed"
    done
    # Extracted pieces only import Foundation; let them see the shim modules like the originals did.
    local module piece
    for piece in "$lib"/decl_* "$lib"/members_* "$lib"/extract_*; do
        [[ -f "$piece" ]] || continue
        for module in $MODULES; do sed -i "1i import $module" "$piece"; done
    done
    # A placeholder so the snippet target always exists; replaced by `snippet`.
    echo 'import xdrip' > "$dir/Sources/snippet/main.swift"

    local module_targets="" module_names="" dependencies
    for module in $MODULES; do
        dependencies=""
        if [[ -f "$SHIM_MODULES_DIR/$module/DEPENDENCIES" ]]; then
            dependencies="$(sed 's/.*/"&"/' "$SHIM_MODULES_DIR/$module/DEPENDENCIES" | paste -sd, | sed 's/,/, /g')"
        fi
        module_targets+="        .target(name: \"$module\", dependencies: [$dependencies], path: \"Sources/$module\"),"$'\n'
        module_names+=", \"$module\""
    done
    cat > "$dir/Package.swift" <<EOF
// swift-tools-version:5.9
// Generated by linux/xdrip-linux.sh. Do not edit: it is rewritten on every run.
import PackageDescription

let package = Package(
    name: "xdrip-linux",
    targets: [
${module_targets}        .target(name: "xdrip", dependencies: [${module_names#, }], path: "Sources/xdrip",
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "snippet", dependencies: ["xdrip"], path: "Sources/snippet"),
        .testTarget(name: "xdripTests", dependencies: ["xdrip"], path: "Tests/xdripTests"),
    ]
)
EOF
}

command -v swift >/dev/null || die "swift not found; run linux/install-swift.sh first"

cmd="${1:-test}"; shift || true
case "$cmd" in
    list) all_suites ;;
    test)
        # Each suite is built in its own package: suites may extract the same declarations, which
        # would clash if compiled into one module. Build products are cached per suite.
        [[ $# -gt 0 ]] || set -- $(all_suites)
        failed=()
        for suite in "$@"; do
            echo "=== $suite"
            generate "$BUILD/$suite" "$suite"
            # shellcheck disable=SC2086
            if ! (cd "$BUILD/$suite" && swift test ${SWIFT_TEST_ARGS:-} 2>&1 \
                    | grep -vE '^(◇|↳|✔) |Test run with 0 tests'; exit "${PIPESTATUS[0]}"); then
                failed+=("$suite")
            fi
        done
        echo
        echo "Suites run: $#, failed: ${#failed[@]}${failed[*]:+ (${failed[*]})}"
        [[ ${#failed[@]} -eq 0 ]]
        ;;
    snippet)
        [[ $# -ge 1 ]] || die "usage: $0 snippet <file.swift> [suite ...]"
        snippet="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
        [[ -f "$snippet" ]] || die "no such snippet: $snippet"
        [[ $# -gt 0 ]] || set -- $(all_suites)
        generate "$BUILD/_snippet" "$@"
        cp "$snippet" "$BUILD/_snippet/Sources/snippet/main.swift"
        cd "$BUILD/_snippet"
        swift run -q snippet
        ;;
    *) die "unknown command '$cmd' (test | snippet | list)" ;;
esac
