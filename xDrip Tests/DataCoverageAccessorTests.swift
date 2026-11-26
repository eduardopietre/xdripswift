//
//  DataCoverageAccessorTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class DataCoverageAccessorTests: XCTestCase {
    private let now = Date()
    private var core: CoreDataManager!
    private var context: NSManagedObjectContext { core.mainManagedObjectContext }

    override func setUp() {
        super.setUp()
        core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    }

    override func tearDown() {
        core = nil
        super.tearDown()
    }

    // MARK: - BgReadingsAccessor

    func testLatestReadingsAreNewestFirstAndRespectLimitAndFromDate() {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        let readings = [30.0, 20, 10, 0].map { reading(100 + $0, minutesAgo: $0) }
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, fromDate: nil, forSensor: nil, ignoreRawData: false, ignoreCalculatedValue: false).map(\.id), readings.reversed().map(\.id))
        XCTAssertEqual(accessor.getLatestBgReadings(limit: 2, fromDate: nil, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).map(\.id), [readings[3].id, readings[2].id])
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, fromDate: readings[1].timeStamp.addingTimeInterval(1), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).count, 2)
        XCTAssertEqual(accessor.getLatestBgReadings(limit: -1, fromDate: nil, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).count, 4)
    }

    func testLatestReadingsFilterZeroValuesSensorAndSuppression() {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        let sensorA = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let sensorB = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        let noCalculated = reading(0, minutesAgo: 1, sensor: sensorA)
        noCalculated.rawData = 50
        let noRaw = reading(100, minutesAgo: 2, sensor: sensorA)
        noRaw.rawData = 0
        let suppressed = reading(100, minutesAgo: 3, sensor: sensorB)
        suppressed.isSuppressedByFiveMinuteCadence = true
        let normal = reading(100, minutesAgo: 4, sensor: sensorB)
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, fromDate: nil, forSensor: nil, ignoreRawData: false, ignoreCalculatedValue: false).map(\.id), [normal.id])
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, fromDate: nil, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false).map(\.id), [noRaw.id, normal.id])
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, fromDate: nil, forSensor: nil, ignoreRawData: false, ignoreCalculatedValue: true).map(\.id), [noCalculated.id, normal.id])
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, fromDate: nil, forSensor: sensorB, ignoreRawData: true, ignoreCalculatedValue: true, includingSuppressed: true).map(\.id), [suppressed.id, normal.id])
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, fromDate: nil, forSensor: sensorA, ignoreRawData: true, ignoreCalculatedValue: true).map(\.id), [noCalculated.id, noRaw.id])
        XCTAssertEqual(accessor.last(forSensor: nil)?.id, noCalculated.id)
        XCTAssertEqual(accessor.last(forSensor: sensorA)?.id, noCalculated.id)
        XCTAssertNil(BgReadingsAccessor(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)).last(forSensor: nil))
    }

    func testHowOldLimitsReadingsByDays() {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        _ = reading(100, minutesAgo: 3 * 24 * 60)
        _ = reading(100, minutesAgo: 12 * 60)
        _ = reading(100, minutesAgo: 1)
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, howOld: 1, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).count, 2)
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, howOld: 0, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).count, 0)
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, howOld: -1, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).count, 3)
        XCTAssertEqual(accessor.getLatestBgReadings(limit: nil, howOld: nil, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).count, 3)
    }

    func testTwoLatestReadingsAreSeparatedByMinimumInterval() {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        XCTAssertTrue(accessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 5).isEmpty)
        let latest = reading(100, minutesAgo: 0)
        XCTAssertEqual(accessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 5).map(\.id), [latest.id])
        _ = reading(100, minutesAgo: 2)
        XCTAssertEqual(accessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 5).map(\.id), [latest.id])
        let far = reading(100, minutesAgo: 6)
        _ = reading(100, minutesAgo: 9)
        XCTAssertEqual(accessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 5).map(\.id), [latest.id, far.id])
        XCTAssertEqual(accessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 1).count, 2)
    }

    func testSnapshotsCarryValuesCalibrationAndSensor() throws {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let calibration = Calibration(timeStamp: now.addingTimeInterval(-600), sensor: sensor, bg: 100, rawValue: 95, adjustedRawValue: 95, sensorConfidence: 1, rawTimeStamp: now, slope: 1.2, intercept: 3, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 95, slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: context)
        let item = reading(120, minutesAgo: 1, sensor: sensor)
        item.calibration = calibration
        item.adjustedValue = 125
        item.smoothedValue = 124
        item.deviceName = "dev"
        _ = reading(80, minutesAgo: 10)
        let snapshots = accessor.getLatestBgReadingSnapshots(limit: nil, fromDate: nil, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true)
        XCTAssertEqual(snapshots.count, 2)
        let first = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(first.id, item.id)
        XCTAssertEqual(first.finalValue, 124)
        XCTAssertEqual(first.adjustedValue, 125)
        XCTAssertEqual(first.smoothedValue, 124)
        XCTAssertEqual(first.calculatedValue, 120)
        XCTAssertEqual(first.deviceName, "dev")
        XCTAssertEqual(first.sensorID, sensor.id)
        XCTAssertEqual(first.calibrationSnapshot?.slope, 1.2)
        XCTAssertEqual(first.calibrationSnapshot?.id, calibration.id)
        XCTAssertNil(snapshots.last?.calibrationSnapshot)
        XCTAssertEqual(accessor.getLatestBgReadingSnapshots(limit: 1, fromDate: nil, forSensor: sensor, ignoreRawData: true, ignoreCalculatedValue: true).map(\.id), [item.id])
        XCTAssertEqual(accessor.lastSnapshot(forSensor: nil)?.id, item.id)
        XCTAssertEqual(accessor.getLatestBgReadingSnapshots(limit: nil, fromDate: now.addingTimeInterval(-300), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: true).count, 1)
    }

    func testReadingTimestampsUseInclusiveWindowAndSkipEmptyReadings() {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let a = reading(100, minutesAgo: 60, sensor: sensor)
        let b = reading(100, minutesAgo: 30)
        let empty = reading(0, minutesAgo: 20)
        empty.rawData = 0
        _ = reading(100, minutesAgo: 25 * 60)
        XCTAssertEqual(accessor.getReadingTimestamps(fromDate: a.timeStamp.addingTimeInterval(-1), toDate: b.timeStamp.addingTimeInterval(1), forSensor: nil), [a.timeStamp, b.timeStamp])
        XCTAssertEqual(accessor.getReadingTimestamps(fromDate: a.timeStamp.addingTimeInterval(-1), toDate: now, forSensor: sensor), [a.timeStamp])
        XCTAssertEqual(accessor.getReadingTimestampsForLast24h(forSensor: nil, endingAt: now), [a.timeStamp, b.timeStamp])
    }

    func testGetBgReadingsUsesExclusiveBoundsAscending() {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        let readings = [40.0, 30, 20, 10].map { reading(100, minutesAgo: $0) }
        readings[2].isSuppressedByFiveMinuteCadence = true
        XCTAssertEqual(accessor.getBgReadings(from: nil, to: nil, on: context).map(\.id), [readings[0].id, readings[1].id, readings[3].id])
        XCTAssertEqual(accessor.getBgReadings(from: readings[0].timeStamp.addingTimeInterval(1), to: nil, on: context, includingSuppressed: true).map(\.id), [readings[1].id, readings[2].id, readings[3].id])
        XCTAssertEqual(accessor.getBgReadings(from: nil, to: readings[1].timeStamp.addingTimeInterval(-1), on: context).map(\.id), [readings[0].id])
        XCTAssertEqual(accessor.getBgReadings(from: readings[0].timeStamp.addingTimeInterval(1), to: readings[3].timeStamp.addingTimeInterval(-1), on: context, includingSuppressed: true).map(\.id), [readings[1].id, readings[2].id])
    }

    func testTransmitterReadSuccessCountsDistinctTimestamps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: directory.appendingPathComponent("Accessor.sqlite"))
        defer {
            try? store.disconnectPersistentStoresForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let storeContext = store.mainManagedObjectContext
        let accessor = BgReadingsAccessor(coreDataManager: store)
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: storeContext)
        func add(_ value: Double, _ date: Date, _ readingSensor: Sensor?) {
            let item = BgReading(timeStamp: date, sensor: readingSensor, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: storeContext)
            item.calculatedValue = value
        }
        let first = now.addingTimeInterval(-30 * 60)
        let last = now.addingTimeInterval(-5 * 60)
        add(100, first, sensor)
        add(101, first, sensor)
        add(100, last, sensor)
        add(0, now.addingTimeInterval(-60), sensor)
        add(100, now.addingTimeInterval(-120 * 60), nil)
        XCTAssertTrue(store.saveChangesSynchronously())
        let result = accessor.getTransmitterReadSuccess(fromDate: now.addingTimeInterval(-3600), toDate: now, forSensor: sensor)
        XCTAssertEqual(result.earliestTimestamp, first)
        XCTAssertEqual(result.latestTimestamp, last)
        XCTAssertEqual(result.distinctTimestampsCount, 2)
        XCTAssertEqual(accessor.getTransmitterReadSuccess(fromDate: nil, toDate: nil, forSensor: nil).distinctTimestampsCount, 3)
        let none = accessor.getTransmitterReadSuccess(fromDate: now.addingTimeInterval(60), toDate: nil, forSensor: nil)
        XCTAssertNil(none.earliestTimestamp)
        XCTAssertNil(none.latestTimestamp)
        XCTAssertEqual(none.distinctTimestampsCount, 0)
    }

    func testDeletingReadingsByObjectOrObjectID() throws {
        let accessor = BgReadingsAccessor(coreDataManager: core)
        let a = reading(100, minutesAgo: 3)
        let b = reading(100, minutesAgo: 2)
        let c = reading(100, minutesAgo: 1)
        XCTAssertTrue(core.saveChangesSynchronously())
        let objectID = c.objectID
        accessor.delete(bgReading: a, on: context)
        accessor.delete(bgReading: b)
        XCTAssertTrue(accessor.delete(bgReadingObjectID: objectID))
        XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 0)
        XCTAssertFalse(accessor.delete(bgReadingObjectID: objectID))
    }

    // MARK: - TreatmentEntryAccessor

    func testLatestTreatmentsLimitAgeAndOrder() {
        let accessor = TreatmentEntryAccessor(coreDataManager: core)
        let treatments = [120.0, 60, 10].map { treatment(.Insulin, $0, minutesAgo: $0) }
        XCTAssertEqual(accessor.getLatestTreatments(limit: 2).map(\.value), [10, 60])
        XCTAssertEqual(accessor.getLatestTreatments(howOld: 90 * 60).map(\.value), [10, 60])
        XCTAssertEqual(accessor.getLatestTreatments(howOld: nil).count, 3)
        XCTAssertEqual(accessor.getLatestTreatments(limit: nil, howOld: -5).count, 3)
        XCTAssertEqual(accessor.getLatestTreatments(limit: nil, fromDate: treatments[1].date.addingTimeInterval(1)).map(\.value), [10])
        XCTAssertEqual(accessor.latest()?.value, 10)
        XCTAssertNil(TreatmentEntryAccessor(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)).latest())
    }

    func testTreatmentsBetweenDatesUseInclusiveBounds() {
        let accessor = TreatmentEntryAccessor(coreDataManager: core)
        let treatments = [30.0, 20, 10].map { treatment(.Carbs, $0, minutesAgo: $0) }
        XCTAssertEqual(accessor.getTreatments(fromDate: treatments[0].date.addingTimeInterval(-1), toDate: treatments[1].date.addingTimeInterval(1), on: context).map(\.value), [20, 30])
        XCTAssertEqual(accessor.getTreatments(fromDate: treatments[1].date.addingTimeInterval(-1), toDate: nil, on: context).map(\.value), [10, 20])
        XCTAssertEqual(accessor.getTreatments(fromDate: nil, toDate: treatments[1].date.addingTimeInterval(1), on: context).map(\.value), [20, 30])
        XCTAssertEqual(accessor.getTreatments(fromDate: nil, toDate: nil, on: context).count, 3)
    }

    func testSiteChangeDatesExcludeDeletedAndOtherTypes() {
        let accessor = TreatmentEntryAccessor(coreDataManager: core)
        let old = treatment(.SiteChange, 0, minutesAgo: 3 * 24 * 60)
        let recent = treatment(.SiteChange, 0, minutesAgo: 60)
        let deleted = treatment(.SiteChange, 0, minutesAgo: 30)
        deleted.treatmentdeleted = true
        _ = treatment(.SensorStart, 0, minutesAgo: 10)
        _ = treatment(.SiteChange, 0, minutesAgo: -60)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(accessor.siteChangeDates(toDate: now), [old.date, recent.date])
        XCTAssertEqual(accessor.siteChangeDates(fromDate: now.addingTimeInterval(-86_400), toDate: now), [recent.date])
        XCTAssertEqual(accessor.latestSiteChangeDate(atOrBefore: now), recent.date)
        XCTAssertEqual(accessor.latestSiteChangeDate(atOrBefore: now.addingTimeInterval(-2 * 86_400)), old.date)
        XCTAssertNil(accessor.latestSiteChangeDate(atOrBefore: now.addingTimeInterval(-4 * 86_400)))
    }

    func testTreatmentLookupByIdAndObjectID() throws {
        let accessor = TreatmentEntryAccessor(coreDataManager: core)
        let carbs = TreatmentEntry(id: "abc-carbs", date: now, value: 10, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let insulin = TreatmentEntry(id: "abc-insulin", date: now, value: 1, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        _ = treatment(.Carbs, 5, minutesAgo: 1)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertTrue(accessor.existsTreatmentWithId("abc-carbs"))
        XCTAssertFalse(accessor.existsTreatmentWithId("abc"))
        XCTAssertFalse(accessor.existsTreatmentWithId(TreatmentEntry.EmptyId))
        XCTAssertNil(accessor.getTreatmentById(TreatmentEntry.EmptyId))
        XCTAssertTrue(accessor.getTreatmentById("abc-insulin") === insulin)
        XCTAssertEqual(Set(accessor.getTreatments(thatContainId: "abc").map(\.id)), ["abc-carbs", "abc-insulin"])
        XCTAssertTrue(accessor.getTreatments(thatContainId: TreatmentEntry.EmptyId).isEmpty)
        XCTAssertTrue(accessor.getTreatment(objectID: carbs.objectID) === carbs)
        accessor.delete(treatmentEntry: carbs, on: context)
        XCTAssertFalse(accessor.existsTreatmentWithId("abc-carbs"))
        XCTAssertEqual(try context.count(for: TreatmentEntry.fetchRequest()), 2)
    }

    // MARK: - CalibrationsAccessor and SensorsAccessor

    func testFirstAndLastCalibrationAreLimitedToTheSensor() throws {
        let accessor = CalibrationsAccessor(coreDataManager: core)
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let other = Sensor(startDate: now.addingTimeInterval(-2 * 86_400), nsManagedObjectContext: context)
        // Calibrations with a confidence of 0 still count: NoCalibrator creates every calibration
        // with confidence 0, and the first and last calibration must be found for those sensors too.
        let oldest = calibration(sensor: sensor, minutesAgo: 300, sensorConfidence: 0, slopeConfidence: 1)
        _ = calibration(sensor: sensor, minutesAgo: 200)
        _ = calibration(sensor: sensor, minutesAgo: 100)
        let newest = calibration(sensor: sensor, minutesAgo: 50, sensorConfidence: 1, slopeConfidence: 0)
        _ = calibration(sensor: other, minutesAgo: 10)
        XCTAssertTrue(accessor.firstCalibrationForActiveSensor(withActivesensor: sensor) === oldest)
        XCTAssertTrue(accessor.lastCalibrationForActiveSensor(withActivesensor: sensor) === newest)
        XCTAssertNil(accessor.lastCalibrationForActiveSensor(withActivesensor: nil))
        let empty = Sensor(startDate: now, nsManagedObjectContext: context)
        XCTAssertNil(accessor.firstCalibrationForActiveSensor(withActivesensor: empty))
    }

    func testLatestCalibrationsFilterBySensorAndDays() {
        let accessor = CalibrationsAccessor(coreDataManager: core)
        let sensor = Sensor(startDate: now.addingTimeInterval(-10 * 86_400), nsManagedObjectContext: context)
        let other = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let a = calibration(sensor: sensor, minutesAgo: 5 * 24 * 60)
        let b = calibration(sensor: sensor, minutesAgo: 2 * 24 * 60)
        let c = calibration(sensor: sensor, minutesAgo: 60)
        let d = calibration(sensor: other, minutesAgo: 30)
        XCTAssertEqual(accessor.getLatestCalibrations(howManyDays: 4, forSensor: sensor).map(\.id), [c.id, b.id])
        XCTAssertEqual(accessor.getLatestCalibrations(howManyDays: 4, forSensor: nil).map(\.id), [d.id, c.id, b.id])
        XCTAssertEqual(accessor.getLatestCalibrations(howManyDays: 6, forSensor: sensor).map(\.id), [c.id, b.id, a.id])
        XCTAssertTrue(accessor.getLatestCalibrations(howManyDays: 0, forSensor: nil).isEmpty)
    }

    func testCalibrationsBetweenDatesAndDeletion() throws {
        let accessor = CalibrationsAccessor(coreDataManager: core)
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let items = [40.0, 30, 20, 10].map { calibration(sensor: sensor, minutesAgo: $0) }
        XCTAssertEqual(accessor.getCalibrations(from: nil, to: nil, on: context).map(\.id), items.map(\.id))
        XCTAssertEqual(accessor.getCalibrations(from: items[0].timeStamp.addingTimeInterval(1), to: nil, on: context).count, 3)
        XCTAssertEqual(accessor.getCalibrations(from: nil, to: items[2].timeStamp.addingTimeInterval(-1), on: context).map(\.id), [items[0].id, items[1].id])
        XCTAssertEqual(accessor.getCalibrations(from: items[0].timeStamp.addingTimeInterval(1), to: items[3].timeStamp.addingTimeInterval(-1), on: context).map(\.id), [items[1].id, items[2].id])
        XCTAssertTrue(core.saveChangesSynchronously())
        accessor.delete(calibration: items[0], on: context)
        XCTAssertEqual(try context.count(for: Calibration.fetchRequest()), 3)
    }

    func testActiveSensorIsNewestWithoutEndDate() {
        let accessor = SensorsAccessor(coreDataManager: core)
        XCTAssertNil(accessor.fetchActiveSensor())
        let old = Sensor(startDate: now.addingTimeInterval(-3 * 86_400), nsManagedObjectContext: context)
        XCTAssertTrue(accessor.fetchActiveSensor() === old)
        let stopped = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        stopped.endDate = now
        XCTAssertTrue(accessor.fetchActiveSensor() === old)
        let current = Sensor(startDate: now.addingTimeInterval(-60), nsManagedObjectContext: context)
        XCTAssertTrue(accessor.fetchActiveSensor() === current)
    }

    // MARK: - BgAdjustmentsAccessor

    func testBgAdjustmentLookupsAndDisabling() throws {
        let accessor = BgAdjustmentsAccessor(coreDataManager: core)
        let start = now.addingTimeInterval(-7200)
        let first = adjustment(accessor, created: start, from: start, intercept: 5)
        let second = adjustment(accessor, created: start.addingTimeInterval(60), from: start.addingTimeInterval(3600), intercept: 10)
        _ = adjustment(accessor, created: start.addingTimeInterval(120), from: start, intercept: 99, source: "other")
        let disabled = adjustment(accessor, created: start.addingTimeInterval(180), from: start, intercept: 50, enabled: false)
        XCTAssertTrue(accessor.latestActiveBgAdjustment(forSourceContextIdentifier: "src", on: context) === second)
        XCTAssertTrue(accessor.latestApplicableBgAdjustment(forSourceContextIdentifier: "src", readingTimeStamp: start.addingTimeInterval(1800), on: context) === first)
        XCTAssertTrue(accessor.latestApplicableBgAdjustment(forSourceContextIdentifier: "src", readingTimeStamp: now, on: context) === second)
        XCTAssertNil(accessor.latestApplicableBgAdjustment(forSourceContextIdentifier: "src", readingTimeStamp: start.addingTimeInterval(-1), on: context))
        XCTAssertEqual(accessor.getBgAdjustments(forSourceContextIdentifier: "src", on: context).count, 3)
        XCTAssertEqual(accessor.getBgAdjustments(forSourceContextIdentifier: "src", on: context).last?.intercept, 10)
        accessor.disableBgAdjustments(forSourceContextIdentifier: "src", fromApplyFromTimeStamp: start.addingTimeInterval(1800), on: context)
        XCTAssertFalse(second.isEnabled)
        XCTAssertTrue(first.isEnabled)
        XCTAssertFalse(disabled.isEnabled)
        accessor.disable(bgAdjustment: first, on: context)
        XCTAssertNil(accessor.latestActiveBgAdjustment(forSourceContextIdentifier: "src", on: context))
        XCTAssertNotNil(accessor.latestActiveBgAdjustment(forSourceContextIdentifier: "other", on: context))
        XCTAssertTrue(BgAdjustmentsAccessor(coreDataManager: core).getBgAdjustments(forSourceContextIdentifier: "missing", on: context).isEmpty)
    }

    // MARK: - Alerts, snooze parameters and peripherals

    func testDefaultAlertTypeIsCreatedOnceAndReturnedWhenEmpty() throws {
        let accessor = AlertTypesAccessor(coreDataManager: core)
        let all = accessor.getAllAlertTypes()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, Texts_Common.default0)
        XCTAssertTrue(accessor.getDefaultAlertType() === all.first)
        XCTAssertEqual(try context.count(for: AlertType.fetchRequest()), 1)
        _ = AlertType(enabled: true, name: "Loud", overrideMute: true, snooze: false, snoozePeriod: 5, vibrate: true, soundName: nil, alertEntries: nil, nsManagedObjectContext: context)
        XCTAssertEqual(accessor.getAllAlertTypes().count, 2)
    }

    func testAlertEntriesAreCreatedForEveryKindAndResolvedByTimeOfDay() throws {
        let types = AlertTypesAccessor(coreDataManager: core)
        let accessor = AlertEntriesAccessor(coreDataManager: core)
        let all = accessor.getAllEntries(forAlertKind: nil, alertTypesAccessor: types)
        XCTAssertEqual(all.count, AlertKind.allCases.count)
        XCTAssertTrue(all.allSatisfy { $0.start == 0 })
        XCTAssertEqual(accessor.getAllEntriesPerAlertKind(alertTypesAccessor: types).map(\.count), Array(repeating: 1, count: AlertKind.allCases.count))
        let single = accessor.getCurrentAndNextAlertEntry(forAlertKind: .low, forWhen: try localDate(hour: 7), alertTypesAccessor: types)
        XCTAssertEqual(single.currentAlertEntry.start, 0)
        XCTAssertNil(single.nextAlertEntry)
        let evening = AlertEntry(isDisabled: false, value: 80, triggerValue: 0, alertKind: .low, start: 1080, alertType: types.getDefaultAlertType(), nsManagedObjectContext: context)
        let morning = accessor.getCurrentAndNextAlertEntry(forAlertKind: .low, forWhen: try localDate(hour: 7), alertTypesAccessor: types)
        XCTAssertEqual(morning.currentAlertEntry.start, 0)
        XCTAssertTrue(morning.nextAlertEntry === evening)
        let night = accessor.getCurrentAndNextAlertEntry(forAlertKind: .low, forWhen: try localDate(hour: 20), alertTypesAccessor: types)
        XCTAssertTrue(night.currentAlertEntry === evening)
        XCTAssertEqual(night.nextAlertEntry?.start, 0)
    }

    func testSnoozeParametersAreCompletedAndDeduplicated() throws {
        let older = SnoozeParameters(alertKind: .low, snoozePeriodInMinutes: 10, snoozeTimeStamp: now.addingTimeInterval(-600), nsManagedObjectContext: context)
        let newer = SnoozeParameters(alertKind: .low, snoozePeriodInMinutes: 20, snoozeTimeStamp: now, nsManagedObjectContext: context)
        let future = SnoozeParameters(alertKind: .high, snoozePeriodInMinutes: 5, snoozeTimeStamp: nil, nsManagedObjectContext: context)
        future.alertKind = 999
        XCTAssertTrue(core.saveChangesSynchronously())
        let parameters = SnoozeParametersAccessor(coreDataManager: core).getSnoozeParameters()
        XCTAssertEqual(parameters.count, AlertKind.allCases.count)
        XCTAssertEqual(parameters.map { Int($0.alertKind) }, AlertKind.allCases.map(\.rawValue).sorted())
        XCTAssertTrue(parameters[AlertKind.low.rawValue] === newer)
        XCTAssertFalse(parameters.contains { $0 === older || $0 === future })
        XCTAssertEqual(try context.count(for: SnoozeParameters.fetchRequest()), AlertKind.allCases.count + 2)
        XCTAssertEqual(SnoozeParametersAccessor(coreDataManager: core).getSnoozeParameters().map(\.objectID), parameters.map(\.objectID))
    }

    func testSnoozeParameterWithTimestampWinsOverEmptyDuplicate() {
        let empty = SnoozeParameters(alertKind: .high, snoozePeriodInMinutes: 0, snoozeTimeStamp: nil, nsManagedObjectContext: context)
        let snoozed = SnoozeParameters(alertKind: .high, snoozePeriodInMinutes: 15, snoozeTimeStamp: now, nsManagedObjectContext: context)
        let parameters = SnoozeParametersAccessor(coreDataManager: core).getSnoozeParameters()
        XCTAssertTrue(parameters[AlertKind.high.rawValue] === snoozed)
        XCTAssertFalse(parameters.contains { $0 === empty })
    }

    func testBLEPeripheralsAreListed() {
        let accessor = BLEPeripheralAccessor(coreDataManager: core)
        XCTAssertTrue(accessor.getBLEPeripherals().isEmpty)
        let device = DexcomG7(address: "addr", name: "DXCM", alias: nil, nsManagedObjectContext: context)
        XCTAssertEqual(accessor.getBLEPeripherals().map(\.address), [device.blePeripheral.address])
        XCTAssertNil(accessor.activeDexcomBatteryStartDate(for: .g5))
    }

    // MARK: - Helpers

    @discardableResult
    private func reading(_ value: Double, minutesAgo: Double, sensor: Sensor? = nil) -> BgReading {
        let item = BgReading(timeStamp: now.addingTimeInterval(-minutesAgo * 60), sensor: sensor, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: context)
        item.calculatedValue = value
        return item
    }

    private func treatment(_ type: TreatmentType, _ value: Double, minutesAgo: Double) -> TreatmentEntry {
        TreatmentEntry(date: now.addingTimeInterval(-minutesAgo * 60), value: value, treatmentType: type, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
    }

    private func calibration(sensor: Sensor, minutesAgo: Double, sensorConfidence: Double = 0.9, slopeConfidence: Double = 0.5) -> Calibration {
        Calibration(timeStamp: now.addingTimeInterval(-minutesAgo * 60), sensor: sensor, bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: sensorConfidence, rawTimeStamp: now, slope: 1, intercept: 0, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: slopeConfidence, deviceName: nil, nsManagedObjectContext: context)
    }

    private func adjustment(_ accessor: BgAdjustmentsAccessor, created: Date, from: Date, intercept: Double, source: String = "src", enabled: Bool = true) -> BgAdjustment {
        accessor.createBgAdjustment(timeStamp: created, applyFromTimeStamp: from, slope: 1, intercept: intercept, adjustmentShapeType: 1, isEnabled: enabled, isBasicAdjustment: true, enteredBgValue: nil, sourceCalculatedValue: nil, sourceDescription: nil, sourceContextIdentifier: source, on: context)
    }

    private func localDate(hour: Int) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour)))
    }
}

extension DataCoverageAccessorTests {
}
