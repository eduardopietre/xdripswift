//
//  HighAlertTrendPolicyTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Tests for skipping high alerts while the glucose is already falling.
///
/// Issue #694: a high alert fired again as soon as its snooze ended, even though the glucose was
/// already coming down, as it does after a correction. xDrip+ on Android lets users skip alerts
/// while the trend goes in the right direction. Here this is an option, off by default, for high
/// and very high alerts only: a low alert must always fire, also when the glucose is rising.
final class HighAlertTrendPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_792_105_000)

    // MARK: - option on (#694)

    func testHighAlertIsSkippedWhileFalling() {
        XCTAssertTrue(HighAlertTrendPolicy.suppresses(isEnabled: true, currentValue: 230, currentTimeStamp: now, previousValue: 240, previousTimeStamp: now.addingTimeInterval(-300)))
    }

    func testHighAlertFiresWhileRisingOrFlat() {
        XCTAssertFalse(HighAlertTrendPolicy.suppresses(isEnabled: true, currentValue: 245, currentTimeStamp: now, previousValue: 240, previousTimeStamp: now.addingTimeInterval(-300)))
        XCTAssertFalse(HighAlertTrendPolicy.suppresses(isEnabled: true, currentValue: 240, currentTimeStamp: now, previousValue: 240, previousTimeStamp: now.addingTimeInterval(-300)))
    }

    func testHighAlertFiresWithoutARecentPreviousReading() {
        XCTAssertFalse(HighAlertTrendPolicy.suppresses(isEnabled: true, currentValue: 230, currentTimeStamp: now, previousValue: nil, previousTimeStamp: nil))
        XCTAssertFalse(HighAlertTrendPolicy.suppresses(isEnabled: true, currentValue: 230, currentTimeStamp: now, previousValue: 240, previousTimeStamp: now.addingTimeInterval(-20 * 60)), "a trend over a gap is unknown")
    }

    // MARK: - option off

    func testHighAlertFiresWhenTheOptionIsOff() {
        XCTAssertFalse(HighAlertTrendPolicy.suppresses(isEnabled: false, currentValue: 230, currentTimeStamp: now, previousValue: 240, previousTimeStamp: now.addingTimeInterval(-300)))
    }
}
