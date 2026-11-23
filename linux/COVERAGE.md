# Linux test coverage on `testing-coverage`

This branch was created from `testing`. It brings the Linux test tooling from `linux_experiments`
and uses line coverage to guide new tests. The full `xDrip Tests` suite needs macOS. On Linux
only the app code that compiles without Apple frameworks is built, so the coverage numbers below
are for that code, not for the whole app.

Measure with:

```bash
linux/install-swift.sh                       # once per container
COVERAGE_FILES=25 linux/xdrip-linux.sh coverage
```

`coverage` runs every suite with code coverage. `linux/coverage.py` then merges the line hits of
the app code compiled into the suites. Test code and shim modules are not counted. It reports two
numbers:

- all compiled app lines;
- the same lines without the `Texts_*` tables of localized strings, which have nothing to test.

## Result

| | Before (`testing`) | After |
|---|---|---|
| Tests run on Linux | 229 in 15 suites | **587** in 26 suites (2.56×), all passing |
| Compiled app lines covered | 3157 / 7387 (42.7%) | 7249 / 11488 (63.1%) |
| Same, without string tables | 3133 / 6035 (51.9%) | 7126 / 10070 (70.8%) |

The denominator grew by about 4000 lines because the new suites compile code that was not built
on Linux before: Dexcom messages, Libre 1/2 parsing, follower and Nightscout models, and report
math. Extracted pieces of the same file in different suites (for example `ConstantsHomeView`)
are counted once per suite, which keeps the percentages conservative.

371 test methods were added in 31 new test files, all registered in `xdrip.xcodeproj`. 358 of them
run on Linux. Thirteen run only on macOS:

- 11 Libre 2 decryption tests, because `PreLibre2` declares an `OSLog`;
- 2 rounding tests, because they use `Darwin.round`.

The test count on macOS therefore goes from about 1945 to about 2316.

| Area | New tests | Main files, Linux line coverage before → after |
|---|---|---|
| Libre 3 protocol | 80 | realtime reading 41% → 100%, data plane state 30% → 100%, phase 6 response and challenge 0% → 98–100%, clinical records 0% → 100%; whole Libre 3 suite 62% → 96% |
| Followers and Nightscout models | 82 | FollowerDataSourceType 0% → 98%, DataFlowPolicy 16% → 100%, NightscoutFollowType 0% → 97%, NightscoutProfileModels 14% → 100%; device status decoding (Loop 3, AAPS, iAPS, Trio documents) 96% |
| Dexcom messages and `Data` | 77 | `Data.swift` 5% → 100%; most `Dexcom/Generic` files 0% → 100% |
| Glucose and report math | 80 | CalibrationReadiness 37% → 88%, RootHomeChartRange 55% → 100%, TimeInterval 40% → 100%, SensorNoiseCalculator 84% → 97%, report math 100% |
| Libre 1/2 parsing and M5Stack | 52 | CRC, serial number, measurements, calibration and M5Stack packets 0% → 82% (not compiled before) |

The new tests check behaviour, not constants:

- byte layouts built field by field, and CRCs that must catch every single-bit flip;
- rejection of truncated or tampered input, and boundary values at the thresholds;
- decision tables over every input combination;
- realistic JSON documents from the apps the follower reads;
- hand-computed clinical values.

Each new area was checked by breaking the code under test temporarily and seeing its tests fail.

## Possible bugs found (app code not changed, no failing tests added)

| Where | What |
|---|---|
| `Extensions/Date.swift`, `toMidnight()` | One hour off on daylight saving days. It subtracts h×3600 + m×60 + s instead of using `Calendar.startOfDay`. Example (Europe/Amsterdam): 2026-03-29 05:00 gives 2026-03-28 23:00. It is used for the BG readings, treatments and landscape date ranges. |
| `Managers/Nightscout/NightscoutDeviceStatusModels.swift`, `Pump.Extended` | AAPS sends `Version`, `ActiveProfile` and `BaseBasalRate` capitalized. The keys are lowercase, so the active profile and base basal from AAPS are always nil. |
| Same file, `NightscoutDeviceStatusResponse.uploader` | One document with a text `uploader` (some uploaders send `"GG-Host"`) makes decoding of the whole device status list fail, so the follower shows no AID status. AndroidAPS added a lenient serializer for this case. |
| Same file, around line 475 | Suggested and enacted are ordered by comparing timestamp texts. This is wrong when the two use different formats (fractional seconds, offsets). |
| `Libre3ClinicalReadingRecord`, `Libre3HistoricalReadingPage` `init(plaintext:)` | Index from 0 instead of `startIndex`, so a `Data` slice crashes. Not reachable today, because decryption returns a fresh buffer. |
| `Libre/Utilities/CRC.swift`, `LibreCrc` | The length check ignores `headerOffset`. With offset 18 and 344–361 bytes it crashes instead of returning false. Callers check the length first. |
| `Libre/Utilities/Libre2BLEUtilities.swift`, `decryptBLE` | No length check: fewer than 46 bytes crashes, and more than 66 overruns the key. The frame assembler always passes 46. |
| `Dexcom/Generic/DexcomBackfillStream.decode()` | Calling it twice can misalign after a skipped record. It is called once today. |
| `Dexcom` `BatteryStatusRxMessage` (10-byte frame) | `temperature` is read from byte 9, which is a CRC byte in that frame. The layout could not be confirmed. |
| `Extensions/Double.swift` | The displayed value rounds halves to even and `bgValueRounded` rounds them away from zero, so 100.5 shows as "100" but rounds to 101. `minutesToDaysAndHours(-30)` gives "-1d0h". |

## Not covered on Linux

UI, CoreData, CoreBluetooth, notifications, HealthKit and networking managers do not compile on
Linux, and neither does code that needs `os.OSLog` or `CryptoKit`. A minimal `os` shim module
would let `PreLibre2`, `Libre2BLEUtilities` and `LibreDataParser` run here too.
