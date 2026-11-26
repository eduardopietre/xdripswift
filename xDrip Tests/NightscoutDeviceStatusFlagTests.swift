//
//  NightscoutDeviceStatusFlagTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the flag that tells the watch manager a Nightscout device status arrived.
///
/// nightscoutDeviceStatusWasUpdated was stored under the nightscoutSyncRequired key, so setting
/// either flag changed the other one.
final class NightscoutDeviceStatusFlagTests: XCTestCase {

    private let suiteName = "NightscoutDeviceStatusFlagTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The watch manager observes the device status key, so the flag must be stored there.
    func testDeviceStatusFlagIsStoredUnderItsOwnKey() {
        defaults.nightscoutDeviceStatusWasUpdated = true
        XCTAssertTrue(defaults.bool(forKey: UserDefaults.Key.nightscoutDeviceStatusWasUpdated.rawValue))
        XCTAssertFalse(defaults.nightscoutSyncRequired, "a device status alone does not ask for a sync")
    }

    /// The watch manager resets the flag after handling it; that must not drop a pending sync.
    func testResettingTheDeviceStatusFlagKeepsAPendingSync() {
        defaults.nightscoutSyncRequired = true
        defaults.nightscoutDeviceStatusWasUpdated = false
        XCTAssertTrue(defaults.nightscoutSyncRequired)
    }

    func testARequiredSyncIsNotADeviceStatusUpdate() {
        defaults.nightscoutSyncRequired = true
        XCTAssertFalse(defaults.nightscoutDeviceStatusWasUpdated)
    }
}
