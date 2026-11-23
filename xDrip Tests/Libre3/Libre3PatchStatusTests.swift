//
//  Libre3PatchStatusTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the parts of Libre 3 patch status decoding not covered by
/// `Libre3DataPlaneTests`: size validation, signed fields, the priority of `errorData`
/// over the patch state when deriving the user attention, and the default lifecycle.
///
/// The attention drives "replace sensor" / "sensor ended" notifications; letting the
/// patch state override a real error code, or reading a signed field as unsigned, would
/// show the wrong notification or none at all.
final class Libre3PatchStatusTests: XCTestCase {

    func testRejectsEveryPlaintextSizeOtherThan12() {
        for size in [0, 11, 13, 29] {
            XCTAssertThrowsError(try Libre3PatchStatus(plaintext: Data(count: size)), "size \(size)") { error in
                XCTAssertEqual(error as? Libre3PatchStatusError, .wrongPlaintextSize(size))
            }
        }
    }

    /// Life counts, error data, event data, index and patch state are signed on the wire;
    /// event data is offset by 4000 and the event count is index + 1.
    func testDecodesSignedFieldsAndDerivedCounts() throws {
        var builder = Libre3PatchStatusPlaintextBuilder()
        builder.lifeCount = -1
        builder.errorData = -2
        builder.eventDataRaw = -100
        builder.index = 0xff
        builder.patchState = 0x80
        builder.currentLifeCount = Int16.min
        builder.stackDisconnectReason = 0xfe
        builder.appDisconnectReason = 0x7f
        let status = try builder.status()

        XCTAssertEqual(status.lifeCount, -1)
        XCTAssertEqual(status.errorData, -2)
        XCTAssertEqual(status.eventDataRaw, -100)
        XCTAssertEqual(status.eventData, 3900)
        XCTAssertEqual(status.index, -1)
        XCTAssertEqual(status.totalEvents, 0)
        XCTAssertEqual(status.patchState, -128)
        XCTAssertEqual(status.patchStateKind, .raw(-128))
        XCTAssertEqual(status.currentLifeCount, Int16.min)
        XCTAssertEqual(status.stackDisconnectReason, -2)
        XCTAssertEqual(status.appDisconnectReason, 127)
        XCTAssertTrue(status.hasErrorData)
        XCTAssertEqual(status.sensorError, .unknown(-2))
        XCTAssertEqual(status.sensorAttention, .unknown(-2))
        XCTAssertTrue(status.shouldNotifyUser, "an unknown error code must still reach the user")
    }

    /// A non-zero `errorData` decides the attention on its own; the patch state is only a
    /// fallback when no error code is present.
    func testErrorDataTakesPriorityOverPatchState() throws {
        let cases: [(errorData: Int16, patchState: UInt8, attention: Libre3SensorAttention)] = [
            (0, 4, .none),
            (0, 3, .checkSensor),
            (0, 5, .sensorEnded),
            (0, 6, .sensorEnded),
            (0, 7, .replaceSensor),
            (0, 8, .replaceSensor),
            (0, 0, .none),
            (0, 9, .none),
            (5, 7, .sensorEnded),
            (7, 8, .checkSensor),
            (3, 6, .checkSensor),
            (8, 4, .replaceSensor),
            (42, 8, .unknown(42)),
        ]
        for c in cases {
            var builder = Libre3PatchStatusPlaintextBuilder()
            builder.errorData = c.errorData
            builder.patchState = c.patchState
            let status = try builder.status()

            XCTAssertEqual(status.sensorAttention, c.attention, "errorData \(c.errorData), patchState \(c.patchState)")
            XCTAssertEqual(status.shouldNotifyUser, c.attention != .none, "errorData \(c.errorData), patchState \(c.patchState)")
            XCTAssertEqual(status.shouldNotifyReplaceSensor, c.attention == .replaceSensor, "errorData \(c.errorData), patchState \(c.patchState)")
        }
        // Without a patch state the attention comes from the error code alone.
        XCTAssertEqual(Libre3SensorAttention(errorData: 0), .none)
        XCTAssertEqual(Libre3SensorAttention(errorData: 6), .sensorEnded)
    }

    /// Disconnect reasons are diagnostics only: either byte alone sets the flag, and
    /// neither changes the sensor error or attention.
    func testDisconnectReasonsAreIndependentDiagnostics() throws {
        let cases: [(stack: UInt8, app: UInt8, expected: Bool)] = [(0, 0, false), (19, 0, true), (0, 1, true), (0x80, 0x80, true)]
        for c in cases {
            var builder = Libre3PatchStatusPlaintextBuilder()
            builder.stackDisconnectReason = c.stack
            builder.appDisconnectReason = c.app
            let status = try builder.status()

            XCTAssertEqual(status.hasDisconnectReason, c.expected, "stack \(c.stack), app \(c.app)")
            XCTAssertEqual(status.sensorError, .none)
            XCTAssertEqual(status.sensorAttention, .none)
        }
    }

    /// The default lifecycle assumes a 60-minute warmup and no wear limit; a negative life
    /// count (corrupt frame) is treated as the very start of warmup, not as expired.
    func testDefaultLifecycleUsesSixtyMinuteWarmup() throws {
        let cases: [(life: Int16, phase: Libre3SensorLifecyclePhase)] = [
            (Int16.min, .warmup), (-1, .warmup), (0, .warmup), (59, .warmup), (60, .active), (Int16.max, .active),
        ]
        for c in cases {
            var builder = Libre3PatchStatusPlaintextBuilder()
            builder.currentLifeCount = c.life
            let status = try builder.status()

            XCTAssertEqual(status.defaultLifecyclePhase, c.phase, "life \(c.life)")
            XCTAssertEqual(status.isInDefaultWarmup, c.phase == .warmup, "life \(c.life)")
            XCTAssertNil(status.defaultLifecycle.wearDurationMinutes)
        }
    }

    /// The lifecycle uses `currentLifeCount` (bytes 8-9), not the record's own `lifeCount`
    /// (bytes 0-1), which is the life count of the event being reported.
    func testLifecycleIsBasedOnCurrentLifeCountNotEventLifeCount() throws {
        var builder = Libre3PatchStatusPlaintextBuilder()
        builder.lifeCount = 10
        builder.currentLifeCount = 21600
        let status = try builder.status()

        XCTAssertEqual(status.lifecycle(wearDurationMinutes: 21600).phase, .expired)
        XCTAssertEqual(status.lifecycle(warmupDurationMinutes: 30, wearDurationMinutes: 21601).remainingWearMinutes, 1)
    }

    func testDescriptionsUsedInLogs() {
        XCTAssertEqual(
            [Libre3SensorAttention.none, .checkSensor, .sensorEnded, .replaceSensor, .unknown(-3)].map(\.description),
            ["none", "checkSensor", "sensorEnded", "replaceSensor", "unknown(-3)"]
        )
        XCTAssertEqual(
            [Int16(0), 3, 5, 6, 7, 8, 9].map { Libre3SensorError(code: $0).description },
            ["none", "insertionFailure", "expired", "terminated", "transmissionError", "terminated", "unknown(9)"]
        )
        XCTAssertEqual(Libre3PatchState(rawValue: 4).description, "active")
        XCTAssertEqual(Libre3PatchState(rawValue: -1).description, "raw(-1)")
    }

    /// Patch state groups are disjoint: no raw state is both "expired or error" and
    /// "terminated", and only 4 is active.
    func testPatchStateGroupsAreDisjointForEveryByte() {
        for byte in UInt8.min...UInt8.max {
            let state = Libre3PatchState(rawValue: Int8(bitPattern: byte))
            let groups = [state.isActive, state.isExpiredOrError, state.isTerminated].filter { $0 }
            XCTAssertLessThanOrEqual(groups.count, 1, "state \(byte)")
            XCTAssertEqual(state.rawValue, Int8(bitPattern: byte))
            XCTAssertEqual(state.isActive, byte == 4)
        }
    }
}
