//
//  AppCoverageReadSuccessTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class AppCoverageReadSuccessTests: XCTestCase {
    private var core: CoreDataManager!
    private var now: Date!

    override func setUp() {
        super.setUp()
        core = AppCoverageFactory.coreData()
        // Readings arrive 30 seconds into each five-minute slot.
        now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 300).rounded(.down) * 300 + 45)
    }

    private func manager() -> TransmitterReadSuccessManager {
        TransmitterReadSuccessManager(bgReadingsAccessor: BgReadingsAccessor(coreDataManager: core), nowProvider: { [now] in now! })
    }

    private func sensor(startedHoursAgo hours: Double) -> Sensor {
        Sensor(startDate: now.addingTimeInterval(-hours * 3600), nsManagedObjectContext: core.mainManagedObjectContext)
    }

    private func addReadings(count: Int, every interval: TimeInterval, skipping skipped: Set<Int> = []) {
        for index in 0..<count where !skipped.contains(index) {
            AppCoverageFactory.reading(120, at: now.addingTimeInterval(-15 - Double(index) * interval), in: core)
        }
    }

    func testCompleteFiveMinuteDayIsOneHundredPercent() {
        addReadings(count: 288, every: 300)
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 48))
        XCTAssertEqual(result.nominalGapInSeconds, 300)
        XCTAssertEqual(result.expected24h, 288)
        XCTAssertEqual(result.actual24h, 288)
        XCTAssertEqual(result.success24h, 100)
        XCTAssertEqual(result.hourlyBuckets.count, 24)
        XCTAssertEqual(result.hourlyBuckets.map(\.id), Array(0..<24))
        XCTAssertEqual(result.hourlyBuckets.reduce(0) { $0 + $1.actual }, 288)
        XCTAssertTrue(result.hourlyBuckets.allSatisfy { $0.actual <= $0.expected })
    }

    func testMissedReadingsAreFlooredToOneDecimal() {
        addReadings(count: 288, every: 300, skipping: [10, 11, 200])
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 48))
        XCTAssertEqual(result.actual24h, 285)
        XCTAssertEqual(result.success24h, 98.9)
        XCTAssertLessThan(result.hourlyBuckets.map(\.success).min() ?? 100, 100)
    }

    func testDuplicateReadingsInOneSlotCountOnce() {
        addReadings(count: 288, every: 300, skipping: [5])
        AppCoverageFactory.reading(118, at: now.addingTimeInterval(-15 - 4 * 300 + 10), in: core)
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 48))
        XCTAssertEqual(result.actual24h, 287)
        XCTAssertLessThanOrEqual(result.success24h, 99.9, "Any miss keeps the result below 100%")
    }

    func testOneMinuteCadenceIsDetected() {
        addReadings(count: 120, every: 60)
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 2))
        XCTAssertEqual(result.nominalGapInSeconds, 60)
        XCTAssertEqual(result.actual24h, result.expected24h)
        XCTAssertEqual(result.success24h, 100)
    }

    func testYoungSensorOnlyExpectsReadingsSinceItsFirstReading() {
        addReadings(count: 12, every: 300)
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 1))
        XCTAssertEqual(result.expected24h, 12)
        XCTAssertEqual(result.actual24h, 12)
        XCTAssertEqual(result.success24h, 100)
        XCTAssertEqual(result.hourlyBuckets.filter { $0.expected > 0 }.count, 1)
    }

    func testReadingsBeforeSensorStartAndBeforeCutoffAreIgnored() throws {
        addReadings(count: 48, every: 300)
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 2))
        XCTAssertEqual(result.actual24h, 24)
        let cutoff = now.addingTimeInterval(-3600)
        let clamped = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 2), notBefore: cutoff)
        XCTAssertEqual(clamped.actual24h, 12)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(clamped.earliestTimestampInLast24h), cutoff)
    }

    func testNoReadingsGiveEmptyResultWithFiveMinuteFallback() {
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 10))
        XCTAssertEqual(result.nominalGapInSeconds, 300)
        XCTAssertNil(result.earliestTimestampInLast24h)
        XCTAssertEqual(result.expected24h, 0)
        XCTAssertEqual(result.actual24h, 0)
        XCTAssertEqual(result.success24h, 0)
        XCTAssertTrue(result.hourlyBuckets.allSatisfy { $0.expected == 0 && $0.success == 0 })
    }

    func testSingleReadingExpectsOneSlot() {
        addReadings(count: 1, every: 300)
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 10))
        XCTAssertEqual(result.expected24h, 1)
        XCTAssertEqual(result.success24h, 100)
    }

    func testZeroValuedReadingsAreNotCounted() {
        addReadings(count: 12, every: 300)
        let empty = AppCoverageFactory.reading(0, at: now.addingTimeInterval(-15 - 12 * 300), in: core)
        empty.rawData = 0
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 10))
        XCTAssertEqual(result.actual24h, 12)
    }

    func testLogAccessorIsThrottledToOncePerHour() {
        addReadings(count: 12, every: 300)
        let manager = manager()
        let sensor = sensor(startedHoursAgo: 5)
        XCTAssertNotNil(manager.getReadSuccessForLogs(forSensor: sensor, timeStampOfLastLogCreated: nil))
        XCTAssertNil(manager.getReadSuccessForLogs(forSensor: sensor, timeStampOfLastLogCreated: now.addingTimeInterval(-59 * 60)))
        XCTAssertNotNil(manager.getReadSuccessForLogs(forSensor: sensor, timeStampOfLastLogCreated: now.addingTimeInterval(-60 * 60)))
        XCTAssertNotNil(manager.getReadSuccessForLogs(forSensor: sensor, now: now.addingTimeInterval(3600), timeStampOfLastLogCreated: now))
    }

    func testExplicitNowOverridesProvider() {
        addReadings(count: 24, every: 300)
        let result = manager().getReadSuccess(forSensor: sensor(startedHoursAgo: 48), now: now.addingTimeInterval(-3600))
        XCTAssertEqual(result.actual24h, 12)
        XCTAssertEqual(result.success24h, 100)
    }
}
