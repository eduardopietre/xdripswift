//
//  SystemTimeZoneChangeObserverTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for dates shown after the device's time zone changes.
///
/// Issue #405: after travelling from Pacific to Eastern time, the sensor start was shown three hours
/// off. Foundation caches the system time zone for the lifetime of the process, and the app never
/// cleared that cache, so while it kept running every formatter still used the old time zone.
final class SystemTimeZoneChangeObserverTests: XCTestCase {

    // MARK: - time zone change (#405)

    func testCachedSystemTimeZoneIsResetWhenTheTimeZoneChanges() {
        let notificationCenter = NotificationCenter()
        var resets = 0
        let observer = SystemTimeZoneChangeObserver(notificationCenter: notificationCenter, resetSystemTimeZone: { resets += 1 })

        notificationCenter.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(resets, 1)
        withExtendedLifetime(observer) {}
    }

    /// The report and chart formatters are created once and kept. They must show dates in the time
    /// zone the device is in now, not in the one it was in when they were created.
    func testKeptFormattersFollowTheCurrentTimeZone() throws {
        let savedDefault = NSTimeZone.default
        defer { NSTimeZone.default = savedDefault }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = GlucoseReportFormatting.dateTimeFormatter

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let inLosAngeles = formatter.string(from: date)
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let inNewYork = formatter.string(from: date)

        XCTAssertNotEqual(inLosAngeles, inNewYork)
    }

    func testNothingIsResetWithoutATimeZoneChange() {
        let notificationCenter = NotificationCenter()
        var resets = 0
        let observer = SystemTimeZoneChangeObserver(notificationCenter: notificationCenter, resetSystemTimeZone: { resets += 1 })

        notificationCenter.post(name: Notification.Name("SomethingElse"), object: nil)

        XCTAssertEqual(resets, 0)
        withExtendedLifetime(observer) {}
    }

    // MARK: - app suspended while travelling (#405)

    /// While the app is suspended (for example in flight mode, when no sensor keeps it running) it
    /// misses the time zone notification. UIKit queues its significant time change notification
    /// until the app runs again, so that one must reset the cached time zone as well.
    func testCachedSystemTimeZoneIsResetByEveryGivenNotification() {
        let notificationCenter = NotificationCenter()
        let significantTimeChange = Notification.Name("SignificantTimeChange")
        var resets = 0
        let observer = SystemTimeZoneChangeObserver(notificationCenter: notificationCenter, notificationNames: [.NSSystemTimeZoneDidChange, significantTimeChange], resetSystemTimeZone: { resets += 1 })

        notificationCenter.post(name: significantTimeChange, object: nil)
        notificationCenter.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(resets, 2)
        withExtendedLifetime(observer) {}
    }
}
