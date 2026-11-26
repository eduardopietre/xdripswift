//
//  AlertManagerNextEntryTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the alert type of a delayed alert that fires in the next alert entry.
///
/// When the next entry starts before the current one (it is the entry of the day after), its start
/// had its own value added on top of the 24 hours, so a delayed alert after midnight still used the
/// current entry's alert type.
final class AlertManagerNextEntryTests: XCTestCase {

    func testDelayedAlertAfterMidnightUsesTheNextDaysEntry() {
        // current entry from 20:00, next entry from 06:00 the day after; now 23:50, alert in 7 hours
        XCTAssertTrue(AlertManager.delayedAlertFallsInNextEntry(currentEntryStart: 20 * 60, nextEntryStart: 6 * 60, minutesSinceMidnightNow: 23 * 60 + 50, delayInSeconds: 7 * 3600))
    }

    func testDelayedAlertBeforeTheNextDaysEntryKeepsTheCurrentEntry() {
        // alert in 30 minutes, at 00:20, before the 06:00 entry
        XCTAssertFalse(AlertManager.delayedAlertFallsInNextEntry(currentEntryStart: 20 * 60, nextEntryStart: 6 * 60, minutesSinceMidnightNow: 23 * 60 + 50, delayInSeconds: 30 * 60))
    }

    func testDelayedAlertOnTheSameDay() {
        XCTAssertTrue(AlertManager.delayedAlertFallsInNextEntry(currentEntryStart: 6 * 60, nextEntryStart: 12 * 60, minutesSinceMidnightNow: 11 * 60, delayInSeconds: 2 * 3600))
        XCTAssertFalse(AlertManager.delayedAlertFallsInNextEntry(currentEntryStart: 6 * 60, nextEntryStart: 12 * 60, minutesSinceMidnightNow: 11 * 60, delayInSeconds: 30 * 60))
        // exactly at the start is still the current entry
        XCTAssertFalse(AlertManager.delayedAlertFallsInNextEntry(currentEntryStart: 6 * 60, nextEntryStart: 12 * 60, minutesSinceMidnightNow: 11 * 60, delayInSeconds: 3600))
    }
}
