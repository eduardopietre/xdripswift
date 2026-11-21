//
//  AlgorithmCoverageSensorNoiseTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import UserNotifications
import XCTest
@testable import xdrip

final class AlgorithmCoverageSensorNoiseTests: XCTestCase {
    private let now = Date()
    private var core: CoreDataManager!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var savedIsMaster = true

    override func setUp() {
        super.setUp()
        core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        suiteName = "AlgorithmCoverageSensorNoise-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        savedIsMaster = UserDefaults.standard.isMaster
        UserDefaults.standard.isMaster = true
    }

    override func tearDown() {
        UserDefaults.standard.isMaster = savedIsMaster
        defaults.removePersistentDomain(forName: suiteName)
        core = nil
        super.tearDown()
    }

    func testUpdateStoresMeasurementOnSensorAndOneHistorySample() throws {
        let sensor = makeSensor()
        insertZigzag(count: 12, endingAt: now)
        let manager = makeManager()
        let expectation = expectation(forNotification: .sensorNoiseHistoryDidChange, object: sensor.id)
        manager.update(activeSensor: sensor, now: now)
        wait(for: [expectation], timeout: 2)
        let expected = SensorNoiseCalculator().calculate(readings: zigzagReadings(count: 12, endingAt: now))
        XCTAssertEqual(sensor.shortTermNoise?.doubleValue ?? -1, try XCTUnwrap(expected.shortTermNoise), accuracy: 0.000_001)
        XCTAssertNil(sensor.longTermNoise)
        XCTAssertEqual(sensor.shortTermNoiseCoverage, expected.shortTermCoverage, accuracy: 0.000_001)
        XCTAssertEqual(sensor.noiseStateRaw, expected.state.rawValue)
        XCTAssertEqual(sensor.noiseUpdatedAt, now)
        XCTAssertEqual(sensor.noiseLatestReadingAt, now)
        XCTAssertEqual(sensor.noiseAlgorithmVersion, ConstantsSensorNoise.algorithmVersion)
        XCTAssertEqual(try core.mainManagedObjectContext.count(for: SensorNoiseSample.fetchRequest()), 1)
    }

    func testUpdateIsSkippedForFollowersMissingSensorsAndWithinInterval() throws {
        let sensor = makeSensor()
        insertZigzag(count: 12, endingAt: now)
        let manager = makeManager()
        manager.update(activeSensor: nil, now: now)
        UserDefaults.standard.isMaster = false
        manager.update(activeSensor: sensor, now: now)
        XCTAssertNil(sensor.noiseUpdatedAt)
        UserDefaults.standard.isMaster = true
        manager.update(activeSensor: sensor, now: now)
        XCTAssertEqual(sensor.noiseUpdatedAt, now)
        manager.update(activeSensor: sensor, now: now.addingTimeInterval(5 * 60))
        XCTAssertEqual(sensor.noiseUpdatedAt, now)
        sensor.noiseAlgorithmVersion = 0
        manager.update(activeSensor: sensor, now: now.addingTimeInterval(5 * 60))
        XCTAssertEqual(sensor.noiseUpdatedAt, now.addingTimeInterval(5 * 60))
        XCTAssertEqual(try core.mainManagedObjectContext.count(for: SensorNoiseSample.fetchRequest()), 1)
    }

    func testNewHistorySampleRequiresTenMinutesBetweenReadings() throws {
        let sensor = makeSensor()
        insertZigzag(count: 12, endingAt: now)
        let manager = makeManager()
        manager.update(activeSensor: sensor, now: now)
        insertZigzag(count: 1, endingAt: now.addingTimeInterval(5 * 60), startValue: 110)
        manager.update(activeSensor: sensor, now: now.addingTimeInterval(11 * 60))
        XCTAssertEqual(try core.mainManagedObjectContext.count(for: SensorNoiseSample.fetchRequest()), 1)
        insertZigzag(count: 2, endingAt: now.addingTimeInterval(15 * 60), startValue: 100)
        manager.update(activeSensor: sensor, now: now.addingTimeInterval(22 * 60))
        XCTAssertEqual(try core.mainManagedObjectContext.count(for: SensorNoiseSample.fetchRequest()), 2)
        let snapshot = try XCTUnwrap(manager.historySnapshot(sensorID: sensor.id, sessionStartDate: sensor.startDate))
        XCTAssertEqual(snapshot.points.map(\.timeStamp), [now, now.addingTimeInterval(15 * 60)])
        XCTAssertEqual(snapshot.sensorStartDate, sensor.startDate)
        XCTAssertNil(snapshot.sensorEndDate)
        XCTAssertEqual(snapshot.shortTermNoise, sensor.shortTermNoise?.doubleValue)
        XCTAssertEqual(snapshot.persistentCoverage, snapshot.points.last?.persistentCoverage)
    }

    func testUpdateWithoutReadingsStoresCollectingStateOnly() throws {
        let sensor = makeSensor()
        makeManager().update(activeSensor: sensor, now: now)
        XCTAssertEqual(sensor.noiseStateRaw, SensorNoiseState.collecting.rawValue)
        XCTAssertNil(sensor.noiseLatestReadingAt)
        XCTAssertNil(sensor.shortTermNoise)
        XCTAssertEqual(try core.mainManagedObjectContext.count(for: SensorNoiseSample.fetchRequest()), 0)
    }

    func testHistorySnapshotForUnknownSensorIsNil() {
        XCTAssertNil(makeManager().historySnapshot(sensorID: "missing", sessionStartDate: now))
        let sensor = makeSensor()
        let snapshot = makeManager().historySnapshot(sensorID: sensor.id, sessionStartDate: sensor.startDate)
        XCTAssertEqual(snapshot?.points.count, 0)
        XCTAssertEqual(snapshot?.state, .collecting)
        XCTAssertNil(snapshot?.persistentNoise)
        XCTAssertEqual(snapshot?.persistentCoverage, 0)
    }

    func testHistoryPrefersSamplesLinkedToTheCurrentSensor() throws {
        let previous = Sensor(startDate: now.addingTimeInterval(-3 * 3600), nsManagedObjectContext: core.mainManagedObjectContext)
        let current = makeSensor()
        let measurement = SensorNoiseMeasurement(shortTermNoise: 2, longTermNoise: nil, shortTermCoverage: 1, longTermCoverage: 0, state: .low, latestReadingAt: now)
        let other = SensorNoiseMeasurement(shortTermNoise: 9, longTermNoise: nil, shortTermCoverage: 1, longTermCoverage: 0, state: .elevated, latestReadingAt: now)
        _ = SensorNoiseSample(timeStamp: now.addingTimeInterval(-600), measurement: other, sensor: previous, nsManagedObjectContext: core.mainManagedObjectContext)
        _ = SensorNoiseSample(timeStamp: now.addingTimeInterval(-600), measurement: measurement, sensor: current, nsManagedObjectContext: core.mainManagedObjectContext)
        _ = SensorNoiseSample(timeStamp: now.addingTimeInterval(-300), measurement: other, sensor: previous, nsManagedObjectContext: core.mainManagedObjectContext)
        let snapshot = try XCTUnwrap(makeManager().historySnapshot(sensorID: current.id, sessionStartDate: current.startDate))
        XCTAssertEqual(snapshot.points.map(\.shortTermNoise), [2, 9])
        XCTAssertEqual(snapshot.points.map(\.state), [.low, .elevated])
    }

    func testRebuildHistorySharesOneBuildBetweenCallers() throws {
        let sensor = makeSensor()
        insertZigzag(count: 24, endingAt: now)
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = makeManager()
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        XCTAssertTrue(manager.rebuildHistoryIfNeeded(sensorID: sensor.id, sessionStartDate: sensor.startDate) { first.fulfill() })
        XCTAssertTrue(manager.rebuildHistoryIfNeeded(sensorID: sensor.id, sessionStartDate: sensor.startDate) { second.fulfill() })
        wait(for: [first, second], timeout: 10)
        var unknownCalled = false
        XCTAssertFalse(manager.rebuildHistoryIfNeeded(sensorID: "unknown", sessionStartDate: now) { unknownCalled = true })
        XCTAssertTrue(unknownCalled)
    }

    func testCompletedHistoryIsNotRebuilt() {
        let sensor = makeSensor()
        sensor.noiseHistoryIsComplete = true
        var called = false
        XCTAssertFalse(makeManager().rebuildHistoryIfNeeded(sensorID: sensor.id, sessionStartDate: sensor.startDate) { called = true })
        XCTAssertTrue(called)
    }

    // MARK: - Helpers

    private func makeManager() -> SensorNoiseManager {
        SensorNoiseManager(
            coreDataManager: core,
            bgReadingsAccessor: BgReadingsAccessor(coreDataManager: core),
            sensorHealthIssueManager: SensorHealthIssueManager(userDefaults: defaults, notificationCenter: NotificationSpy())
        )
    }

    private func makeSensor() -> Sensor {
        let sensor = Sensor(startDate: now.addingTimeInterval(-2 * 3600), nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        return sensor
    }

    private func zigzagValues(count: Int, startValue: Double) -> [Double] {
        (0..<count).map { index in (index.isMultiple(of: 2) ? startValue : startValue + 10) }
    }

    private func insertZigzag(count: Int, endingAt end: Date, startValue: Double = 100) {
        for (index, value) in zigzagValues(count: count, startValue: startValue).enumerated() {
            let reading = BgReading(timeStamp: end.addingTimeInterval(-Double(count - 1 - index) * 300), sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
        }
    }

    private func zigzagReadings(count: Int, endingAt end: Date) -> [SensorNoiseReading] {
        zigzagValues(count: count, startValue: 100).enumerated().map { index, value in
            SensorNoiseReading(timeStamp: end.addingTimeInterval(-Double(count - 1 - index) * 300), calculatedValue: value, rawData: value, calibrationID: nil)
        }
    }
}

private final class NotificationSpy: SensorHealthNotificationScheduling {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        completionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers _: [String]) {}
    func removePendingNotificationRequests(withIdentifiers _: [String]) {}
}
