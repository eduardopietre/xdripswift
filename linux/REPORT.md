# `linux_experiments` report

This branch was created from `fixes-and-etc` in a Linux cloud session (no Xcode, simulator or
device). It does two things:

1. Builds tooling that runs the platform-independent parts of xDrip4iOS, and their unchanged
   XCTest files, with the open-source Swift toolchain on Linux.
2. Uses that tooling to work through the high (6–7) and medium (4–5) rated issues of the upstream
   repository, `JohanDegraeve/xdripswift`, with one regression-test commit followed by one fix
   commit per issue.

Nothing on this branch has been compiled by Xcode or run on a device. Changed app code was
syntax-checked with `swiftc -parse`. Logic covered by a Linux suite was compiled and tested on
Linux. Before merging, build the app and run `xDrip Tests` on macOS, and check the opt-in audio
change (#741) on a device.

## 1. Linux tooling

### Why

The full test suite needs macOS. Most logic in the app (protocol parsing, calculations, state
rules) only needs Foundation. Running it on Linux gives fast feedback in cloud sessions and makes
test-first fixes possible there.

### What was built (`linux/`)

| File | Purpose |
|---|---|
| `install-swift.sh` | Installs the official Swift toolchain into `/opt/swift` (tested with 6.2.1 on Ubuntu 24.04). |
| `xdrip-linux.sh` | `test [suite…]`, `snippet <file> [suite…]`, `list`. Generates one throwaway SwiftPM package per suite in `/tmp/xdrip-linux/<suite>` with a library module named `xdrip`, so `@testable import xdrip` works unchanged. |
| `extract.py` | Copies real sources into the package: whole files, single top-level declarations (`decl`), single members of a type (`members`, including enum `cases` and all overloads), or a file without some members (`without`). It drops `@objc`/`dynamic` and imports `FoundationNetworking`. |
| `suites/*.txt` | One suite per test file: which sources and tests go in. `_*.txt` files are shared fragments (`include`). |
| `shim-modules/` | Minimal stand-ins for Apple modules so files keep their imports: `CommonCrypto` (AES-ECB, validated by the Libre 3 AES-CCM vectors), `SwiftUI` (`Color`, `Font.Weight`, `Animation`), `UIKit` (`UIColor`), `Combine` (storage-only `@Published`), `ActivityKit`, `WidgetKit`. |
| `find-type.sh` | Shows where a type is declared and what its file imports. |
| `add-test-to-xcodeproj.py` | Registers a new file of `xDrip Tests` in `xdrip.xcodeproj` (the four entries Xcode writes), so tests written without Xcode also run on macOS. |
| `snippets/` | Example of running app code from a script. |

`CLAUDE.md` documents the setup, every directive, the shim modules, the coverage and the known
Linux differences. Contributions must be in English and follow the project's code style.

### Coverage

26 suites with 276 tests run on Linux. 15 suites port existing test files, in some cases without
the methods that need CoreData, UIKit views, KVO or networking managers. The other 11 suites hold
the new regression tests from section 2.

| Ported test file | Tests on Linux |
|---|---|
| Libre3 AESCCM, BleFraming, DataPlane, NFCActivationCommand, ReceiverID | 43 |
| TherapyMetricsTests | 35 of 48 |
| CGMG5SensorSessionDetectionTests | 24 of 26 |
| LiveActivityWarmupTests | 21 of 22 |
| BluetoothSignalStrengthTests | 17 |
| NightscoutFollowerGapFillTests | 16 |
| GlucoseRangeDistributionTests | 14 |
| RootHomeInteractionTests | 12 of 15 |
| OnlineHelpTests | 10 |
| GlucoseChartYAxisRetentionTests | 10 of 12 |
| SensorNoisePersistenceTests | 9 |
| DexcomG6BluetoothSlotTests | 8 |
| CalibrationReadinessTests | 4 |
| Libre2FrameAssemblerTests | 3 |
| BgReadingDownstreamPolicyTests | 3 (BgReadingTrendTests needs CoreData) |

### Findings from running the ported tests

- **Real bug reproduced:** two `GlucoseRangeDistributionTests` fail on `fixes-and-etc` on any
  platform. Summing `3.6 + 87.6 + 8.8` left to right gives `99.99999999999999`, so floating-point
  noise decides the largest-remainder tie. Branch `testing` already fixes this in `ec8a1cd` with a
  tie tolerance; it is not on `fixes-and-etc` yet.
- **Linux difference:** `UserDefaults.object(forKey:) as? Double` returns nil for a stored `Int` on
  Linux (no NSNumber bridging), so one TherapyMetrics test is left out there.

## 2. Upstream issues

### Method

- Issues were read through the GitHub search API, because the upstream REST endpoints are blocked
  in this environment. Bodies were available; comments were not.
- External behaviour was checked against the real source code of the other projects. Nightscout,
  iAPS and Trio were cloned into the scratchpad for this.
- Per issue there are two commits. The first adds the regression test, plus a seam that keeps
  today's behaviour when the code needed one to be testable, so the test compiles and fails. The
  second adds the fix, with the issue number in the message.
- When a test can run on Linux, it was shown failing after the first commit and passing after the
  second. New test files are registered in the Xcode project.

### Fixed

| Issue | Problem | Fix | Test commit → fix commit |
|---|---|---|---|
| #283 | Sensor errors (stored as 38 mg/dL) were written to Apple Health as hypos. | Only readings from 39 mg/dL up are written (`HealthKitReadingPolicy`). | `50cad05` → `e33dd22` |
| #781 | Small Doses gives every bolus ≤ 0.1 U and every carb amount ≤ 1 g the same marker. | New Extra Small Doses scale (0.05–1 U, 0.5–20 g, 18–30 pt markers) as a third Treatment Scale option, in its own setting, translated into 18 languages. | `1e7ec0e` → `35fe941` |
| #636 | Verify rejected valid Nightscout tokens: the token was sent as plain text in `api-secret`, which only recent Nightscout versions accept for tokens. | The token is sent as the `token` query parameter, as syncing already does (`NightscoutCredentialsCheck`). | `6a04c8d` → `8a5d934` |
| #560 | In mmol/L, readings shown with the same value were plotted at different heights. | Readings are plotted at their displayed, rounded mmol/L value (`GlucoseChartPlotValue`), in all charts. | `fc59db3` → `3ca4ccc` |
| #337 | Fast rise and fast drop alerts did not say how big the change was. | The delta is added to those alerts, e.g. "9.2 ↑ +0.7 mmol/L" (`BgReadingAlertBody`). The app still does not speak alerts. | `0637e95` → `0d249a9` |
| #418 | The screen could lock after a new sensor was found but before it connected, which broke Libre 2 pairing. | The screen stays awake from scanning until the connection (`AddDeviceScreenLockPolicy`). | `dad8a70` → `26b69bf` |
| #775 | Stopping and restarting a Dexcom session: the transmitter's leftover "stopped" state stopped the new session 68 s later. | A stopped state is ignored while a user-requested start is pending, for at most 15 min (`DexcomSessionStopDetectionPolicy`). | `668af59` → `d19e16a` |
| #269 | The Calendar Share event had no location, so watch faces looked bare. | New optional Event Location text setting (`CalendarShareEventLocation`). | `b75499b` → `a5b4a44` |
| #624 | Meals edited in iAPS appeared twice. iAPS deletes the record and uploads a new one with a new `_id`. | Remote deletions were already reconciled since `bb35b52` (test `250fef5`). A remaining gap was fixed: only the latest 50 treatments were checked, about 4 hours with an AID's temp basals. Now the whole 24-hour download window is checked. | `250fef5`, `1156b5b` → `802c266` |
| #405 | After changing time zone, times stayed in the old one. | Foundation caches the system time zone. It is now reset on `NSSystemTimeZoneDidChange` (`SystemTimeZoneChangeObserver`). | `d2471c4` → `c9311a4` |
| #329 | AID apps could not create sensor changes in Nightscout from xDrip4iOS readings. | Shared readings now carry `sessionStartDate` and `transmitterID` in the Dexcom format (`LoopShareSensorSession`). iAPS and Trio do not read them yet and need to adopt them. | `ce84773` → `3204f55` |
| #694 | High alerts fired again while the glucose was already falling. | Opt-in setting, Skip High Alerts While Falling, off by default (`HighAlertTrendPolicy`). Low alerts are never skipped. | `ea902ad` → `7ea7e6b` |
| #741 | Spoken readings were hard to hear over music. | Opt-in setting, Lower Other Audio, off by default. Ducks other audio while speaking; the shared audio session is never deactivated. | `518ccce` → `573d99e` |
| #795 | The sensor health banner cut its guidance off after three lines, and it is shown nowhere else. | The guidance wraps fully. Layout-only, so there is no unit test. | `6aa5350` |

The tests for #624 (CoreData) and #741 (AVFoundation) only run on macOS. All others also run on
Linux.

### Not changed, with the reason

These were decided with the user (skip, or record and close):

| Issue | Reason |
|---|---|
| #762 | Solved by open upstream PR #763 (by the reporter, with tests); skipped until it is merged. Its head is fetchable as `refs/pull/763/head`. |
| #540 | Already done: contact images use the app's semantic colours since `8e13e50`. |
| #111 | Already done: Speak Glucose can say only the value since `9ef9b98`. |
| #246, #190 | The delta is per 5 minutes by definition, and "use five minute readings" exists. Changing the definition is a product decision. |
| #708, #628 | Not reproducible in the current code (reported before the v7 rewrites), and no sample data. |
| #621 | Asks for a UX design, with no defined behaviour to implement. |
| #695 | A new alarm type (carbs required); a large feature left for a product decision. |
| #509 | A question about logs, answered by the v7 Troubleshooting Log. |
| #493 | Adopting a third-party build script that cannot be tested without macOS. |

## 3. Before merging

1. Build the app and run `xDrip Tests` on macOS, including the 13 new test files.
2. On a device, check Lower Other Audio (#741) with music playing, and that background keep-alive
   and alarms keep working.
3. Port `ec8a1cd` from `testing` to fix the reproduced `GlucoseRangeDistribution` tie bug.
4. Translations: the new settings for #269, #694 and #741 use their English text as the default in
   all languages until translated. #781 is translated into all 18 languages.
