//
//  TimeIntervalExtensionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers the `TimeInterval` unit helpers with fractional, negative and chained values.
///
/// The helpers are used for alert snooze periods, sensor lifetimes and the Home chart window
/// (which subtracts `.hours(-range)` from the end date). A wrong factor in one initializer
/// propagates through the chained ones (`days` -> `hours` -> `minutes`), so the tests check
/// every step against seconds computed by hand.
final class TimeIntervalExtensionTests: XCTestCase {

    /// Fractional units must keep their fraction: a 1.5 minute delay is 90 seconds, not 60 or 120.
    func testFactoriesKeepFractionalUnits() {
        XCTAssertEqual(TimeInterval.minutes(1.5), 90)
        XCTAssertEqual(TimeInterval.hours(0.25), 900)
        XCTAssertEqual(TimeInterval.days(0.5), 43_200)
        XCTAssertEqual(TimeInterval.seconds(0.25), 0.25)
        // A ten-day sensor lifetime in seconds.
        XCTAssertEqual(TimeInterval(days: 10), 864_000)
        // A 14.5-day Libre sensor lifetime.
        XCTAssertEqual(TimeInterval(days: 14.5), 1_252_800)
    }

    /// Negative values are used to look back in time (chart start date, lookback windows) and must
    /// convert with the same factors as positive ones.
    func testNegativeIntervalsLookBackInTime() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let start = end.addingTimeInterval(.hours(-3))

        XCTAssertEqual(TimeInterval.hours(-3), -10_800)
        XCTAssertEqual(end.timeIntervalSince(start).hours, 3)
        XCTAssertEqual(start.timeIntervalSince(end).minutes, -180)
        XCTAssertEqual(TimeInterval(days: -1).hours, -24)
    }

    /// The accessors are the exact inverse of the factories, so a value can be converted back to
    /// the unit it was entered in without drift.
    func testAccessorsInvertTheFactories() {
        for value in [0.0, 0.5, 1, 7, 13.25, 90, 365] {
            XCTAssertEqual(TimeInterval.minutes(value).minutes, value, accuracy: 1e-12)
            XCTAssertEqual(TimeInterval.hours(value).hours, value, accuracy: 1e-12)
            XCTAssertEqual(TimeInterval.days(value).days, value, accuracy: 1e-12)
        }
        // Cross-unit: 36 hours are 1.5 days and 2160 minutes.
        let thirtySixHours = TimeInterval(hours: 36)
        XCTAssertEqual(thirtySixHours.days, 1.5)
        XCTAssertEqual(thirtySixHours.minutes, 2160)
    }
}
