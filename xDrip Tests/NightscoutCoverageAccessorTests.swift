//
//  NightscoutCoverageAccessorTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class NightscoutCoverageAccessorTests: XCTestCase {
    private var coreDataManager: CoreDataManager!
    private var statusAccessor: NightscoutDeviceStatusAccessor!
    private var profileAccessor: NightscoutProfileAccessor!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        statusAccessor = NightscoutDeviceStatusAccessor(coreDataManager: coreDataManager)
        profileAccessor = NightscoutProfileAccessor(coreDataManager: coreDataManager)
    }

    override func tearDown() {
        statusAccessor = nil
        profileAccessor = nil
        coreDataManager = nil
        super.tearDown()
    }

    private func status(id: String = "", minutes: Double, iob: Double? = nil, device: String? = nil) -> NightscoutDeviceStatus {
        var status = NightscoutDeviceStatus()
        status.id = id
        status.createdAt = base.addingTimeInterval(minutes * 60)
        status.iob = iob
        status.device = device
        return status
    }

    private func profile(id: String = "", hours: Double, basal: [NightscoutProfile.TimeValue]? = nil) -> NightscoutProfile {
        var profile = NightscoutProfile()
        profile.id = id
        profile.startDate = base.addingTimeInterval(hours * 3600)
        profile.createdAt = profile.startDate
        profile.basal = basal
        return profile
    }

    private func statusCount() -> Int {
        let context = coreDataManager.privateManagedObjectContext
        var count = 0
        context.performAndWait {
            count = (try? context.count(for: NightscoutDeviceStatusEntry.fetchRequest())) ?? -1
        }
        return count
    }

    private func scheduleRowCount() -> Int {
        let context = coreDataManager.privateManagedObjectContext
        var count = 0
        context.performAndWait {
            count = (try? context.count(for: NightscoutProfileScheduleEntry.fetchRequest())) ?? -1
        }
        return count
    }

    // MARK: - Device status

    func testUpsertRejectsStatusesWithoutAnyDate() async {
        let empty = NightscoutDeviceStatus()
        let stored = await statusAccessor.upsert(empty)
        XCTAssertFalse(stored)
        let inserted = await statusAccessor.upsert([empty, empty])
        XCTAssertEqual(inserted, 0)
        XCTAssertNil(statusAccessor.latest())
    }

    func testUpsertAcceptsLastLoopDateOnlyStatusUsingCreatedAtFallbackIdentity() async throws {
        var status = NightscoutDeviceStatus()
        status.lastLoopDate = base
        let stored = await statusAccessor.upsert(status)
        XCTAssertTrue(stored)
        let latest = try XCTUnwrap(statusAccessor.latest())
        XCTAssertTrue(latest.id.hasPrefix("createdAt-"))
        XCTAssertEqual(latest.lastLoopDate, base)
    }

    func testUpsertIsIdempotentAndUpdatesExistingRecord() async throws {
        let inserted = await statusAccessor.upsert([status(id: "a", minutes: 0, iob: 1), status(id: "b", minutes: 5, iob: 2)])
        XCTAssertEqual(inserted, 2)
        let again = await statusAccessor.upsert([status(id: "a", minutes: 0, iob: 1.5), status(id: "b", minutes: 5, iob: 2)])
        XCTAssertEqual(again, 0)
        XCTAssertEqual(statusCount(), 2)
        let first = try XCTUnwrap(statusAccessor.fetch(fromDate: nil, toDate: nil).first)
        XCTAssertEqual(first.id, "a")
        XCTAssertEqual(first.iob, 1.5)
    }

    func testUpsertWithoutIdentifierUsesCreatedAtIdentity() async {
        let first = await statusAccessor.upsert([status(minutes: 10, iob: 1)])
        let second = await statusAccessor.upsert([status(minutes: 10, iob: 3)])
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(statusAccessor.latest()?.iob, 3)
        XCTAssertEqual(statusAccessor.latest()?.id, "createdAt-\(Int(base.addingTimeInterval(600).timeIntervalSince1970 * 1000))")
    }

    func testInsertMissingSkipsKnownIdentifiersAndCreatedAtCollisions() async throws {
        await statusAccessor.upsert(status(id: "a", minutes: 0, iob: 1))
        let result = try await statusAccessor.insertMissing([
            status(id: "a", minutes: 30, iob: 9),
            status(id: "other", minutes: 0, iob: 9),
            status(id: "new", minutes: 5, iob: 2),
            status(id: "new2", minutes: 5, iob: 3),
            NightscoutDeviceStatus()
        ])
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(statusAccessor.fetch(fromDate: nil, toDate: nil).map(\.id), ["a", "new"])
        XCTAssertEqual(statusAccessor.latest()?.iob, 2)
    }

    func testInsertMissingWithNoValidStatusesDoesNothing() async throws {
        let result = try await statusAccessor.insertMissing([NightscoutDeviceStatus()])
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    func testLatestOrdersByCreatedAtThenLastLoopDate() async throws {
        var older = status(id: "older", minutes: 0)
        older.lastLoopDate = base.addingTimeInterval(3600)
        var sameCreatedLaterLoop = status(id: "loop", minutes: 10)
        sameCreatedLaterLoop.lastLoopDate = base.addingTimeInterval(700)
        var sameCreatedEarlierLoop = status(id: "early", minutes: 10)
        sameCreatedEarlierLoop.lastLoopDate = base.addingTimeInterval(500)
        await statusAccessor.upsert([older, sameCreatedEarlierLoop, sameCreatedLaterLoop])
        XCTAssertEqual(statusAccessor.latest()?.id, "loop")
    }

    func testLatestAtOrBeforeRespectsMaximumAge() async {
        await statusAccessor.upsert([status(id: "a", minutes: 0), status(id: "b", minutes: 20), status(id: "c", minutes: 40)])
        let point = base.addingTimeInterval(30 * 60)
        XCTAssertEqual(statusAccessor.latest(atOrBefore: point, maximumAge: 15 * 60)?.id, "b")
        XCTAssertNil(statusAccessor.latest(atOrBefore: point, maximumAge: 5 * 60))
        XCTAssertEqual(statusAccessor.latest(atOrBefore: base.addingTimeInterval(40 * 60), maximumAge: 0)?.id, "c")
        XCTAssertNil(statusAccessor.latest(atOrBefore: base.addingTimeInterval(-1), maximumAge: 3600))
    }

    func testFetchFiltersInclusiveBoundsAndSortsAscending() async {
        await statusAccessor.upsert([status(id: "c", minutes: 40), status(id: "a", minutes: 0), status(id: "b", minutes: 20)])
        XCTAssertEqual(statusAccessor.fetch(fromDate: nil, toDate: nil).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(statusAccessor.fetch(fromDate: base.addingTimeInterval(20 * 60), toDate: nil).map(\.id), ["b", "c"])
        XCTAssertEqual(statusAccessor.fetch(fromDate: nil, toDate: base.addingTimeInterval(20 * 60)).map(\.id), ["a", "b"])
        XCTAssertEqual(statusAccessor.fetch(fromDate: base.addingTimeInterval(1), toDate: base.addingTimeInterval(39 * 60)).map(\.id), ["b"])
    }

    func testSnapshotRoundTripsEveryPersistedField() async throws {
        var full = NightscoutDeviceStatus()
        full.id = "full"
        full.createdAt = base
        full.updatedDate = base.addingTimeInterval(1)
        full.lastCheckedDate = base.addingTimeInterval(2)
        full.lastLoopDate = base.addingTimeInterval(3)
        full.timestamp = base.addingTimeInterval(4)
        full.device = "loop://phone"
        full.appVersion = "3"
        full.activeProfile = "Default"
        full.iob = 1.1
        full.cob = 12
        full.eventualBG = 130
        full.currentTarget = 100
        full.isf = 40
        full.insulinReq = 0.2
        full.bolusVolume = 0.3
        full.rate = 0.9
        full.duration = 30
        full.reason = "reason"
        full.sensitivityRatio = 1.1
        full.tdd = 30
        full.error = "err"
        full.overrideActive = true
        full.overrideName = "Run"
        full.overrideMinValue = 140
        full.overrideMaxValue = 150
        full.overrideMultiplier = 0.7
        full.pumpBatteryPercent = 55
        full.pumpReservoir = 120
        full.pumpIsBolusing = false
        full.pumpIsSuspended = true
        full.pumpStatus = "normal"
        full.pumpStatusTimestamp = base.addingTimeInterval(5)
        full.pumpManufacturer = "Acme"
        full.pumpModel = "Model"
        full.uploaderBatteryPercent = 80
        full.uploaderIsCharging = true
        await statusAccessor.upsert(full)

        let restored = try XCTUnwrap(statusAccessor.latest()).deviceStatus()
        XCTAssertFalse(restored.hasPersistedChanges(comparedTo: full))
        XCTAssertEqual(restored.updatedDate, full.updatedDate)
        XCTAssertEqual(restored.lastCheckedDate, full.lastCheckedDate)
    }

    func testCareLinkSnapshotsDropLegacyNegativeSentinels() async throws {
        var careLink = status(id: "cl", minutes: 0, iob: -1, device: "carelink://pump")
        careLink.rate = -0.5
        careLink.pumpReservoir = -1
        careLink.pumpBatteryPercent = 150
        careLink.cob = -3
        await statusAccessor.upsert(careLink)
        let snapshot = try XCTUnwrap(statusAccessor.latest())
        XCTAssertNil(snapshot.iob)
        XCTAssertNil(snapshot.rate)
        XCTAssertNil(snapshot.pumpReservoir)
        XCTAssertNil(snapshot.pumpBatteryPercent)
        XCTAssertEqual(snapshot.cob, -3)

        var loop = status(id: "loop", minutes: 5, iob: -1, device: "loop://phone")
        loop.pumpBatteryPercent = 150
        await statusAccessor.upsert(loop)
        let loopSnapshot = try XCTUnwrap(statusAccessor.latest())
        XCTAssertEqual(loopSnapshot.iob, -1)
        XCTAssertEqual(loopSnapshot.pumpBatteryPercent, 150)
    }

    func testCareLinkSnapshotKeepsValidValues() async throws {
        var careLink = status(id: "cl", minutes: 0, iob: 0, device: "carelink://pump")
        careLink.pumpBatteryPercent = 100
        careLink.pumpReservoir = 0
        await statusAccessor.upsert(careLink)
        let snapshot = try XCTUnwrap(statusAccessor.latest())
        XCTAssertEqual(snapshot.iob, 0)
        XCTAssertEqual(snapshot.pumpBatteryPercent, 100)
        XCTAssertEqual(snapshot.pumpReservoir, 0)
    }

    func testDeleteOlderThanRemovesStatusHistoryFromSQLiteStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqliteManager = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: directory.appendingPathComponent("status.sqlite"))
        let accessor = NightscoutDeviceStatusAccessor(coreDataManager: sqliteManager)
        await accessor.upsert([status(id: "a", minutes: 0), status(id: "b", minutes: 10), status(id: "c", minutes: 20)])

        XCTAssertEqual(accessor.deleteOlderThan(base.addingTimeInterval(10 * 60)), 1)
        XCTAssertEqual(accessor.fetch(fromDate: nil, toDate: nil).map(\.id), ["b", "c"])
        XCTAssertEqual(accessor.deleteOlderThan(base), 0)
    }

    // MARK: - Profiles

    func testProfileUpsertRequiresIdentifierOrStartDate() async {
        let stored = await profileAccessor.upsert(NightscoutProfile())
        XCTAssertFalse(stored)
        XCTAssertNil(profileAccessor.latest())

        var idOnly = NightscoutProfile()
        idOnly.id = "only-id"
        let storedByID = await profileAccessor.upsert(idOnly)
        XCTAssertTrue(storedByID)
        XCTAssertEqual(profileAccessor.latest()?.id, "only-id")
    }

    func testProfileUpsertStoresSortedSchedulesAndMetadata() async throws {
        var profile = profile(id: "p1", hours: 0, basal: [.init(timeAsSecondsFromMidnight: 3600, value: 0.8), .init(timeAsSecondsFromMidnight: 0, value: 0.6)])
        profile.carbratio = [.init(timeAsSecondsFromMidnight: 0, value: 10)]
        profile.sensitivity = [.init(timeAsSecondsFromMidnight: 0, value: 45)]
        profile.targetLow = [.init(timeAsSecondsFromMidnight: 0, value: 90)]
        profile.targetHigh = [.init(timeAsSecondsFromMidnight: 0, value: 120)]
        profile.timezone = "Europe/Brussels"
        profile.dia = 6
        profile.isMgDl = true
        profile.profileName = "Default"
        profile.enteredBy = "Loop"
        let stored = await profileAccessor.upsert(profile)
        XCTAssertTrue(stored)

        let snapshot = try XCTUnwrap(profileAccessor.latest())
        XCTAssertEqual(snapshot.id, "p1")
        XCTAssertEqual(snapshot.startDate, base)
        XCTAssertEqual(snapshot.basal, [.init(timeAsSecondsFromMidnight: 0, value: 0.6), .init(timeAsSecondsFromMidnight: 3600, value: 0.8)])
        XCTAssertEqual(snapshot.carbRatio.map(\.value), [10])
        XCTAssertEqual(snapshot.sensitivity.map(\.value), [45])
        XCTAssertEqual(snapshot.targetLow.map(\.value), [90])
        XCTAssertEqual(snapshot.targetHigh.map(\.value), [120])
        XCTAssertEqual(snapshot.timezone, "Europe/Brussels")
        XCTAssertEqual(snapshot.dia, 6)
        XCTAssertEqual(snapshot.isMgDl, true)
        XCTAssertEqual(snapshot.profileName, "Default")
        XCTAssertEqual(snapshot.enteredBy, "Loop")
    }

    func testProfileUpsertReplacesSchedulesForSameIdentifier() async throws {
        await profileAccessor.upsert(profile(id: "p1", hours: 0, basal: [.init(timeAsSecondsFromMidnight: 0, value: 1), .init(timeAsSecondsFromMidnight: 60, value: 2)]))
        XCTAssertEqual(scheduleRowCount(), 2)
        await profileAccessor.upsert(profile(id: "p1", hours: 0, basal: [.init(timeAsSecondsFromMidnight: 0, value: 3)]))
        XCTAssertEqual(scheduleRowCount(), 1)
        XCTAssertEqual(profileAccessor.fetch(fromDate: nil, toDate: nil).count, 1)
        XCTAssertEqual(try XCTUnwrap(profileAccessor.latest()).basal.map(\.value), [3])
    }

    func testProfileUpsertWithoutIdentifierMatchesStartDate() async throws {
        await profileAccessor.upsert(profile(hours: 1, basal: [.init(timeAsSecondsFromMidnight: 0, value: 1)]))
        var updated = profile(hours: 1, basal: [.init(timeAsSecondsFromMidnight: 0, value: 2)])
        updated.profileName = "Renamed"
        await profileAccessor.upsert(updated)
        let all = profileAccessor.fetch(fromDate: nil, toDate: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.profileName, "Renamed")
        XCTAssertEqual(all.first?.id, "startDate-\(Int(base.addingTimeInterval(3600).timeIntervalSince1970 * 1000))")
    }

    func testProfileInsertMissingIsMergeOnly() async throws {
        await profileAccessor.upsert(profile(id: "known", hours: 0, basal: [.init(timeAsSecondsFromMidnight: 0, value: 1)]))
        let result = try await profileAccessor.insertMissing([
            profile(id: "known", hours: 5, basal: [.init(timeAsSecondsFromMidnight: 0, value: 9)]),
            profile(id: "sameStart", hours: 0),
            profile(id: "new", hours: 2),
            profile(hours: 3),
            profile(hours: 3)
        ])
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.skipped, 3)
        let all = profileAccessor.fetch(fromDate: nil, toDate: nil)
        XCTAssertEqual(all.map(\.startDate), [base, base.addingTimeInterval(2 * 3600), base.addingTimeInterval(3 * 3600)])
        XCTAssertEqual(all.first?.basal.map(\.value), [1])
    }

    func testProfileInsertMissingWithEmptyInput() async throws {
        let result = try await profileAccessor.insertMissing([])
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    func testProfileFetchBoundsAndLatest() async {
        for hour in [0.0, 2, 4] {
            await profileAccessor.upsert(profile(id: "p\(Int(hour))", hours: hour))
        }
        XCTAssertEqual(profileAccessor.latest()?.id, "p4")
        XCTAssertEqual(profileAccessor.fetch(fromDate: base.addingTimeInterval(3600), toDate: nil).map(\.id), ["p2", "p4"])
        XCTAssertEqual(profileAccessor.fetch(fromDate: nil, toDate: base.addingTimeInterval(2 * 3600)).map(\.id), ["p0", "p2"])
        XCTAssertEqual(profileAccessor.fetch(fromDate: base.addingTimeInterval(2 * 3600), toDate: base.addingTimeInterval(2 * 3600)).map(\.id), ["p2"])
    }

    func testProfileDeleteOlderThanKeepsNewestBaselineAndItsSchedules() async {
        for hour in [0.0, 1, 2, 5] {
            await profileAccessor.upsert(profile(id: "p\(Int(hour))", hours: hour, basal: [.init(timeAsSecondsFromMidnight: 0, value: hour)]))
        }
        XCTAssertEqual(scheduleRowCount(), 4)
        XCTAssertEqual(profileAccessor.deleteOlderThan(base.addingTimeInterval(3 * 3600)), 2)
        let remaining = profileAccessor.fetch(fromDate: nil, toDate: nil)
        XCTAssertEqual(remaining.map(\.id), ["p2", "p5"])
        XCTAssertEqual(remaining.first?.basal.map(\.value), [2])
        XCTAssertEqual(scheduleRowCount(), 2)
        XCTAssertEqual(profileAccessor.deleteOlderThan(base.addingTimeInterval(3 * 3600)), 0)
    }

    func testProfileDeleteOlderThanWithNothingOlder() async {
        await profileAccessor.upsert(profile(id: "p", hours: 10))
        XCTAssertEqual(profileAccessor.deleteOlderThan(base), 0)
        XCTAssertEqual(profileAccessor.fetch(fromDate: nil, toDate: nil).count, 1)
    }

    func testProfileScheduleKindsAreStable() {
        XCTAssertEqual(NightscoutProfileScheduleKind.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
    }
}
