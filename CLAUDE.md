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
linux/xdrip-linux.sh test                          # all suites (each in its own package)
linux/xdrip-linux.sh test libre2-frame-assembler   # selected suites
SWIFT_TEST_ARGS="--filter testAnubis" linux/xdrip-linux.sh test dexcom-g6-bluetooth-slot
linux/xdrip-linux.sh snippet linux/snippets/libre2-assembler-demo.swift libre2-frame-assembler dexcom-g6-bluetooth-slot
linux/find-type.sh SomeType OtherType              # where a type lives and what its file imports
linux/add-test-to-xcodeproj.py NewTests.swift      # register a new file of xDrip Tests in the Xcode test target
```

**New test files must be registered in `xdrip.xcodeproj`** or they never run on macOS: there is no
Xcode here, so run `linux/add-test-to-xcodeproj.py <FileName.swift>` after creating one.

`snippet` runs any Swift script against the real app sources (use `@testable import xdrip`),
handy to probe behaviour or reproduce an issue quickly. It merges the given suites into one module,
so pick suites that do not extract the same declarations (default: all, which may clash).

### How it works

`linux/xdrip-linux.sh` generates throwaway SwiftPM packages in `$XDRIP_LINUX_BUILD` (default
`/tmp/xdrip-linux/<suite>`) with a library module named **`xdrip`**, so the original test files
with `@testable import xdrip` compile unchanged. Real files are **copied**, never edited; the
Xcode project is untouched. Every copy goes through `linux/extract.py`, which also drops `@objc`
and `dynamic` (no Objective-C runtime) and imports `FoundationNetworking` (URLRequest on Linux). Each suite builds separately (builds are cached per suite);
the exit code is non-zero when any suite fails.

Each `linux/suites/<name>.txt` lists what goes in (`#` comments allowed, paths relative to the
repo root, spaces in paths are fine). Files named `_<name>.txt` are shared fragments, never run alone:

```
src     <path> [| without a, b]          # source file into module xdrip, optionally minus members
test    <path> [| without a, b]          # XCTest file, optionally minus test methods / classes
decl    <path> | TypeA, TypeB            # only these top-level declarations (and their extensions)
members <path> | Type | a, b, cases      # Type with only these members; `cases` = all enum cases.
                                         #   Requests for the same type are merged across fragments.
extract <path> | <start-regex> | <end-regex>  # raw line range (end line excluded)
testdecl <path> | TestClassA             # only these test classes
include <fragment>                       # another suite file; each fragment is added once
module  <Name>                           # shim module from linux/shim-modules/<Name>
```

Pick the narrowest directive that compiles: `src` for Foundation-only files, `decl`/`members`
for big files that mix pure logic with UIKit/CoreData (e.g. `UserDefaults.swift`, `Texts_*`,
`ConstantsHomeView.swift`), `without` for the few members or tests that cannot work on Linux.
Always write *why* something is left out in a `#` comment next to it.

### Shim modules (`linux/shim-modules/`)

Minimal stand-ins so app files keep their original `import` lines. They contain only what ported
code needs; extend them deliberately and keep them honest (no fake behaviour that could make a
test pass for the wrong reason).

| Module | Provides |
|---|---|
| `CommonCrypto` | `CCCrypt` AES-ECB encryption (FIPS-197), validated by the Libre 3 AES-CCM test vectors |
| `SwiftUI` | `Color` (components or asset name), `Font.Weight`, `Animation`, `withAnimation`; re-exports UIKit and Combine |
| `UIKit` | `UIColor` with system colours |
| `Combine` | `ObservableObject`, `@Published` as plain storage (nothing is published) |
| `ActivityKit` | `ActivityAttributes` protocol |
| `WidgetKit` | empty |

A module's `DEPENDENCIES` file lists the shim modules it imports.

### Adding a suite

1. Pick a test file; note which test methods need CoreData, UIKit views, KVO, notifications etc.
2. Start the suite with `test <path> | without <those methods>` and iterate: build, then run
   `linux/find-type.sh` on the missing names, and add the narrowest directive for each.
   Reuse fragments (`_foundation-extensions`, `_texts-home-view`, `_app-colors`,
   `_sensor-noise-calculator`, `_sensor-health-models`, `_widget-payload`) before adding lines.
3. Never change app code just to make it build on Linux unless asked.
4. Sanity-check by temporarily breaking the logic under test and seeing it fail, then
   `git checkout --` the file.
5. When a test fails, find out whether it fails on iOS too before blaming Linux (see below).

### Current suites (264 tests on `linux_experiments`, based on `fixes-and-etc`)

| Suite | Test file (tests run on Linux) | Left out |
|---|---|---|
| `libre2-frame-assembler` | Libre2FrameAssemblerTests (3) | |
| `dexcom-g6-bluetooth-slot` | DexcomG6BluetoothSlotTests (8) | |
| `libre3-protocol` | Libre3 AESCCM, BleFraming, DataPlane, NFCActivationCommand, ReceiverID (43) | Libre3IntegrationTests, Libre3Phase6ResponseTests (CryptoKit) |
| `sensor-noise` | SensorNoisePersistenceTests (9) | |
| `glucose-range-distribution` | GlucoseRangeDistributionTests (14, **2 fail**, see below) | |
| `bluetooth-signal-strength` | BluetoothSignalStrengthTests (17) | |
| `calibration-readiness` | CalibrationReadinessTests (4) | |
| `online-help` | OnlineHelpTests (10) | |
| `nightscout-follower-gap-fill` | NightscoutFollowerGapFillTests (16) | |
| `cgm-g5-sensor-session-detection` | CGMG5SensorSessionDetectionTests (24) | 2 (SwiftUI state, CoreData backup) |
| `root-home-interaction` | RootHomeInteractionTests (12) | 3 (UIKit orientation, RootHomeStateModel) |
| `live-activity-warmup` | LiveActivityWarmupTests (21) | 1 (UserDefaults KVO) |
| `glucose-chart-y-axis-retention` | GlucoseChartYAxisRetentionTests (10) | 2 (GlucoseChartStateManager/CoreData) |
| `bg-reading-downstream-policy` | BgReadingDownstreamPolicyTests (3) | BgReadingTrendTests (CoreData) |
| `therapy-metrics` | TherapyMetricsTests (35) | 13 (CoreData, rendering, settings view models, UserDefaults bridging) |
| `healthkit-reading-policy` | HealthKitReadingPolicyTests (3), #283 | |
| `treatment-scale` | TreatmentScaleTests (5), #781 | |
| `nightscout-credentials-check` | NightscoutCredentialsCheckTests (4), #636 | |
| `glucose-chart-plot-value` | GlucoseChartPlotValueTests (4), #560 | |
| `bg-reading-alert-body` | BgReadingAlertBodyTests (4), #337 | |
| `add-device-screen-lock` | AddDeviceScreenLockPolicyTests (4), #418 | |
| `dexcom-session-stop-detection` | DexcomSessionStopDetectionTests (4), #775 | |
| `calendar-share-event-location` | CalendarShareEventLocationTests (3), #269 | |

NightscoutTreatmentEditSyncTests (#624) needs CoreData and only runs on macOS.

Not ported (cost outweighs value; they are mostly CoreData, UIKit, notifications or networking
managers): FollowerSettings, LibreLinkUpDownloadChain, BasalInjection, BatteryHistory,
BluetoothPeripheralDisplayStatus, CareLink, DexcomG6SensorLabel, DexcomG7Calibration,
DexcomShareUpload, DirectWatchBridge, FollowerBackgroundKeepAliveManager, GMIStatistics,
GlucoseAdjustment, MissedReadingSnooze, RepeatingAlarm, SensorExpiryReminderManager,
SensorHealthIssueManager, TroubleshootingLog.

### Known failures and Linux differences

- **GlucoseRangeDistributionTests (2 failures) are real** and also fail on iOS: summing
  `3.6 + 87.6 + 8.8` left to right gives `99.99999999999999`, so floating-point noise decides the
  largest-remainder tie (`[3, 88, 9]` instead of `[4, 87, 9]`). Fixed on branch `testing` (commit
  `ec8a1cd`, tie tolerance `1e-9`), not yet on `fixes-and-etc`. (Python's `sum()` uses compensated
  summation and hides this; reproduce with a plain loop.)
- `UserDefaults.object(forKey:) as? Double` returns nil on Linux for a stored `Int` (no NSNumber
  bridging); one TherapyMetrics test is left out for that.
- No Objective-C runtime: `@objc`, KVO (`observe(\.key)`), `#selector` do not work.
- Foundation is swift-corelibs-foundation: `DateFormatter`/locale and `UserDefaults` edge cases
  can differ, so a Linux pass is not proof for those.
- Combine is a storage-only shim: nothing that subscribes to publishers can be tested.
- A Linux pass validates logic only; BLE, UI, CoreData, notifications and background execution
  still need a macOS run. Tests that are flaky only when run in parallel on the simulator
  are mostly CoreData-based and are not covered here.

## Working on upstream issues

- Issues live in `JohanDegraeve/xdripswift`. Its REST endpoints are blocked in cloud sessions;
  read issues with the search API instead, e.g.
  `gh api -X GET search/issues -f q='repo:JohanDegraeve/xdripswift is:issue 624 in:number'`
  (gives title, body and comment count, not the comments). Upstream PR heads can be fetched with
  `git fetch https://github.com/JohanDegraeve/xdripswift refs/pull/<n>/head:refs/remotes/upstream-pr/<n>`.
- Public projects the app talks to (Nightscout, iAPS, Trio) can be cloned into the scratchpad to
  check their real behaviour before deciding a fix.
- Per issue: one commit with a regression test (if the code needs a seam to be testable, add it in
  that commit without changing behaviour, so the test compiles and fails), then one commit with
  the fix and `#<issue>` in the message. Add a Linux suite for the test when possible and show it
  failing before and passing after.

## Git

Feature work for the user goes on branch `fixes-and-etc`; Linux tooling experiments live on
`linux_experiments`.
