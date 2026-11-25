# Test platform: robustness and speed analysis

Branch `test-platform-analysis`, created from `testing-coverage` (commit `7932d865`).
This document reviews the two places where the tests run today and lists what to change to make
them **as fast as possible** and **more robust**, ordered by return on effort. Every number marked
*measured* comes from this container (4 vCPU, 15 GB RAM, Swift 6.2.1, Ubuntu 24.04). The macOS
side could not be run here (no Xcode), so its items are based on reading the code and project.

## 0. Status on this branch

| Item | Done in | Result |
|---|---|---|
| L1 write only changed files, L2 parallel suites, L6 coverage scratch path, L7 snippet target only for `snippet` | `linux/xdrip-linux.sh`, `linux/sync-tree.py` | cold 303 s → **104 s**, no change 74 s → **8 s**, after editing one test **7 s** *measured* |
| R4 registration check | `linux/check-test-registration.py` | parses `project.pbxproj`; 123/123 test files compiled by `xdripTests` |
| M1 minimal test host | `XdripApp.isHostingUnitTests` | services are not started when XCTest hosts unit tests |
| M2/M3/M4 test doubles for globals | `xDrip Tests/UserDefaultsSandbox.swift`, `NetworkStub.swift`, `AsyncTestConditions.swift` | 20 tests, Linux suite `test-support` |
| M2 fixed setUp/tearDown sleeps (≈20 s) | the six classes of §4.2 | replaced by `waitUntilStable` on the stub's request count |
| CI | `.github/workflows/tests_linux.yml`, `tests_macos.yml` | Linux on every push/PR, macOS on PRs and on demand |

Still open: L3 (single generator), L4 (merged package), R1 (`extract.py` tokenizer), R2/R3
(expected counts, macOS-only inventory), M5 (test plan), M6 (core package), and moving the six
classes' private `URLProtocol` stubs to `NetworkStub`.

### Writing tests against the app's globals

```swift
@MainActor final class SomeManagerTests: XCTestCase {
    func testUploadsTheNewReading() async throws {
        isolateUserDefaults()                       // no key list; undone in teardown, even after a crash
        UserDefaults.standard.nightscoutUrl = "https://ns.test"

        let network = installNetworkStub()          // URLSession.shared never reaches the internet
        network.on("POST", host: "ns.test", path: "/api/v1/entries") { _ in .json("[]") }

        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)

        await waitForCondition { !network.requests(path: "/api/v1/entries").isEmpty }   // no sleep
        let body = try XCTUnwrap(network.requests(path: "/api/v1/entries").first?.jsonBody as? [[String: Any]])
        XCTAssertEqual(body.count, 1)
    }
}
```

- `isolateUserDefaults(alsoSuites:)` protects the standard defaults (and any suite listed).
- `installNetworkStub()` routes by method/host/path; unanswered requests fail with
  `notConnectedToInternet` and are listed in `unexpectedRequests`
  (`installNetworkStub(failOnUnexpectedRequests: true)` turns them into test failures).
  `waitUntilIdle()` waits for a chain of requests to finish.
- `waitForCondition` fails the test on timeout; `waitUntilStable` (for setUp/tearDown) and
  `drainPendingWork` never fail.
- Fixed sleeps stay only where a test proves that something does **not** happen.

## 1. Where the tests are today

| | macOS (Xcode, `xdripTests`) | Linux (`linux/xdrip-linux.sh`) |
|---|---|---|
| Test files / methods | 118 files, 2316 `func test…`, ~42 k lines | 50 of those files, **587 tests** in 26 suites |
| How | `xdripTests` hosted by `xdrip.app` (`TEST_HOST`), scheme `xdrip`, `parallelizable = YES` | One throwaway SwiftPM package per suite, sources copied or extracted by `extract.py` |
| CI | **None.** No workflow runs any test; `build_xdrip.yml` only builds and uploads to TestFlight | **None** |

The single most important finding: **nothing runs the tests automatically**. Every robustness item
below is worth less until a CI job enforces it.

## 2. Linux: measurements

| Scenario | Wall time | Notes |
|---|---|---|
| Cold, all 26 suites, current script | **303 s** *measured* | 243 s of it is `Build complete` time |
| Rerun with **no change at all**, current script | **74 s** *measured* | still 398 compile steps (332 of the `xdrip` module) |
| Rerun with no change, write-only-if-changed prototype | **23 s** *measured* | 0 compile steps |
| …of which: generating the packages (bash + 329 `python3` processes) | **11.6 s** *measured* | half of the warm time |
| …of which: `swift test` on an up-to-date package | ~0.45–0.85 s per suite *measured* | ×26 suites |
| Cold, 4 suites in parallel (`xargs -P 4`) + prototype | **96 s** *measured* | 3.2× faster than 303 s |
| Time spent actually **executing** the 587 tests | **2.8 s** *measured* | 99 % of the run is infrastructure |
| App lines compiled across suites vs unique content | 98 820 vs 21 992 *measured* | every shared file is compiled **4.5×** |
| Build directory size | 1.4 GB *measured* | 26 separate `.build` trees |
| All suites with `TZ` = UTC, America/Sao_Paulo, Pacific/Chatham (+12:45), Pacific/Kiritimati (+14), America/St_Johns (−3:30) and `LANG=pt_BR.UTF-8` | all pass *measured* | `TZ` is honoured by Foundation on Linux (checked) |

### 2.1 Why it is slow

1. **The incremental build is defeated on every run.** `generate()` starts with
   `rm -rf Sources Tests Package.swift` and rewrites every file. Same content, new mtime, so the
   Swift driver recompiles the whole module each time. This alone turns a ~1 s no-op into 74 s.
2. **Suites run one after the other** on a 4-core machine. Small modules do not saturate the
   cores, and linking plus test startup are single-threaded.
3. **Shared code is compiled once per suite.** `_foundation-extensions`, `_texts-home-view`,
   `ConstantsHomeView`, `UserDefaults` members etc. are rebuilt in up to 26 packages (4.5×
   redundancy), and 26 test binaries are linked.
4. **Generation spawns one Python process per directive** (329 per full run) plus `sed -i` per
   piece and module, re-reading and re-scanning the same large files (`UserDefaults.swift` is 3444
   lines) for every suite.
5. **`coverage` and `test` share one `.build/debug`** with different compiler flags, so switching
   between them forces a full rebuild of the suite (expected from SwiftPM's behaviour, not timed).
6. Each `swift test` also builds the `snippet` executable target, which is only needed by
   `snippet`.

### 2.2 Recommendations, in order

| # | Change | Effort | Expected effect |
|---|---|---|---|
| L1 | **Write only changed files**: generate into `<suite>.staging`, then copy a file only if its bytes differ and delete files that disappeared (≈20 lines; prototype used in the measurements) | XS | no-op rerun 74 s → 23 s *measured*; editing one test recompiles one file |
| L2 | **Run suites in parallel** (`-j N`, default `nproc`), each suite's output buffered to its own log and printed in order at the end so logs stay readable | S | cold 303 s → 96 s *measured* |
| L3 | **One generator process**: move the directive interpreter from bash into `extract.py` (or a new `generate.py`) so each source file is read once and every suite is written in one Python run | S | ~11.6 s → well under 1 s (estimate: one interpreter start plus in-memory work) |
| L4 | **Merged mode: one package for all suites.** Union the directives before writing: a file brought in by `src` wins over `decl`/`members`/`extract` of the same file; `decl` names are merged per file (like `members` already are); `without` lists are merged; identical test files are added once. Only **9 of 177** files are requested in conflicting ways today (`ConstantsHomeView`, `Double`, `Date`, `UserDefaults`, `TextsSettingsView`, `ConstantsGlucoseChartSwiftUI`, `NightscoutDeviceStatusModels`, `TherapyMetricsManager`, `ReportModels`). A naive merge fails with exactly those duplicate declarations *measured*. Keep per-suite mode as a fallback (`--isolated`) for debugging a single suite | M | compile work ÷4.5, one link, one test process; estimate **~30–40 s cold, ~2 s warm** for the full run |
| L5 | Build once, then `swift test --skip-build --parallel` | XS | test execution already 2.8 s; mainly removes double planning |
| L6 | Separate scratch path for coverage (`--scratch-path .build-coverage`) | XS | `test` ↔ `coverage` no longer invalidates each other |
| L7 | Drop the `snippet` target from test packages (add it only for `snippet`) | XS | one link less per suite |
| L8 | Try `-Xswiftc -use-ld=lld` and `-Xswiftc -gline-tables-only` | XS | faster links; measure before adopting |
| L9 | Pre-install the toolchain: `swift:6.2-noble` container image in CI, or the cloud environment's setup script for Claude Code sessions, instead of `install-swift.sh` (~1–2 min, ~3 GB) on every new container | XS | removes the fixed install cost |

Target after L1–L4: **full Linux run in ~2 s when nothing changed, a few seconds after editing a
test, well under a minute cold.**

## 3. Linux: robustness

| # | Finding | Recommendation |
|---|---|---|
| R1 | **`extract.py` counts braces line by line.** A `"""` multi-line string containing `{` (typical JSON fixture) or a `/* } */` block comment shifts the depth. Reproduced: `without json` on a struct whose `json()` returns `"""{"a": {"b": 1}"""` also deleted the next method `kept()` and the struct's closing brace; `decl B` with `/* } */` inside B returned a truncated body. No file used by a suite today has `"""` or `/*`, so this is latent. | Keep tokenizer state across lines (multi-line strings, raw strings `#"…"#`, nested block comments). Add `linux/test_extract.py` (plain `unittest`) with these cases and run it in CI. Longer term, `swift-syntax` would make extraction exact. |
| R2 | **Silent test loss.** A suite that compiles zero tests, or a `without` that removes more than intended, still passes. | After `without`, assert the number of removed `func test…` equals the names listed. Keep `linux/expected-test-counts.txt` (suite → count) and fail when a count drops; the script already sees `Executed N tests`. |
| R3 | **No inventory of what runs where.** 50 test files run on Linux; the other 68 are implicitly macOS-only. | `linux/macos-only.txt` listing each remaining file with its reason (CoreData, UIKit, BLE, OSLog…). CI fails if a test file is in neither list. |
| R4 | **Xcode registration is checked by hand.** A grep for `/* Name in Sources */` gives false positives: `TherapyMetricsTests.swift` is registered under its full path (`xDrip Tests/TherapyMetricsTests.swift`) and was wrongly flagged as missing by such a check during this review. | A small script that parses `project.pbxproj`, resolves the `xdripTests` Sources phase and compares it with `find "xDrip Tests" -name '*.swift'`. Run it in CI. |
| R5 | Timezone and locale coverage depends on the machine. | Nightly matrix on Linux with `TZ` ∈ {UTC, America/Sao_Paulo, Pacific/Chatham, Pacific/Kiritimati, America/St_Johns} and a non-English `LANG` (all pass today *measured*). It costs seconds per run once L1–L4 are in. |
| R6 | 2306 `Date()` calls in tests: results depend on the day the suite runs (DST transitions, month ends). `toMidnight()` already has a known DST bug (see `linux/COVERAGE.md`) that only shows on DST days. | Inject a clock/`now` into the code under test where a decision depends on the date; pin `now` in tests to fixed instants, including DST-change days for the zones above. |

## 4. macOS (Xcode): speed and robustness

These could not be measured here; they come from reading the scheme, the project and the tests.

### 4.1 The test host starts the whole app

`xdripTests` uses `TEST_HOST = xdrip.app`. `XdripApp.init()` calls
`RootApplicationCoordinator().start(...)`, which brings up the real SQLite Core Data store,
Bluetooth, follower timers, Nightscout/LibreLinkUp networking and notifications **before and
while** the tests run. Consequences:

- slower start of every test run, and of every parallel worker (each is a fresh app launch);
- tests that change `UserDefaults.standard` (639 uses in 51 files) are observed by the live
  managers through KVO, so the app reacts to test settings in the background: real network calls,
  timers, Core Data writes;
- background work from the host can overlap with assertions: a classic source of flakiness.

**Recommendation M1 (high value, small change):** when running under XCTest
(`ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`, or an explicit
`XDRIP_UNIT_TESTS=1` set in the test plan), skip `applicationCoordinator.start` and show an empty
scene. Tests already build their own managers with `CoreDataManager(inMemoryModelName:)`.

### 4.2 Fixed sleeps

Measured statically over `xDrip Tests`:

- `setUp`/`tearDown` sleeps run for **every test** of six classes: 0.2–0.6 s each, **≈20 s in total**
  (`NightscoutCoverageUploadTests` 0.6 s × 8, `FollowerCoverageLibreLinkUpTests` 0.3 s × 17,
  `NightscoutCoverageSyncManagerTests` 0.2 s × 19, `FollowerCoverageDexcomShareFollowTests`,
  `NightscoutCoverageFollowManagerTests`, `NightscoutCoverageSyncFlowTests`);
- other `Task.sleep` literals inside tests add **≈10 s**, plus `Thread.sleep` in
  `M5StackPacketRoundTripTests` and `NightscoutCoverageGapFillRunTests`.

They wait for background work of the managers to settle. A fixed sleep is both slow (always paid)
and flaky (not enough on a loaded CI machine).

**M2:** give these managers a test seam: a handle to the work they start (`Task` they return or
store, `func waitUntilIdle() async`, or an injected scheduler/clock). Replace setUp/tearDown sleeps
with awaiting that, and the polling `waitUntil(timeout: 5)` loops with expectations fulfilled by
the stub. For M5Stack, inject the timestamp instead of sleeping past
`maximumTimeBetweenTwoPacketsInMs`.

### 4.3 Global state

- **M3 `URLProtocol.registerClass`** is used in five Nightscout test files. It intercepts every
  `URLSession.shared` request in the process, including the host app's. Four other files already
  do it right with `URLSessionConfiguration.protocolClasses`. Make that the only pattern: let the
  managers take a `URLSession` (or configuration) parameter.
- **M4 `UserDefaults.standard`** persists in the simulator between runs. Tests snapshot and
  restore keys in `tearDown`, but a crash or a timeout skips `tearDown` and leaves state that
  changes the next run. Short term: an `XCTestObservation` registered by the bundle that wipes
  the app's defaults domain in `testBundleWillStart` (simulator only). Long term: inject a
  `UserDefaults(suiteName:)` per test, as `GlucoseAdjustmentTests` and `DirectWatchBridgeTests`
  already do.

### 4.4 Test plan

**M5:** replace the inline scheme test action with an `.xctestplan`:

- *Randomize execution order* to expose order dependencies (shared defaults, singletons);
- configurations for timezone/locale (UTC/en, America/Sao_Paulo/pt-BR, Pacific/Chatham);
- execution time allowance (e.g. 60 s per test) so a hang fails one test instead of the job;
- code coverage only for the `xdrip` target;
- parallel execution kept on.

### 4.5 Strategic: a real core package

The Linux tooling exists because the platform-independent code lives inside the app target. The
26 suites already show which code is Foundation-only (128 `src` lines: Dexcom messages, Libre 3
protocol, report math, follower models…).

**M6:** move those areas, one at a time, into a local Swift package (e.g. `Packages/XDripCore`)
that the app depends on. Then:

- `swift test` runs them natively on **both** Linux and macOS, in seconds, without a simulator or
  a host app;
- `extract.py`, `decl`/`members` and most shim modules disappear for those areas (the fragile part
  of the platform, see R1);
- incremental builds of the app get faster, because changes in the app do not recompile the core.

Cost: `public` access on the moved API and `import XDripCore` where it is used. Good first
candidates, already isolated: `Dexcom/Generic` (41 files) and `Libre3/Protocol` (18 files).

## 5. CI proposal

| Job | Runner | Trigger | Content | Expected time |
|---|---|---|---|---|
| `tests-linux` | `ubuntu-latest`, container `swift:6.2-noble` | every push and PR | `test_extract.py`, registration and inventory checks (R3, R4), `xdrip-linux.sh test -j` with expected counts (R2); cache the build directory keyed on `linux/**` | ~1–2 min cold today with L1+L2; less with L4 |
| `tests-linux-nightly` | same | schedule | the `TZ`/`LANG` matrix (R5) and `coverage` | minutes |
| `tests-macos` | `macos-26` | PR + nightly | `xcodebuild build-for-testing` then `test-without-building -testPlan …`, `-parallel-testing-enabled YES`, `-resultBundlePath`, upload the `.xcresult`; cache DerivedData and SwiftPM | to be measured after M1/M2 |
| `tests-macos-flaky` | `macos-26` | weekly | `-test-iterations 5 -run-tests-until-failure` to surface flaky tests (no automatic retries on PRs: retries hide flakiness) | |

Notes: the workflows in this repository serve the "build in the browser" flow for forks and use
repository secrets; the test jobs must not need any secret so they also run on forks and PRs.
macOS minutes cost about 10× Linux minutes, which is one more reason to move as much as possible
to the Linux job (L4, M6).

## 6. Suggested order of work

1. L1 + L2 + L7 (one small PR to `linux/xdrip-linux.sh`): cold 303 s → ~96 s, no-op 74 s → ~23 s.
2. `tests-linux` workflow with R2, R3, R4.
3. R1 (tokenizer fix + `test_extract.py`) and L3 (single generator).
4. L4 merged mode: the full Linux run in a couple of seconds when warm.
5. macOS: M1 (minimal host), M3 (no global URLProtocol), M2 (remove sleeps, ≈30 s), M5 test plan,
   `tests-macos` workflow.
6. M6: start `XDripCore` with Dexcom messages and the Libre 3 protocol.

## Appendix: how the numbers were taken

```bash
export XDRIP_LINUX_BUILD=/tmp/…/build
linux/xdrip-linux.sh test          # cold: 303 s, then again with no change: 74 s
```

The write-only-if-changed prototype replaced the `rm -rf` in `generate()` with "generate into
`<suite>.staging`, then copy each file only when `filecmp.cmp(..., shallow=False)` says it differs
and delete files that are gone". The parallel run was
`linux/xdrip-linux.sh list | xargs -P 4 -I{} <prototype> test {}` into an empty build directory.
Static counts (`Date()`, `UserDefaults.standard`, sleeps) were taken with `grep` over
`xDrip Tests/`; the setUp/tearDown sleep total multiplies each class's sleeps by its number of
`func test` methods.
