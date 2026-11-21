//
//  DataCoverageBackupTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class DataCoverageBackupTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_900_000_000)
    private var urlsToRemove = [URL]()

    override func tearDown() {
        urlsToRemove.forEach { try? FileManager.default.removeItem(at: $0) }
        urlsToRemove = []
        super.tearDown()
    }

    // MARK: - Models

    func testBackupModelsDescribeCategoriesModesAndErrors() throws {
        XCTAssertEqual(BackupMergeMode.allCases.map(\.id), BackupMergeMode.allCases.map(\.rawValue))
        XCTAssertEqual(BackupAccountCategory.allCases.map(\.id), BackupAccountCategory.allCases.map(\.rawValue))
        XCTAssertEqual(Set(BackupAccountCategory.allCases.map(\.title)).count, BackupAccountCategory.allCases.count)
        for category in BackupAccountCategory.allCases {
            XCTAssertTrue(category.availabilityKeys.isSubset(of: category.keys), category.title)
            XCTAssertTrue(category.keys.isSubset(of: BackupAccountCategory.allKeys))
            XCTAssertFalse(BackupService.isPortableSetting(category.keys.first!))
        }
        XCTAssertTrue(BackupAccountCategory.allKeys.contains(UserDefaults.Key.nightscoutUrl.rawValue))
        let errors: [BackupError] = [.invalidFile, .unsupportedVersion(3), .incorrectPassphrase, .missingPassphrase, .finalValueMismatch("x")]
        XCTAssertEqual(Set(errors.compactMap(\.errorDescription)).count, errors.count)
        XCTAssertEqual(errors.map(\.traceDescription), ["invalid backup file", "unsupported backup format version 3", "incorrect password or damaged encrypted backup", "missing backup password", "BG reading final value validation failed"])
        let options = BackupOptions()
        XCTAssertTrue(options.includesSettings && options.includesBgReadings && options.includesTreatments)
        XCTAssertFalse(options.includesAccounts)
        XCTAssertNil(options.passphrase)
    }

    func testPropertyListValueRoundTripsAndRejectsUnsupportedValues() throws {
        let value = try BackupPropertyListValue(["a": 1, "b": [true, false]] as [String: Any])
        let decoded = try XCTUnwrap(value.decoded() as? [String: Any])
        XCTAssertEqual(decoded["a"] as? Int, 1)
        XCTAssertEqual(decoded["b"] as? [Bool], [true, false])
        XCTAssertThrowsError(try BackupPropertyListValue(NSObject()))
    }

    func testPortableSettingsExcludeDevicePrefixedKeys() {
        XCTAssertFalse(BackupService.isPortableSetting(UserDefaults.Key.dexcomG7PairingCode.rawValue + "-XYZ"))
        XCTAssertFalse(BackupService.isPortableSetting(UserDefaults.Key.postProcessingSourceContextIdentifier.rawValue))
        XCTAssertFalse(BackupService.isPortableSetting(UserDefaults.Key.libreLinkUpPassword.rawValue))
        XCTAssertTrue(BackupService.isPortableSetting(UserDefaults.Key.bloodGlucoseUnitIsMgDl.rawValue))
        XCTAssertTrue(BackupService.isPortableSetting(UserDefaults.Key.dexcomG7PairingCode.rawValue))
    }

    // MARK: - Archive creation and inspection

    @MainActor
    func testHistoryRoundTripsThroughAnArchive() async throws {
        let source = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let reading = addReading(source, at: base, value: 120)
        reading.adjustedValue = 125
        reading.smoothedValue = 123
        reading.calculatedValueSlope = 0.0001
        reading.deviceName = "dev"
        reading.isSuppressedByFiveMinuteCadence = true
        addReading(source, at: base.addingTimeInterval(300), value: 130)
        let treatment = TreatmentEntry(id: "nsid-insulin", date: base, value: 1.5, valueSecondary: 2, treatmentType: .Insulin, nightscoutEventType: "Bolus", enteredBy: "me", notes: "n", nsManagedObjectContext: source.mainManagedObjectContext)
        treatment.careLinkSourceIdentifier = nil
        addDeviceStatus(source, at: base, iob: 1.2)
        addProfile(source, at: base.addingTimeInterval(-86_400))
        XCTAssertTrue(source.saveChangesSynchronously())
        let created = try await BackupService(coreDataManager: source).createBackup(options: historyOnly())
        urlsToRemove.append(created.url)
        XCTAssertEqual(created.url.pathExtension, "xdripbackup")
        XCTAssertTrue(created.url.lastPathComponent.hasPrefix(ConstantsHomeView.applicationName + "_"))
        XCTAssertFalse(created.url.lastPathComponent.contains("_encrypted"))
        XCTAssertEqual(created.manifest.bgReadingCount, 2)
        XCTAssertEqual(created.manifest.treatmentCount, 1)
        XCTAssertEqual(created.manifest.deviceStatusCount, 1)
        XCTAssertEqual(created.manifest.profileCount, 1)
        XCTAssertEqual(created.manifest.firstBgReadingDate, base)
        XCTAssertEqual(created.manifest.lastBgReadingDate, base.addingTimeInterval(300))
        XCTAssertFalse(created.manifest.isPasswordProtected)
        XCTAssertFalse(created.manifest.includesSettings)

        let destination = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let service = BackupService(coreDataManager: destination)
        XCTAssertFalse(try service.backupRequiresPassphrase(at: created.url))
        let inspection = try service.inspectBackup(at: created.url)
        let result = try await withPreservedGapFillKeys {
            try await service.restore(inspection: inspection, mode: .fillGaps, restoresSettings: false, restoredAccountCategories: [])
        }
        XCTAssertEqual(result.bgReadingsAdded, 2)
        XCTAssertEqual(result.bgReadingsSkipped, 0)
        XCTAssertEqual(result.firstBgReadingAppliedAt, base)
        XCTAssertEqual(result.treatmentsAdded, 1)
        XCTAssertEqual(result.deviceStatusesAdded, 1)
        XCTAssertEqual(result.profilesAdded, 1)
        XCTAssertEqual(result.settingsRestored, 0)
        XCTAssertEqual(result.accountsRestored, 0)
        XCTAssertTrue(result.accountStatuses.values.allSatisfy { $0 == .unavailable })
        let restored = try XCTUnwrap(try destination.mainManagedObjectContext.fetch(BgReading.fetchRequest()).first { $0.id == reading.id })
        XCTAssertEqual(restored.finalValue, 123)
        XCTAssertEqual(restored.adjustedValue?.doubleValue, 125)
        XCTAssertEqual(restored.calculatedValueSlope, 0.0001)
        XCTAssertEqual(restored.deviceName, "dev")
        XCTAssertTrue(restored.isSuppressedByFiveMinuteCadence)
        let restoredTreatment = try XCTUnwrap(try destination.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).first)
        XCTAssertEqual(restoredTreatment.id, "nsid-insulin")
        XCTAssertEqual(restoredTreatment.valueSecondary, 2)
        XCTAssertEqual(restoredTreatment.notes, "n")
        XCTAssertEqual(restoredTreatment.nightscoutEventType, "Bolus")
        let status = try XCTUnwrap(try destination.mainManagedObjectContext.fetch(NightscoutDeviceStatusEntry.fetchRequest()).first)
        XCTAssertEqual(status.iob?.doubleValue, 1.2)
        let profile = try XCTUnwrap(try destination.mainManagedObjectContext.fetch(NightscoutProfileEntry.fetchRequest()).first)
        XCTAssertEqual(profile.schedules?.count, 2)
        XCTAssertEqual(profile.dia?.doubleValue, 5)

        let again = try await withPreservedGapFillKeys {
            try await service.restore(inspection: inspection, mode: .fillGaps, restoresSettings: false, restoredAccountCategories: [])
        }
        XCTAssertEqual(again.bgReadingsAdded, 0)
        XCTAssertEqual(again.bgReadingsSkipped, 2)
        XCTAssertEqual(again.treatmentsSkipped, 1)
        XCTAssertEqual(again.deviceStatusesSkipped, 1)
        XCTAssertEqual(again.profilesSkipped, 1)
    }

    @MainActor
    func testAccountsRequireAPassphrase() async throws {
        let service = BackupService(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName))
        do {
            _ = try await service.createBackup(options: BackupOptions(includesSettings: false, includesAccounts: true, includesBgReadings: false, includesTreatments: false, passphrase: ""))
            XCTFail("expected missing passphrase")
        } catch let error as BackupError {
            XCTAssertEqual(error.traceDescription, BackupError.missingPassphrase.traceDescription)
        }
    }

    func testInspectionRejectsMalformedArchives() throws {
        let service = BackupService(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName))
        assertBackupError(.invalidFile) { _ = try service.inspectBackup(at: try self.write(Data("not a backup".utf8))) }
        assertBackupError(.invalidFile) { _ = try service.backupRequiresPassphrase(at: try self.write(Data("XDRIPBKP1".utf8))) }
        assertBackupError(.invalidFile) { _ = try service.backupRequiresPassphrase(at: try self.write(Data("XDRIPBKP1".utf8) + Data([2, 0]))) }
        XCTAssertTrue(try service.backupRequiresPassphrase(at: try write(Data("XDRIPBKP1".utf8) + Data([1, 0]))))
        assertBackupError(.missingPassphrase) { _ = try service.inspectBackup(at: try self.write(Data("XDRIPBKP1".utf8) + Data([1, 0]))) }
    }

    func testInspectionValidatesManifestAgainstPayload() throws {
        let service = BackupService(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName))
        let record = backupReading(id: "r1", at: base, value: 100)
        XCTAssertNoThrow(try service.inspectBackup(at: try archive(payload(readings: [record]))))
        assertBackupError(.invalidFile) { _ = try service.inspectBackup(at: try self.archive(self.payload(readings: [record], bgCount: 2))) }
        assertBackupError(.invalidFile) { _ = try service.inspectBackup(at: try self.archive(self.payload(readings: [record], format: "other"))) }
        assertBackupError(.invalidFile) { _ = try service.inspectBackup(at: try self.archive(self.payload(readings: [record], protected: true))) }
        assertBackupError(.unsupportedVersion(2)) { _ = try service.inspectBackup(at: try self.archive(self.payload(readings: [record], version: 2))) }
        let mismatched = backupReading(id: "bad", at: base, value: 100, finalValue: 90)
        assertBackupError(.finalValueMismatch("bad")) { _ = try service.inspectBackup(at: try self.archive(self.payload(readings: [mismatched]))) }
        let invalidTreatment = BackupTreatment(careLinkSourceIdentifier: nil, date: base, enteredBy: nil, id: "", nightscoutEventType: nil, notes: nil, treatmentDeleted: false, treatmentType: 99, uploaded: false, value: 1, valueSecondary: 0)
        assertBackupError(.invalidFile) { _ = try service.inspectBackup(at: try self.archive(self.payload(treatments: [invalidTreatment]))) }
    }

    func testIncomingBackupIsCopiedOnlyWithTheBackupExtension() throws {
        let wrong = try write(Data("x".utf8), extension: "txt")
        assertBackupError(.invalidFile) { _ = try BackupService.copyIncomingBackup(from: wrong) }
        let source = try write(Data("content".utf8))
        let copy = try BackupService.copyIncomingBackup(from: source)
        urlsToRemove.append(copy.deletingLastPathComponent())
        XCTAssertNotEqual(copy, source)
        XCTAssertEqual(copy.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: copy), Data("content".utf8))
        XCTAssertTrue(copy.path.contains("Incoming Backups"))
    }

    // MARK: - Restore modes

    @MainActor
    func testFillGapsSkipsReadingsWithin30SecondsOfExistingOnes() async throws {
        let destination = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        addReading(destination, at: base, value: 100)
        addReading(destination, at: base.addingTimeInterval(600), value: 100)
        XCTAssertTrue(destination.saveChangesSynchronously())
        let records = [backupReading(id: "near", at: base.addingTimeInterval(20), value: 101), backupReading(id: "inside", at: base.addingTimeInterval(300), value: 102), backupReading(id: "after", at: base.addingTimeInterval(7200), value: 103)]
        let fill = try await restore(records, into: destination, mode: .fillGaps)
        XCTAssertEqual(fill.bgReadingsAdded, 2)
        XCTAssertEqual(fill.bgReadingsSkipped, 1)
        XCTAssertEqual(fill.firstBgReadingAppliedAt, base.addingTimeInterval(300))
    }

    @MainActor
    func testKeepCurrentAlsoSkipsReadingsInsideCoveredPeriods() async throws {
        let destination = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        addReading(destination, at: base, value: 100)
        addReading(destination, at: base.addingTimeInterval(600), value: 100)
        addReading(destination, at: base.addingTimeInterval(3600), value: 100)
        XCTAssertTrue(destination.saveChangesSynchronously())
        let records = [backupReading(id: "covered", at: base.addingTimeInterval(300), value: 101), backupReading(id: "gap", at: base.addingTimeInterval(1800), value: 102), backupReading(id: "outside", at: base.addingTimeInterval(7200), value: 103)]
        let keep = try await restore(records, into: destination, mode: .keepCurrent)
        XCTAssertEqual(keep.bgReadingsAdded, 2)
        XCTAssertEqual(keep.bgReadingsSkipped, 1)
        let ids = Set(try destination.mainManagedObjectContext.fetch(BgReading.fetchRequest()).map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["gap", "outside"]))
        XCTAssertFalse(ids.contains("covered"))
    }

    @MainActor
    func testIgnoreModeSkipsEverythingAndReplaceRangeReplacesOverlaps() async throws {
        let destination = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let existing = addReading(destination, at: base.addingTimeInterval(60), value: 100)
        let outside = addReading(destination, at: base.addingTimeInterval(-3600), value: 100)
        _ = TreatmentEntry(date: base.addingTimeInterval(30), value: 5, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: destination.mainManagedObjectContext)
        XCTAssertTrue(destination.saveChangesSynchronously())
        let records = [backupReading(id: "a", at: base, value: 110), backupReading(id: "b", at: base.addingTimeInterval(120), value: 111)]
        let treatments = [backupTreatment(at: base, value: 2), backupTreatment(at: base.addingTimeInterval(60), value: 3)]
        let ignored = try await restore(records, treatments: treatments, into: destination, mode: .ignore)
        XCTAssertEqual(ignored.bgReadingsAdded, 0)
        XCTAssertEqual(ignored.bgReadingsSkipped, 2)
        XCTAssertEqual(ignored.treatmentsSkipped, 2)
        let replaced = try await restore(records, treatments: treatments, into: destination, mode: .replaceRange)
        XCTAssertEqual(replaced.bgReadingsAdded, 2)
        XCTAssertEqual(replaced.treatmentsAdded, 2)
        let ids = Set(try destination.mainManagedObjectContext.fetch(BgReading.fetchRequest()).map(\.id))
        XCTAssertEqual(ids, ["a", "b", outside.id])
        XCTAssertFalse(ids.contains(existing.id))
        XCTAssertEqual(try destination.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).map(\.value).sorted(), [2, 3])
    }

    @MainActor
    func testTreatmentsAreDeduplicatedByIdAndFingerprint() async throws {
        let destination = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        _ = TreatmentEntry(id: "known-carbs", date: base.addingTimeInterval(-7200), value: 10, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: destination.mainManagedObjectContext)
        _ = TreatmentEntry(date: base, value: 4, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, notes: " note ", nsManagedObjectContext: destination.mainManagedObjectContext)
        XCTAssertTrue(destination.saveChangesSynchronously())
        let treatments = [
            backupTreatment(at: base.addingTimeInterval(3600), value: 10, type: .Carbs, id: "known-carbs"),
            backupTreatment(at: base.addingTimeInterval(5), value: 4, type: .Insulin, notes: "note"),
            backupTreatment(at: base.addingTimeInterval(5), value: 5, type: .Insulin),
            backupTreatment(at: base.addingTimeInterval(5), value: 5, type: .Insulin),
            BackupTreatment(careLinkSourceIdentifier: nil, date: base, enteredBy: nil, id: "", nightscoutEventType: nil, notes: nil, treatmentDeleted: false, treatmentType: 99, uploaded: false, value: 1, valueSecondary: 0)
        ]
        let result = try await restore([], treatments: treatments, into: destination, mode: .fillGaps)
        XCTAssertEqual(result.treatmentsAdded, 1)
        XCTAssertEqual(result.treatmentsSkipped, 4)
    }

    @MainActor
    func testRestoredHistoryClearsGapFillMarkers() async throws {
        try await withPreservedGapFillKeys {
            let key = UserDefaults.Key.nightscoutFollowerGapFillSite.rawValue
            UserDefaults.standard.set("https://site", forKey: key)
            _ = try await self.restore([self.backupReading(id: "r", at: self.base, value: 100)], into: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName), mode: .fillGaps, preserveKeys: false)
            XCTAssertNil(UserDefaults.standard.object(forKey: key))
            UserDefaults.standard.set("https://site", forKey: key)
            _ = try await self.restore([self.backupReading(id: "r", at: self.base, value: 100)], into: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName), mode: .ignore, preserveKeys: false)
            XCTAssertEqual(UserDefaults.standard.string(forKey: key), "https://site")
        }
    }

    // MARK: - Helpers

    private func historyOnly() -> BackupOptions {
        BackupOptions(includesSettings: false, includesAccounts: false, includesBgReadings: true, includesTreatments: true)
    }

    @discardableResult
    private func addReading(_ core: CoreDataManager, at date: Date, value: Double) -> BgReading {
        let reading = BgReading(timeStamp: date, sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        reading.calculatedValue = value
        return reading
    }

    private func addDeviceStatus(_ core: CoreDataManager, at date: Date, iob: Double) {
        let entry = NightscoutDeviceStatusEntry(context: core.mainManagedObjectContext)
        entry.id = "status-1"
        entry.createdAt = date
        entry.updatedDate = date
        entry.lastCheckedDate = date
        entry.lastLoopDate = date
        entry.iob = NSNumber(value: iob)
        entry.device = "loop://iPhone"
    }

    private func addProfile(_ core: CoreDataManager, at date: Date) {
        let context = core.mainManagedObjectContext
        let entry = NightscoutProfileEntry(context: context)
        entry.id = "profile-1"
        entry.startDate = date
        entry.createdAt = date
        entry.updatedDate = date
        entry.lastCheckedDate = date
        entry.dia = 5
        for (kind, value) in [(NightscoutProfileScheduleKind.basal, 0.8), (.carbRatio, 10)] {
            let schedule = NightscoutProfileScheduleEntry(context: context)
            schedule.kind = kind.rawValue
            schedule.timeAsSecondsFromMidnight = 0
            schedule.value = value
            schedule.profile = entry
        }
    }

    private func backupReading(id: String, at date: Date, value: Double, finalValue: Double? = nil) -> BackupBgReading {
        BackupBgReading(id: id, timeStamp: date, a: 0, adjustedValue: nil, ageAdjustedRawValue: value, backfilledAt: nil, b: 0, c: 0, calculatedValue: value, calculatedValueSlope: 0, calibrationFlag: false, deviceName: nil, finalValue: finalValue ?? value, hideSlope: false, isSuppressedByFiveMinuteCadence: false, ra: 0, rawData: value, rb: 0, rc: 0, smoothedValue: nil)
    }

    private func backupTreatment(at date: Date, value: Double, type: TreatmentType = .Insulin, id: String = "", notes: String? = nil) -> BackupTreatment {
        BackupTreatment(careLinkSourceIdentifier: nil, date: date, enteredBy: nil, id: id, nightscoutEventType: nil, notes: notes, treatmentDeleted: false, treatmentType: type.rawValue, uploaded: false, value: value, valueSecondary: 0)
    }

    private func payload(readings: [BackupBgReading] = [], treatments: [BackupTreatment] = [], bgCount: Int? = nil, format: String = "xdrip-backup", version: Int = 1, protected: Bool = false) -> BackupPayload {
        let manifest = BackupManifest(format: format, formatVersion: version, createdAt: base, appVersion: "1", appBuild: "1", bgReadingCount: bgCount ?? readings.count, treatmentCount: treatments.count, deviceStatusCount: nil, profileCount: nil, firstBgReadingDate: readings.map(\.timeStamp).min(), lastBgReadingDate: readings.map(\.timeStamp).max(), firstTreatmentDate: treatments.map(\.date).min(), firstDeviceStatusDate: nil, firstProfileDate: nil, includesSettings: false, includesAccounts: false, isPasswordProtected: protected)
        return BackupPayload(manifest: manifest, settings: nil, accounts: nil, alertTypes: [], bgReadings: readings, treatments: treatments, deviceStatuses: nil, profiles: nil)
    }

    private func archive(_ payload: BackupPayload) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let compressed = try (encoder.encode(payload) as NSData).compressed(using: .lzfse) as Data
        return try write(Data("XDRIPBKP1".utf8) + Data([0]) + compressed)
    }

    private func write(_ data: Data, extension pathExtension: String = "xdripbackup") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DataCoverage-\(UUID().uuidString).\(pathExtension)")
        try data.write(to: url)
        urlsToRemove.append(url)
        return url
    }

    private func restore(_ readings: [BackupBgReading], treatments: [BackupTreatment] = [], into core: CoreDataManager, mode: BackupMergeMode, preserveKeys: Bool = true) async throws -> BackupRestoreResult {
        let service = BackupService(coreDataManager: core)
        let inspection = BackupInspection(payload: payload(readings: readings, treatments: treatments))
        if preserveKeys {
            return try await withPreservedGapFillKeys {
                try await service.restore(inspection: inspection, mode: mode, restoresSettings: false, restoredAccountCategories: [])
            }
        }
        return try await service.restore(inspection: inspection, mode: mode, restoresSettings: false, restoredAccountCategories: [])
    }

    private func withPreservedGapFillKeys<T>(_ body: () async throws -> T) async throws -> T {
        let keys = [UserDefaults.Key.nightscoutFollowerGapFillLastAuditEndDate, .nightscoutFollowerGapFillSite, .nightscoutFollowerGapFillCoverage].map(\.rawValue)
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        return try await body()
    }

    private func assertBackupError(_ expected: BackupError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(expected.traceDescription)", file: file, line: line)
        } catch let error as BackupError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
