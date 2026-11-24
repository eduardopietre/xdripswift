//
//  DexcomSessionStopDetectionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for sensor stops detected from a Dexcom G5/G6/ONE transmitter.
///
/// Issue #775: a session started 10 seconds after stopping the previous one was stopped by the app
/// 68 seconds later. Start and stop are sent at the next connection, and until the transmitter
/// has processed the start it still reports the previous session as stopped. That state was taken
/// as a new sensor stop, which stopped the session the user had just started (and pre-snoozed the
/// missed reading alert with it).
final class DexcomSessionStopDetectionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_792_105_000)

    // MARK: - pending session start (#775)

    func testStoppedStateRightAfterTheUserStartsASessionDoesNotStopIt() {
        XCTAssertFalse(DexcomSessionStopDetectionPolicy.reportsSensorStop(algorithmStatus: .SessionStopped, sessionStartRequestedAt: now.addingTimeInterval(-58), now: now))
    }

    func testStoppedStateLongAfterTheStartWasRequestedStopsTheSession() {
        let requested = now.addingTimeInterval(-DexcomSessionStopDetectionPolicy.sessionStartGracePeriod - 1)
        XCTAssertTrue(DexcomSessionStopDetectionPolicy.reportsSensorStop(algorithmStatus: .SessionStopped, sessionStartRequestedAt: requested, now: now))
    }

    // MARK: - no pending start

    func testStoppedStateWithoutPendingStartStopsTheSession() {
        XCTAssertTrue(DexcomSessionStopDetectionPolicy.reportsSensorStop(algorithmStatus: .SessionStopped, sessionStartRequestedAt: nil, now: now))
    }

    func testOtherStatesNeverStopTheSession() {
        for status in [DexcomAlgorithmState.okay, .needsCalibration, .SensorWarmup] {
            XCTAssertFalse(DexcomSessionStopDetectionPolicy.reportsSensorStop(algorithmStatus: status, sessionStartRequestedAt: nil, now: now))
        }
    }
}
