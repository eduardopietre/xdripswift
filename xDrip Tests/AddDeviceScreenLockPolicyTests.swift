//
//  AddDeviceScreenLockPolicyTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for keeping the screen awake while a CGM is being added.
///
/// Issue #418: after scanning a new Libre 2 sensor the iPhone locked its screen while the sensor
/// was still connecting and pairing, and pairing did not complete after unlocking. The screen was
/// kept awake while scanning, but allowed to lock as soon as the sensor was found, which is
/// before the connection is made and the sensor is unlocked.
final class AddDeviceScreenLockPolicyTests: XCTestCase {

    // MARK: - pairing (#418)

    func testScreenStaysAwakeAfterTheDeviceIsFoundUntilItConnects() {
        XCTAssertNotEqual(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .deviceFound), false, "the screen must not lock before the connection is made")
        XCTAssertEqual(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .connected), false)
    }

    func testFullAddSequenceKeepsTheScreenAwakeUntilConnected() {
        var keepsScreenAwake = false
        var states: [Bool] = []
        for event in [AddDeviceScreenLockPolicy.Event.scanningStarted, .deviceFound, .connected] {
            keepsScreenAwake = AddDeviceScreenLockPolicy.keepsScreenAwake(after: event) ?? keepsScreenAwake
            states.append(keepsScreenAwake)
        }
        XCTAssertEqual(states, [true, true, false])
    }

    /// A device that is found but never connects lets the screen lock after a while, instead of
    /// keeping it awake until the user leaves the screen.
    func testScreenLocksWhenAFoundDeviceDoesNotConnectInTime() {
        XCTAssertEqual(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .connectionTimedOut), false)
        XCTAssertGreaterThan(AddDeviceScreenLockPolicy.maximumWaitForConnection, 60, "long enough for pairing")
    }

    /// A device that was already added reconnects on its own; only a connection that completes adding
    /// a device lets the screen lock.
    func testReconnectingDeviceLeavesTheScreenLockUnchanged() {
        XCTAssertNil(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .connected, isKeptAwakeForAddingDevice: false))
        XCTAssertEqual(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .connected, isKeptAwakeForAddingDevice: true), false)
    }

    // MARK: - scanning

    func testScanningKeepsTheScreenAwake() {
        XCTAssertEqual(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .scanningStarted), true)
    }

    func testFailedScanningAndLeavingTheScreenLetTheScreenLock() {
        XCTAssertEqual(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .scanningFailed), false)
        XCTAssertEqual(AddDeviceScreenLockPolicy.keepsScreenAwake(after: .screenClosed), false)
    }
}
