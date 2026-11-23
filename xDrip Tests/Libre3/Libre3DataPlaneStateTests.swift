//
//  Libre3DataPlaneStateTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the Libre 3 data-plane state machine: which realtime readings are accepted,
/// how a later patch status re-assesses the latest reading (warmup ending, sensor
/// expiring), and which backfill commands a reconnect sends.
///
/// `lastAcceptedGlucoseLifeCount` is the lower bound of the reconnect backfill, so
/// accepting a warmup or expired reading, or forgetting the last good one, would either
/// store bad values or leave a gap after reconnecting.
final class Libre3DataPlaneStateTests: XCTestCase {

    // MARK: - helpers

    private let emptyFrame = Libre3DataFrame(encrypted: Data(), seq: 1, type: 0)

    private func realtimePacket(_ reading: Libre3RealtimeGlucoseReading) -> Libre3DataPlaneDecodedPacket {
        Libre3DataPlaneDecodedPacket(
            channel: .glucoseData, frame: emptyFrame, kind: .kind3, preferredKind: .kind3,
            plaintext: Data(), payload: .realtimeGlucose(reading)
        )
    }

    private func statusPacket(_ status: Libre3PatchStatus) -> Libre3DataPlaneDecodedPacket {
        Libre3DataPlaneDecodedPacket(
            channel: .patchStatus, frame: emptyFrame, kind: .kind2, preferredKind: .kind2,
            plaintext: Data(), payload: .patchStatus(status)
        )
    }

    private func reading(lifeCount: UInt16, mgDL: UInt16, currentWord: UInt16? = nil) throws -> Libre3RealtimeGlucoseReading {
        var builder = Libre3RealtimePlaintextBuilder()
        builder.lifeCount = lifeCount
        builder.uncappedCurrentMgDL = mgDL
        builder.currentWord = currentWord ?? (mgDL & 0x1fff)
        return try builder.reading()
    }

    private func status(currentLifeCount: Int16, errorData: Int16 = 0) throws -> Libre3PatchStatus {
        var builder = Libre3PatchStatusPlaintextBuilder()
        builder.currentLifeCount = currentLifeCount
        builder.errorData = errorData
        return try builder.status()
    }

    private func sensorState(
        lastLifeCount: UInt16? = nil,
        lastMgDL: UInt16? = nil,
        warmup: Int? = nil,
        wear: Int? = nil
    ) throws -> Libre3SensorState {
        try Libre3SensorState(
            serialNumber: "0RRC989AQ", blePIN: Data([1, 2, 3, 4]),
            lastGlucoseLifeCount: lastLifeCount, lastGlucoseMgDL: lastMgDL,
            warmupDurationMinutes: warmup, wearDurationMinutes: wear
        )
    }

    /// Patch info with a 30-minute warmup (byte 16 = 6) and 14400-minute wear (0x3840),
    /// deliberately different from the defaults so the source of each duration is visible.
    private func patchInfo() throws -> Libre3NFCPatchInfo {
        try Libre3NFCPatchInfo(raw: Libre3ProtocolFixtures.data(hex: "00a50001000200010040381e020401040604305252433938394151c6ca"))
    }

    // MARK: - initialisation

    func testDefaultStateHasNoLifecycleAndNoAttention() {
        let state = Libre3DataPlaneState()

        XCTAssertEqual(state.warmupDurationMinutes, Libre3SensorLifecycle.defaultWarmupDurationMinutes)
        XCTAssertNil(state.wearDurationMinutes)
        XCTAssertNil(state.latestLifecycle)
        XCTAssertNil(state.lifecyclePhase)
        XCTAssertFalse(state.isInWarmup)
        XCTAssertEqual(state.latestSensorAttention, .none)
        XCTAssertFalse(state.shouldNotifyUser)
        XCTAssertNil(state.reconnectBackfillLowerBoundLifeCount)
        XCTAssertEqual(state.reconnectBackfillCommands(), [])
    }

    /// Negative durations (e.g. from corrupted persisted state) are clamped to 0, both on
    /// the state and on the lifecycle derived from a seeded patch status.
    func testNegativeDurationsAreClampedToZero() throws {
        let state = Libre3DataPlaneState(
            warmupDurationMinutes: -5,
            wearDurationMinutes: -10,
            latestPatchStatus: try status(currentLifeCount: 3)
        )

        XCTAssertEqual(state.warmupDurationMinutes, 0)
        XCTAssertEqual(state.wearDurationMinutes, 0)
        XCTAssertEqual(state.latestLifecycle?.warmupDurationMinutes, 0)
        XCTAssertEqual(state.latestLifecycle?.wearDurationMinutes, 0)
        XCTAssertEqual(state.lifecyclePhase, .expired)
    }

    /// Reconnect seeding prefers explicit durations, then the sensor's persisted cycle,
    /// then the default warmup.
    func testSensorStateInitResolvesDurationsInPriorityOrder() throws {
        let persisted = try sensorState(lastLifeCount: 500, lastMgDL: 123, warmup: 30, wear: 14400)

        let explicit = Libre3DataPlaneState(sensorState: persisted, warmupDurationMinutes: 45, wearDurationMinutes: 20160)
        XCTAssertEqual(explicit.warmupDurationMinutes, 45)
        XCTAssertEqual(explicit.wearDurationMinutes, 20160)

        let fromPersisted = Libre3DataPlaneState(sensorState: persisted)
        XCTAssertEqual(fromPersisted.warmupDurationMinutes, 30)
        XCTAssertEqual(fromPersisted.wearDurationMinutes, 14400)
        XCTAssertEqual(fromPersisted.lastAcceptedGlucoseLifeCount, 500)
        XCTAssertEqual(fromPersisted.lastAcceptedGlucoseMgDL, 123)

        let fallback = Libre3DataPlaneState(sensorState: try sensorState())
        XCTAssertEqual(fallback.warmupDurationMinutes, 60)
        XCTAssertNil(fallback.wearDurationMinutes)
        XCTAssertNil(fallback.lastAcceptedGlucoseLifeCount)
    }

    /// With both inputs, the NFC patch info decides the cycle while the persisted state
    /// still provides the last accepted glucose.
    func testSensorStateAndPatchInfoInitTakesCycleFromPatchInfo() throws {
        let info = try patchInfo()
        XCTAssertEqual(info.warmupMinutes, 30)
        XCTAssertEqual(info.wearDurationMinutes, 14400)
        let persisted = try sensorState(lastLifeCount: 700, lastMgDL: 140, warmup: 60, wear: 21600)

        let state = Libre3DataPlaneState(
            sensorState: persisted, patchInfo: info,
            latestPatchStatus: try status(currentLifeCount: 29)
        )

        XCTAssertEqual(state.warmupDurationMinutes, 30)
        XCTAssertEqual(state.wearDurationMinutes, 14400)
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 700)
        XCTAssertEqual(state.lastAcceptedGlucoseMgDL, 140)
        XCTAssertEqual(state.lifecyclePhase, .warmup)
        XCTAssertEqual(state.latestLifecycle?.remainingWarmupMinutes, 1)
    }

    // MARK: - recording packets

    func testPatchStatusUsesStateDurationsForLifecycle() throws {
        var state = Libre3DataPlaneState(warmupDurationMinutes: 30, wearDurationMinutes: 100)
        let patchStatus = try status(currentLifeCount: 100)

        let update = state.record(statusPacket(patchStatus))

        let expectedLifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 100, warmupDurationMinutes: 30, wearDurationMinutes: 100)
        XCTAssertEqual(update, .patchStatus(patchStatus, lifecycle: expectedLifecycle))
        XCTAssertEqual(state.latestPatchStatus, patchStatus)
        XCTAssertEqual(state.latestLifecycle, expectedLifecycle)
        XCTAssertEqual(state.lifecyclePhase, .expired)
        XCTAssertFalse(state.isInWarmup)
    }

    /// Before any patch status arrives there is no lifecycle, so a clean reading is
    /// accepted on its own merits.
    func testCleanReadingWithoutPatchStatusIsAccepted() throws {
        var state = Libre3DataPlaneState()
        let clean = try reading(lifeCount: 2000, mgDL: 110)

        let update = state.record(realtimePacket(clean))

        guard case .realtimeGlucose(let recorded, let assessment) = update else {
            return XCTFail("unexpected update \(update)")
        }
        XCTAssertEqual(recorded, clean)
        XCTAssertTrue(assessment.isUsable)
        XCTAssertEqual(state.latestRealtimeGlucose, clean)
        XCTAssertEqual(state.latestQualityAssessment, assessment)
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 2000)
        XCTAssertEqual(state.lastAcceptedGlucoseMgDL, 110)
    }

    func testReadingDuringWarmupIsNotAccepted() throws {
        var state = Libre3DataPlaneState()
        _ = state.record(statusPacket(try status(currentLifeCount: 10)))

        let update = state.record(realtimePacket(try reading(lifeCount: 10, mgDL: 110)))

        guard case .realtimeGlucose(_, let assessment) = update else {
            return XCTFail("unexpected update \(update)")
        }
        XCTAssertEqual(assessment.issues, [.sensorWarmup(remainingMinutes: 50)])
        XCTAssertTrue(state.isInWarmup)
        XCTAssertNil(state.lastAcceptedGlucoseLifeCount)
        XCTAssertNil(state.lastAcceptedGlucoseMgDL)
    }

    /// When a patch status shows warmup has ended, the latest reading is re-assessed with
    /// the new lifecycle and accepted, without waiting for the next reading.
    func testPatchStatusEndingWarmupReassessesAndAcceptsLatestReading() throws {
        var state = Libre3DataPlaneState()
        _ = state.record(statusPacket(try status(currentLifeCount: 59)))
        _ = state.record(realtimePacket(try reading(lifeCount: 59, mgDL: 95)))
        XCTAssertNil(state.lastAcceptedGlucoseLifeCount)
        XCTAssertFalse(try XCTUnwrap(state.latestQualityAssessment).isUsable)

        _ = state.record(statusPacket(try status(currentLifeCount: 60)))

        XCTAssertTrue(try XCTUnwrap(state.latestQualityAssessment).isUsable)
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 59)
        XCTAssertEqual(state.lastAcceptedGlucoseMgDL, 95)
        XCTAssertEqual(state.lifecyclePhase, .active)
    }

    /// Once the sensor expires the latest reading becomes unusable, but the last accepted
    /// glucose must be kept: it is still the correct backfill lower bound.
    func testExpiryMarksLatestReadingUnusableButKeepsLastAccepted() throws {
        var state = Libre3DataPlaneState(wearDurationMinutes: 21600)
        _ = state.record(statusPacket(try status(currentLifeCount: 21599)))
        _ = state.record(realtimePacket(try reading(lifeCount: 21599, mgDL: 150)))
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 21599)

        _ = state.record(statusPacket(try status(currentLifeCount: 21600)))

        XCTAssertEqual(state.lifecyclePhase, .expired)
        XCTAssertEqual(state.latestQualityAssessment?.issues, [.sensorExpired])
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 21599)
        XCTAssertEqual(state.lastAcceptedGlucoseMgDL, 150)
    }

    /// Unusable readings (no value, DQ error) never move the accepted bookmark; clamped LO
    /// values are accepted with their display value, not their raw value.
    func testOnlyUsableReadingsMoveTheAcceptedBookmark() throws {
        var state = Libre3DataPlaneState()
        _ = state.record(statusPacket(try status(currentLifeCount: 1000)))
        _ = state.record(realtimePacket(try reading(lifeCount: 1000, mgDL: 120)))

        _ = state.record(realtimePacket(try reading(lifeCount: 1001, mgDL: 0)))
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 1000)

        _ = state.record(realtimePacket(try reading(lifeCount: 1002, mgDL: 120, currentWord: 0x8078)))
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 1000)
        XCTAssertEqual(state.latestRealtimeGlucose?.lifeCount, 1002)

        _ = state.record(realtimePacket(try reading(lifeCount: 1003, mgDL: 20)))
        XCTAssertEqual(state.lastAcceptedGlucoseLifeCount, 1003)
        XCTAssertEqual(state.lastAcceptedGlucoseMgDL, 39)
    }

    func testHistoricalPagesAccumulateIntoBackfill() throws {
        var state = Libre3DataPlaneState()
        let first = try Libre3HistoricalReadingPage(plaintext: Libre3ProtocolFixtures.data(hex: "9803" + "6d006b0069006e006a006500"))
        let second = try Libre3HistoricalReadingPage(plaintext: Libre3ProtocolFixtures.data(hex: "b603" + "640063006200610060005f00"))

        for page in [first, second] {
            let packet = Libre3DataPlaneDecodedPacket(
                channel: .historicData, frame: emptyFrame, kind: .kind4, preferredKind: .kind4,
                plaintext: Data(), payload: .historicalReadingPage(page)
            )
            XCTAssertEqual(state.record(packet), .historicalReadingPage(page))
        }

        XCTAssertEqual(state.historicalBackfill.pages, [first, second])
        XCTAssertEqual(state.historicalBackfill.firstLifeCount, 920)
        XCTAssertEqual(state.historicalBackfill.lastLifeCount, 975)
        XCTAssertTrue(state.historicalBackfill.isContiguous)
        XCTAssertNil(state.lastAcceptedGlucoseLifeCount, "historical pages must not move the realtime bookmark")
    }

    /// Clinical records and raw packets pass through without touching backfill or the
    /// accepted bookmark.
    func testClinicalAndRawPacketsPassThroughUnchanged() throws {
        var state = Libre3DataPlaneState()
        let record = try Libre3ClinicalReadingRecord(plaintext: Data(count: 14))
        let clinical = Libre3DataPlaneDecodedPacket(
            channel: .clinicalData, frame: emptyFrame, kind: .kind5, preferredKind: nil,
            plaintext: Data(count: 14), payload: .clinicalReadingRecord(record)
        )
        let raw = Libre3DataPlaneDecodedPacket(
            channel: .eventLog, frame: emptyFrame, kind: .kind6, preferredKind: nil,
            plaintext: Data([1, 2, 3]), payload: .raw(Data([1, 2, 3]))
        )
        let before = state

        XCTAssertEqual(state.record(clinical), .clinicalReadingRecord(record))
        XCTAssertEqual(state.record(raw), .raw(raw))
        XCTAssertEqual(state, before)
    }

    /// `assess` is a pure query: it must not store the reading or move the bookmark.
    func testAssessDoesNotMutateState() throws {
        let state = Libre3DataPlaneState()
        let assessment = state.assess(try reading(lifeCount: 5, mgDL: 100))

        XCTAssertTrue(assessment.isUsable)
        XCTAssertNil(state.latestRealtimeGlucose)
        XCTAssertNil(state.latestQualityAssessment)
        XCTAssertNil(state.lastAcceptedGlucoseLifeCount)
    }

    // MARK: - reconnect backfill

    /// Reconnect requests historical and clinical pages from the last accepted life count,
    /// little-endian, using the requested selector.
    func testReconnectBackfillCommandsStartAtLastAcceptedLifeCount() throws {
        let state = Libre3DataPlaneState(lastAcceptedGlucoseLifeCount: 0x1234, lastAcceptedGlucoseMgDL: 100)

        let commands = state.reconnectBackfillCommands()
        XCTAssertEqual(commands.map(\.plaintext.hex), ["01000134120000", "01010134120000"])
        XCTAssertEqual(commands.map(\.label), ["historic >= 4660", "clinical >= 4660"])

        let historicalOnly = state.reconnectBackfillCommands(selector: 0x02, includeClinical: false)
        XCTAssertEqual(historicalOnly.map(\.plaintext.hex), ["01000234120000"])
    }

    // MARK: - sensor state persistence

    func testUpdatingLastAcceptedGlucosePersistsOnlyWhenSomethingWasAccepted() throws {
        let persisted = try sensorState(lastLifeCount: 100, lastMgDL: 90, warmup: 60, wear: 21600)

        XCTAssertEqual(try persisted.updatingLastAcceptedGlucose(from: Libre3DataPlaneState()), persisted)

        var state = Libre3DataPlaneState(sensorState: persisted)
        _ = state.record(realtimePacket(try reading(lifeCount: 4321, mgDL: 180)))
        let updated = try persisted.updatingLastAcceptedGlucose(from: state)

        XCTAssertEqual(updated.lastGlucoseLifeCount, 4321)
        XCTAssertEqual(updated.lastGlucoseMgDL, 180)
        XCTAssertEqual(updated.serialNumber, persisted.serialNumber)
        XCTAssertEqual(updated.blePIN, persisted.blePIN)
        XCTAssertEqual(updated.warmupDurationMinutes, 60)
        XCTAssertEqual(updated.wearDurationMinutes, 21600)
    }

    // MARK: - lifecycle

    /// Phase boundaries: warmup ends exactly at the warmup duration, expiry starts exactly
    /// at the wear duration, and a negative life count counts as zero elapsed minutes.
    func testLifecyclePhaseBoundaries() {
        let cases: [(life: Int, phase: Libre3SensorLifecyclePhase, remainingWarmup: Int, remainingWear: Int?)] = [
            (-5, .warmup, 60, 1000),
            (0, .warmup, 60, 1000),
            (59, .warmup, 1, 941),
            (60, .active, 0, 940),
            (999, .active, 0, 1),
            (1000, .expired, 0, 0),
            (5000, .expired, 0, 0),
        ]
        for c in cases {
            let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: c.life, warmupDurationMinutes: 60, wearDurationMinutes: 1000)
            XCTAssertEqual(lifecycle.phase, c.phase, "life \(c.life)")
            XCTAssertEqual(lifecycle.isActive, c.phase == .active, "life \(c.life)")
            XCTAssertEqual(lifecycle.isWarmingUp, c.phase == .warmup, "life \(c.life)")
            XCTAssertEqual(lifecycle.isExpired, c.phase == .expired, "life \(c.life)")
            XCTAssertEqual(lifecycle.remainingWarmupMinutes, c.remainingWarmup, "life \(c.life)")
            XCTAssertEqual(lifecycle.remainingWearMinutes, c.remainingWear, "life \(c.life)")
        }

        let unknownWear = Libre3SensorLifecycle(currentLifeCountMinutes: 100_000)
        XCTAssertFalse(unknownWear.isExpired, "without a wear duration a sensor never expires on its own")
        XCTAssertNil(unknownWear.remainingWearMinutes)
        XCTAssertEqual(unknownWear.phase, .active)
    }
}
