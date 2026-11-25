#!/usr/bin/env bash
# Runs the platform-independent parts of xDrip4iOS on Linux with the open-source Swift toolchain.
#
# The real sources and XCTest files are copied into a throwaway SwiftPM package whose library
# module is called `xdrip`, so the unchanged `@testable import xdrip` in the tests keeps working.
# Which files go in is listed per suite in linux/suites/*.txt (format documented in CLAUDE.md);
# linux/generate.py writes the packages. Nothing in the Xcode project is modified.
#
# Usage:
#   linux/xdrip-linux.sh test     [--isolated] [-j N] [suite ...]
#   linux/xdrip-linux.sh coverage [--isolated] [-j N] [suite ...]   # then line coverage of the app
#                                                                   # code built on Linux
#                                                                   # (COVERAGE_FILES=N rows)
#   linux/xdrip-linux.sh snippet <file.swift> [suite ...]           # run a script against the
#                                                                   # suites' sources
#   linux/xdrip-linux.sh list                                       # list available suites
#
# Without suite names, `test` and `coverage` build every suite into ONE merged package (fastest:
# shared code is compiled once, one test binary, one test process). With suite names, or with
# --isolated, each suite gets its own package and they run in parallel (-j N), which is useful to
# check that a suite builds on its own or to see which suite a failure belongs to.
#
# Environment:
#   SWIFT_BIN          directory with the swift binary (default: /opt/swift/usr/bin, else PATH)
#   XDRIP_LINUX_BUILD  where the generated packages live (default: /tmp/xdrip-linux)
#   SWIFT_TEST_ARGS    extra arguments for `swift test`, e.g. "--filter Libre2"
#   XDRIP_LINUX_JOBS   isolated suites built and run at the same time (default: CPUs; `-j` wins)
#   XDRIP_FUZZ_SCALE   multiplies the random work of the fuzz tests (default 1)
#
# Speed: generate.py only rewrites files whose content changed, so SwiftPM rebuilds only what
# really changed. `coverage` builds into `.build-coverage`, so switching between `test` and
# `coverage` does not invalidate the other's build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES_DIR="$ROOT/linux/suites"
BUILD="${XDRIP_LINUX_BUILD:-/tmp/xdrip-linux}"
mkdir -p "$BUILD" && BUILD="$(cd "$BUILD" && pwd)"
MERGED=_all

if [[ -x "${SWIFT_BIN:-/opt/swift/usr/bin}/swift" ]]; then
    export PATH="${SWIFT_BIN:-/opt/swift/usr/bin}:$PATH"
fi

die() { echo "error: $*" >&2; exit 1; }
all_suites() { for f in "$SUITES_DIR"/[!_]*.txt; do basename "$f" .txt; done; }
generate() { python3 "$ROOT/linux/generate.py" --build "$BUILD" "$@" || die "generating the packages failed"; }

# Builds and tests the package in <dir>; output goes to stdout. Swift Testing's empty-run lines
# are dropped: all tests are XCTest.
run_package() { # <dir>
    local scratch=".build" coverage_flag=""
    if [[ "${XDRIP_COVERAGE:-0}" == 1 ]]; then scratch=".build-coverage"; coverage_flag="--enable-code-coverage"; fi
    cd "$1"
    # shellcheck disable=SC2086
    swift test --scratch-path "$scratch" $coverage_flag ${SWIFT_TEST_ARGS:-} 2>&1 \
        | grep -vE '^(◇|↳|✔) |Test run with 0 tests'
    return "${PIPESTATUS[0]}"
}

command -v swift >/dev/null || die "swift not found; run linux/install-swift.sh first"

cmd="${1:-test}"; shift || true
case "$cmd" in
    list) all_suites ;;
    _run-suite)
        # Internal: tests one already generated isolated suite; output goes to the caller's log.
        run_package "$BUILD/$1"
        ;;
    test|coverage)
        isolated=0
        jobs="${XDRIP_LINUX_JOBS:-$(nproc 2>/dev/null || echo 2)}"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --isolated) isolated=1; shift ;;
                -j) jobs="${2:?usage: -j N}"; shift 2 ;;
                -j*) jobs="${1#-j}"; shift ;;
                *) break ;;
            esac
        done
        [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "-j expects a positive number, got '$jobs'"
        [[ $# -gt 0 ]] && isolated=1 || set -- $(all_suites)
        export XDRIP_COVERAGE=0; [[ "$cmd" == coverage ]] && XDRIP_COVERAGE=1
        started=$SECONDS

        if [[ $isolated == 0 ]]; then
            echo "Running $# suites in one package ($BUILD/$MERGED)"
            generate --merged "$MERGED" "$@"
            status=0
            (run_package "$BUILD/$MERGED") || status=$?
            echo
            echo "Suites run: $# (merged), $([[ $status == 0 ]] && echo passed || echo FAILED), $((SECONDS - started))s"
            coverage_targets=("$MERGED")
        else
            echo "Running $# suite(s), $jobs at a time"
            generate "$@"
            # A worker that dies before recording its status must not inherit a previous success.
            for suite in "$@"; do : > "$BUILD/$suite.status"; done
            printf '%s\n' "$@" | xargs -P "$jobs" -I{} bash -c '
                start=$SECONDS
                if bash "$0" _run-suite "$1" > "$2/$1.log" 2>&1; then status=0; else status=$?; fi
                echo "$status" > "$2/$1.status"
                [[ $status -eq 0 ]] && mark=ok || mark=FAILED
                printf "  %-6s %-40s %3ss\n" "$mark" "$1" "$((SECONDS - start))"
            ' "$0" {} "$BUILD"
            failed=()
            for suite in "$@"; do
                echo; echo "=== $suite"
                cat "$BUILD/$suite.log"
                [[ "$(cat "$BUILD/$suite.status" 2>/dev/null)" == 0 ]] || failed+=("$suite")
            done
            echo
            echo "Suites run: $#, failed: ${#failed[@]}${failed[*]:+ (${failed[*]})}, $((SECONDS - started))s"
            status=${#failed[@]}
            coverage_targets=("$@")
        fi
        if [[ "$cmd" == coverage ]]; then
            echo
            python3 "$ROOT/linux/coverage.py" "$BUILD" "$(dirname "$(command -v swift)")/llvm-cov" "${coverage_targets[@]}" --files "${COVERAGE_FILES:-25}"
        fi
        [[ $status == 0 ]]
        ;;
    snippet)
        [[ $# -ge 1 ]] || die "usage: $0 snippet <file.swift> [suite ...]"
        snippet="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
        [[ -f "$snippet" ]] || die "no such snippet: $snippet"
        [[ $# -gt 0 ]] || set -- $(all_suites)
        # Merged, so any combination of suites works; the snippet replaces the placeholder main.swift.
        generate --merged _snippet --snippet "$@"
        cp "$snippet" "$BUILD/_snippet/Sources/snippet/main.swift"
        cd "$BUILD/_snippet"
        swift run -q snippet
        ;;
    *) die "unknown command '$cmd' (test | coverage | snippet | list)" ;;
esac
