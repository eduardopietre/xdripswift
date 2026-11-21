//
//  DataCoverageHousekeepingTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class DataCoverageHousekeepingTests: XCTestCase {
    private let now = Date()
    private var directory: URL!
    private var core: CoreDataManager!
    private var context: NSManagedObjectContext { core.mainManagedObjectContext }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        core = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: directory.appendingPathComponent("Housekeeping.sqlite"))
    }

    override func tearDownWithError() throws {
        try? core.disconnectPersistentStoresForTesting()
        core = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Models

    func testSelectionPlanAndModeModels() {
        XCTAssertFalse(CleanDataSelection(includesBgReadings: false, includesTreatments: false, includesDeviceStatus: false).hasSelection)
        XCTAssertTrue(CleanDataSelection(includesBgReadings: false, includesTreatments: false, includesDeviceStatus: true).hasSelection)
        let plan = CleanDataDeletionPlan(selection: CleanDataSelection(includesBgReadings: true, includesTreatments: true, includesDeviceStatus: true), rangeMode: .all, fromDate: nil, throughDate: now, bgReadingCount: 3, treatmentCount: 2, deviceStatusCount: 1, calibrationCount: 4, createdAt: now)
        XCTAssertEqual(plan.totalSelectedRecordCount, 10)
        XCTAssertEqual(CleanDataRangeMode.allCases.map(\.id), [.keepRecent, .custom, .all])
        XCTAssertEqual(Set(CleanDataRangeMode.allCases.map(\.title)).count, 3)
        let errors: [CleanDataError] = [.invalidDateRange, .noDataSelected, .noMatchingData, .storedDataChanged, .unableToDeleteData]
        XCTAssertEqual(Set(errors.compactMap(\.errorDescription)).count, errors.count)
    }

    // MARK: - Inventory and planning

    @MainActor
    func testInventoryCountsEveryHistoricalCategory() async throws {
        let service = DataManagementService(coreDataManager: core)
        let sensor = Sensor(startDate: days(-12), nsManagedObjectContext: context)
        reading(at: days(-10), sensor: sensor)
        reading(at: days(-2))
        treatment(at: days(-8))
        treatment(at: days(-1))
        treatment(at: days(-3))
        deviceStatus(at: days(-4))
        calibration(at: days(-9), sensor: sensor)
        let inventory = try await service.inventory()
        XCTAssertEqual(inventory.bgReadings.count, 2)
        XCTAssertEqual(inventory.bgReadings.firstDate, days(-10))
        XCTAssertEqual(inventory.bgReadings.lastDate, days(-2))
        XCTAssertEqual(inventory.treatments.count, 3)
        XCTAssertEqual(inventory.treatments.firstDate, days(-8))
        XCTAssertEqual(inventory.treatments.lastDate, days(-1))
        XCTAssertEqual(inventory.deviceStatus.count, 1)
        XCTAssertEqual(inventory.deviceStatus.firstDate, days(-4))
        XCTAssertEqual(inventory.calibrations.count, 1)
        XCTAssertEqual(inventory.devices, 0)
        XCTAssertEqual(inventory.sensors, 1)
        XCTAssertGreaterThan(inventory.storeSizeInBytes, 0)
        XCTAssertEqual(service.currentStoreSizeInBytes(), inventory.storeSizeInBytes)
    }

    @MainActor
    func testEmptyInventoryHasNoDates() async throws {
        let inventory = try await DataManagementService(coreDataManager: core).inventory()
        XCTAssertEqual(inventory.bgReadings.count, 0)
        XCTAssertNil(inventory.bgReadings.firstDate)
        XCTAssertNil(inventory.treatments.lastDate)
        XCTAssertNil(inventory.calibrations.firstDate)
    }

    @MainActor
    func testDeletionPlanRejectsInvalidRequests() async throws {
        let service = DataManagementService(coreDataManager: core)
        reading(at: days(-10))
        await assertThrows(CleanDataError.noDataSelected) {
            _ = try await service.deletionPlan(selection: CleanDataSelection(includesBgReadings: false, includesTreatments: false, includesDeviceStatus: false), rangeMode: .all, fromDate: nil, throughDate: self.now)
        }
        await assertThrows(CleanDataError.invalidDateRange) {
            _ = try await service.deletionPlan(selection: self.everything, rangeMode: .custom, fromDate: self.now, throughDate: self.days(-1))
        }
        await assertThrows(CleanDataError.noMatchingData) {
            _ = try await service.deletionPlan(selection: self.everything, rangeMode: .keepRecent, fromDate: nil, throughDate: self.days(-20))
        }
    }

    @MainActor
    func testDeletionPlanCountsOnlyCalibrationsLeftWithoutReadings() async throws {
        let service = DataManagementService(coreDataManager: core)
        let sensor = Sensor(startDate: days(-12), nsManagedObjectContext: context)
        let oldCalibration = calibration(at: days(-9), sensor: sensor)
        reading(at: days(-10), calibration: oldCalibration)
        let usedCalibration = calibration(at: days(-7), sensor: sensor)
        reading(at: days(-2), calibration: usedCalibration)
        calibration(at: days(-9), sensor: sensor)
        reading(at: days(-6))
        treatment(at: days(-8))
        treatment(at: days(-1))
        deviceStatus(at: days(-6))
        let plan = try await service.deletionPlan(selection: CleanDataSelection(includesBgReadings: true, includesTreatments: true, includesDeviceStatus: false), rangeMode: .keepRecent, fromDate: nil, throughDate: days(-5))
        XCTAssertEqual(plan.bgReadingCount, 2)
        XCTAssertEqual(plan.treatmentCount, 1)
        XCTAssertEqual(plan.deviceStatusCount, 0)
        XCTAssertEqual(plan.calibrationCount, 2)
        XCTAssertEqual(plan.totalSelectedRecordCount, 5)
        XCTAssertEqual(plan.rangeMode, .keepRecent)
    }

    @MainActor
    func testCustomRangeCountsReadingsAndCalibrationsInsideRange() async throws {
        let service = DataManagementService(coreDataManager: core)
        let sensor = Sensor(startDate: days(-12), nsManagedObjectContext: context)
        let inside = calibration(at: days(-6.5), sensor: sensor)
        reading(at: days(-6), calibration: inside)
        let spanning = calibration(at: days(-6.4), sensor: sensor)
        reading(at: days(-10), calibration: spanning)
        reading(at: days(-2))
        deviceStatus(at: days(-6))
        deviceStatus(at: days(-1))
        let plan = try await service.deletionPlan(selection: everything, rangeMode: .custom, fromDate: days(-7), throughDate: days(-3))
        XCTAssertEqual(plan.bgReadingCount, 1)
        XCTAssertEqual(plan.calibrationCount, 1)
        XCTAssertEqual(plan.deviceStatusCount, 1)
        XCTAssertEqual(plan.treatmentCount, 0)
    }

    // MARK: - Deletion

    @MainActor
    func testConfirmedDeletionRemovesPlannedRecordsAndMergesIntoMainContext() async throws {
        let service = DataManagementService(coreDataManager: core)
        let sensor = Sensor(startDate: days(-12), nsManagedObjectContext: context)
        calibration(at: days(-9), sensor: sensor)
        let keptCalibration = calibration(at: days(-7), sensor: sensor)
        reading(at: days(-2), calibration: keptCalibration)
        reading(at: days(-10))
        reading(at: days(-6))
        treatment(at: days(-8))
        treatment(at: days(-1))
        deviceStatus(at: days(-6))
        let plan = try await service.deletionPlan(selection: everything, rangeMode: .keepRecent, fromDate: nil, throughDate: days(-5))
        let result = try await service.delete(plan: plan)
        XCTAssertEqual(result.bgReadingCount, 2)
        XCTAssertEqual(result.treatmentCount, 1)
        XCTAssertEqual(result.deviceStatusCount, 1)
        XCTAssertEqual(result.oldestRemainingBgReadingDate, days(-2))
        XCTAssertEqual(result.oldestRemainingTreatmentDate, days(-1))
        XCTAssertGreaterThan(result.storeSizeBeforeInBytes, 0)
        XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 1)
        XCTAssertEqual(try context.count(for: TreatmentEntry.fetchRequest()), 1)
        XCTAssertEqual(try context.count(for: NightscoutDeviceStatusEntry.fetchRequest()), 0)
        XCTAssertEqual(try context.count(for: Sensor.fetchRequest()), 1)
    }

    @MainActor
    func testDeletionFailsWhenStoredDataChangedAfterPlanning() async throws {
        let service = DataManagementService(coreDataManager: core)
        reading(at: days(-10))
        let plan = try await service.deletionPlan(selection: everything, rangeMode: .keepRecent, fromDate: nil, throughDate: days(-5))
        reading(at: days(-9))
        await assertThrows(CleanDataError.storedDataChanged) {
            _ = try await service.delete(plan: plan)
        }
        XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 2)
    }

    @MainActor
    func testNightscoutLoopCleanupKeepsProfileActiveAtCutoff() async throws {
        let service = DataManagementService(coreDataManager: core)
        deviceStatus(at: days(-10))
        deviceStatus(at: days(-5))
        deviceStatus(at: days(-1))
        profile(at: days(-30))
        profile(at: days(-20))
        profile(at: days(-2))
        let result = try await service.deleteNightscoutLoopData(throughDate: days(-4))
        XCTAssertEqual(result.deviceStatusCount, 2)
        XCTAssertEqual(result.profileCount, 1)
        let remaining = try context.fetch(NightscoutProfileEntry.fetchRequest()).map(\.startDate).sorted()
        XCTAssertEqual(remaining, [days(-20), days(-2)])
        XCTAssertEqual(try context.count(for: NightscoutDeviceStatusEntry.fetchRequest()), 1)
    }

    // MARK: - Automatic housekeeping

    @MainActor
    func testHouseKeeperDeletesExpiredHistoryOncePerDay() async throws {
        try await withHousekeepingDefaults {
            let defaults = UserDefaults.standard
            defaults.automaticHousekeepingEnabled = true
            defaults.retentionPeriodInDays = 7
            reading(at: days(-10))
            reading(at: days(-8))
            reading(at: days(-1))
            treatment(at: days(-9))
            deviceStatus(at: days(-12))
            XCTAssertTrue(core.saveChangesSynchronously())
            let houseKeeper = HouseKeeper(coreDataManager: core)
            houseKeeper.doAppStartUpHouseKeeping()
            let attempt = try XCTUnwrap(defaults.lastHousekeepingAttemptDate)
            XCTAssertEqual(defaults.lastHousekeepingAttemptRetentionPeriodInDays, 7)
            for _ in 0..<200 where defaults.object(forKey: UserDefaults.Key.lastHousekeepingCalibrationsDeleted.rawValue) == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertNotNil(defaults.lastHousekeepingDate)
            XCTAssertEqual(defaults.lastHousekeepingRetentionPeriodInDays, 7)
            XCTAssertEqual(defaults.lastHousekeepingBgReadingsDeleted, 2)
            XCTAssertEqual(defaults.lastHousekeepingTreatmentsDeleted, 1)
            XCTAssertEqual(defaults.lastHousekeepingCalibrationsDeleted, 0)
            XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 1)
            XCTAssertEqual(try context.count(for: NightscoutDeviceStatusEntry.fetchRequest()), 0)
            houseKeeper.doAppStartUpHouseKeeping()
            XCTAssertEqual(defaults.lastHousekeepingAttemptDate, attempt)
            defaults.retentionPeriodInDays = 30
            houseKeeper.doAppStartUpHouseKeeping()
            XCTAssertNotEqual(defaults.lastHousekeepingAttemptDate, attempt)
            XCTAssertEqual(defaults.lastHousekeepingAttemptRetentionPeriodInDays, 30)
            for _ in 0..<200 where defaults.lastHousekeepingRetentionPeriodInDays != 30 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(defaults.lastHousekeepingRetentionPeriodInDays, 30)
        }
    }

    @MainActor
    func testDisabledHouseKeeperDoesNothing() async throws {
        try await withHousekeepingDefaults {
            UserDefaults.standard.automaticHousekeepingEnabled = false
            reading(at: days(-400))
            XCTAssertTrue(core.saveChangesSynchronously())
            HouseKeeper(coreDataManager: core).doAppStartUpHouseKeeping()
            XCTAssertNil(UserDefaults.standard.lastHousekeepingAttemptDate)
            XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 1)
        }
    }

    @MainActor
    private func withHousekeepingDefaults(_ body: @MainActor () async throws -> Void) async throws {
        let keys: [UserDefaults.Key] = [.automaticHousekeepingEnabled, .retentionPeriodInDays, .lastHousekeepingDate, .lastHousekeepingAttemptDate,
            .lastHousekeepingAttemptRetentionPeriodInDays, .lastHousekeepingRetentionPeriodInDays, .lastHousekeepingBgReadingsDeleted,
            .lastHousekeepingTreatmentsDeleted, .lastHousekeepingCalibrationsDeleted]
        let saved = keys.map { ($0.rawValue, UserDefaults.standard.object(forKey: $0.rawValue)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0.rawValue) }
        try await body()
    }

    // MARK: - Helpers

    private var everything: CleanDataSelection {
        CleanDataSelection(includesBgReadings: true, includesTreatments: true, includesDeviceStatus: true)
    }

    private func days(_ value: Double) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 + value * 86_400).rounded())
    }

    @discardableResult
    private func reading(at date: Date, sensor: Sensor? = nil, calibration: Calibration? = nil) -> BgReading {
        let item = BgReading(timeStamp: date, sensor: sensor, calibration: calibration, rawData: 100, deviceName: nil, nsManagedObjectContext: context)
        item.calculatedValue = 100
        return item
    }

    private func treatment(at date: Date) {
        _ = TreatmentEntry(date: date, value: 1, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
    }

    @discardableResult
    private func calibration(at date: Date, sensor: Sensor) -> Calibration {
        Calibration(timeStamp: date, sensor: sensor, bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: date, slope: 1, intercept: 0, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: context)
    }

    private func deviceStatus(at date: Date) {
        let entry = NightscoutDeviceStatusEntry(context: context)
        entry.id = UUID().uuidString
        entry.createdAt = date
        entry.updatedDate = date
        entry.lastCheckedDate = date
        entry.lastLoopDate = date
    }

    private func profile(at date: Date) {
        let entry = NightscoutProfileEntry(context: context)
        entry.id = UUID().uuidString
        entry.startDate = date
        entry.createdAt = date
        entry.updatedDate = date
        entry.lastCheckedDate = date
    }

    private func assertThrows(_ expected: CleanDataError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CleanDataError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
