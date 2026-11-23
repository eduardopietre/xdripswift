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

    func testNothingIsResetWithoutATimeZoneChange() {
        let notificationCenter = NotificationCenter()
        var resets = 0
        let observer = SystemTimeZoneChangeObserver(notificationCenter: notificationCenter, resetSystemTimeZone: { resets += 1 })

        notificationCenter.post(name: Notification.Name("SomethingElse"), object: nil)

        XCTAssertEqual(resets, 0)
        withExtendedLifetime(observer) {}
    }
}
