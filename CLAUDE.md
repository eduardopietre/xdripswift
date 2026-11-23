# CLAUDE.md

xDrip4iOS (`xdrip.xcodeproj` / `xdrip.xcworkspace`): iOS + watchOS CGM app in Swift. Fork of
`JohanDegraeve/xdripswift`; upstream issues are tracked there, not in this fork.

## Language and code style

- Everything written to the repository is in **English**: code, comments, tests, scripts,
  commit messages and this file (even when the conversation is in another language).
- Mimic the existing style of the surrounding code and tests:
  - New Swift files start with the standard header:
    ```swift
    //
    //  FileName.swift
    //  xdrip            (xdripTests for files in `xDrip Tests/`)
    //
    //  Created by eduardopietre on dd/mm/yy.
    //  Copyright © 2026 Johan Degraeve. All rights reserved.
    //
    ```
  - `///` doc comments on types, properties and functions, explaining *why* as well as what.
  - `// MARK: -` sections as used in the file being edited (e.g. `// MARK: - private functions`).
  - Regression tests get a type-level `///` comment describing the bug they guard against
    (see `xDrip Tests/LibreLinkUpDownloadChainTests.swift`).
- Shell scripts start with a comment block describing purpose and usage.

## Running code and tests on Linux (cloud sessions)

There is no Xcode, simulator, UIKit, CoreBluetooth, CoreData, HealthKit, etc. on Linux, so the
full `xDrip Tests` suite **cannot** run here (it needs macOS: Xcode locally or a macOS CI runner).
What **does** work: the platform-independent parts (Foundation-only logic: parsers, frame
assembly, calculations, enums/state rules), compiled and tested with the open-source Swift
toolchain. Proven on Swift 6.2.1 / Ubuntu 24.04 x86_64.

### Setup (once per container; the container is ephemeral)

```bash
linux/install-swift.sh        # official toolchain into /opt/swift (~3 GB, ~1-2 min)
```

### Commands

```bash
linux/xdrip-linux.sh list                          # available suites
linux/xdrip-linux.sh test                          # all suites
linux/xdrip-linux.sh test libre2-frame-assembler   # selected suites
SWIFT_TEST_ARGS="--filter testAnubis" linux/xdrip-linux.sh test
linux/xdrip-linux.sh snippet linux/snippets/libre2-assembler-demo.swift [suite ...]
```

`snippet` runs any Swift script against the real app sources (use `@testable import xdrip`),
handy to probe behaviour or reproduce an issue quickly.

### How it works

`linux/xdrip-linux.sh` generates a throwaway SwiftPM package in `$XDRIP_LINUX_BUILD`
(default `/tmp/xdrip-linux`) with a library module named **`xdrip`**, so the original test files
with `@testable import xdrip` compile unchanged. Real files are **copied**, never edited; the
Xcode project is untouched. Exit code is non-zero when a test fails.

Each `linux/suites/<name>.txt` lists what goes in (`#` comments allowed, paths relative to the
repo root, spaces in paths are fine):

```
src     <path>                              # whole source file into module xdrip
test    <path>                              # XCTest file into the test target
extract <path> | <start-regex> | <end-regex> # lines from start match up to (excluding) end match;
                                            #   for files mixing pure Swift with CoreData/UIKit
shim    <file>                              # linux/shims/<file>: hand-written stand-ins (none yet)
```

### Adding a suite

1. Pick a test in `xDrip Tests/` whose imports are only `XCTest`/`Foundation` (+ `@testable import xdrip`).
2. Follow the types it uses to their sources (`grep -rn "struct Foo\|enum Foo\|class Foo" xDrip`),
   adding `src` lines until it compiles. Prefer `extract` over pulling in Apple-only files.
3. If a dependency is Apple-only but trivial, add a minimal shim in `linux/shims/` — keep shims
   small and note why; never change app code just to make it build on Linux unless asked.
4. Run `linux/xdrip-linux.sh test <suite>`; sanity-check by temporarily breaking the logic under
   test and seeing it fail, then `git checkout --` the file.

### Current suites

| Suite | Covers |
|---|---|
| `libre2-frame-assembler` | `Libre2FrameAssemblerTests` (3 tests) |
| `dexcom-g6-bluetooth-slot` | `DexcomG6BluetoothSlotTests` (8 tests), uses `extract` on the CoreData file |

### Linux caveats

- No Objective-C runtime: `@objc`, `NSObject` KVO, `#selector` won't behave as on iOS.
- Foundation is swift-corelibs-foundation: mostly compatible; `DateFormatter`/locale and
  `UserDefaults` edge cases can differ — don't treat a Linux pass as proof for those.
- A Linux pass validates logic only; anything touching BLE, UI, CoreData, notifications or
  background execution still needs a macOS run.

## Git

Feature work for the user goes on branch `fixes-and-etc`; Linux tooling experiments live on
`linux_experiments`.
