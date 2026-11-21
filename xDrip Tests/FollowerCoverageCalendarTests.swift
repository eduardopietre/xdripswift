//
//  FollowerCoverageCalendarTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import EventKit
import XCTest
@testable import xdrip

private final class CalendarDelegateSpy: FollowerDelegate {
    var received: [[FollowerBgReading]] = []
    func followerInfoReceived(followGlucoseDataArray: inout [FollowerBgReading]) {
        received.append(followGlucoseDataArray)
    }
}

private final class CalendarKeepAliveSpy: FollowerBackgroundKeepAliveManaging {
    var started: [FollowerBackgroundKeepAliveSource] = []
    var stopped: [FollowerBackgroundKeepAliveSource] = []
    var refreshes: [() -> Void] = []
    func start(for source: FollowerBackgroundKeepAliveSource, backgroundRefresh: (() -> Void)?) {
        started.append(source)
        if let backgroundRefresh { refreshes.append(backgroundRefresh) }
    }
    func stop(for source: FollowerBackgroundKeepAliveSource) { stopped.append(source) }
}

@MainActor final class FollowerCoverageCalendarTests: XCTestCase {
    private let keys: [UserDefaults.Key] = [.isMaster, .followerDataSourceType, .calendarFollowCalendarId, .calendarFollowStatus, .followerBackgroundKeepAliveType]
    private var saved: [String: Any] = [:]
    private var coreDataManager: CoreDataManager!
    private var delegate: CalendarDelegateSpy!
    private var keepAlive: CalendarKeepAliveSpy!

    override func setUp() async throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { saved[key.rawValue] = value }
        }
        UserDefaults.standard.followerBackgroundKeepAliveType = .heartbeat
        UserDefaults.standard.isMaster = false
        UserDefaults.standard.followerDataSourceType = .calendar
        UserDefaults.standard.calendarFollowCalendarId = "Coverage Calendar"
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        delegate = CalendarDelegateSpy()
        keepAlive = CalendarKeepAliveSpy()
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = saved[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        delegate = nil
        coreDataManager = nil
    }

    private func makeManager() -> CalendarFollowManager {
        CalendarFollowManager(coreDataManager: coreDataManager, followerDelegate: delegate, backgroundKeepAliveManager: keepAlive, startsInitialDownload: false)
    }

    private var calendarAuthorized: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess: return true
        default: return false
        }
    }

    private func reading(_ seconds: TimeInterval, _ value: Double) -> BgReading {
        let reading = BgReading(timeStamp: Date(timeIntervalSince1970: seconds), sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        reading.calculatedValue = value
        return reading
    }

    func testDownloadWithoutCalendarAccessReportsErrorOrMissingCalendar() {
        let manager = makeManager()
        UserDefaults.standard.calendarFollowStatus = CalendarShareStatus.waiting.rawValue
        manager.download()
        let expected: CalendarShareStatus = calendarAuthorized ? .notConfigured : .error
        XCTAssertEqual(UserDefaults.standard.calendarFollowStatus, expected.rawValue)
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testDownloadIsIgnoredOutsideCalendarFollowerMode() {
        let manager = makeManager()
        UserDefaults.standard.calendarFollowStatus = CalendarShareStatus.waiting.rawValue
        UserDefaults.standard.isMaster = true
        manager.download()
        XCTAssertEqual(UserDefaults.standard.calendarFollowStatus, CalendarShareStatus.waiting.rawValue)
        UserDefaults.standard.isMaster = false
        UserDefaults.standard.followerDataSourceType = .nightscout
        UserDefaults.standard.calendarFollowStatus = CalendarShareStatus.waiting.rawValue
        manager.download()
        XCTAssertEqual(UserDefaults.standard.calendarFollowStatus, CalendarShareStatus.waiting.rawValue)
    }

    func testDownloadFromBackgroundThreadRunsOnMain() async {
        let manager = makeManager()
        UserDefaults.standard.calendarFollowStatus = CalendarShareStatus.waiting.rawValue
        let done = expectation(description: "dispatched")
        DispatchQueue.global().async {
            manager.download()
            DispatchQueue.main.async { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNotEqual(UserDefaults.standard.calendarFollowStatus, CalendarShareStatus.waiting.rawValue)
    }

    func testStartRegistersKeepAliveWithRefreshAndClearingCalendarStops() {
        let manager = makeManager()
        XCTAssertEqual(keepAlive.started, [.sharedCalendar])
        XCTAssertEqual(keepAlive.refreshes.count, 1)
        keepAlive.refreshes.first?()
        UserDefaults.standard.calendarFollowCalendarId = nil
        XCTAssertEqual(keepAlive.stopped.last, .sharedCalendar)
        XCTAssertEqual(UserDefaults.standard.calendarFollowStatus, CalendarShareStatus.notConfigured.rawValue)
        withExtendedLifetime(manager) {}
    }

    func testCreateBgReadingComputesSlopeFromStoredReadings() throws {
        let manager = makeManager()
        let lone = manager.createBgReading(followGlucoseData: FollowerBgReading(timeStamp: Date(), sgv: 100))
        XCTAssertTrue(lone.hideSlope)
        XCTAssertEqual(lone.calculatedValue, 100)
        coreDataManager.mainManagedObjectContext.delete(lone)
        let context = coreDataManager.mainManagedObjectContext
        for (offset, value) in [(600.0, 150.0), (300.0, 140.0)] {
            let stored = BgReading(timeStamp: Date().addingTimeInterval(-offset), sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: context)
            stored.calculatedValue = value
        }
        try context.save()
        let next = manager.createBgReading(followGlucoseData: FollowerBgReading(timeStamp: Date(), sgv: 130))
        XCTAssertFalse(next.hideSlope)
        XCTAssertLessThan(next.calculatedValueSlope, 0)
    }

    // MARK: - Calendar Share payload

    func testPayloadRoundTripsThroughNotesAndSortsDeduplicatedHistory() throws {
        let current = reading(1_800_000_600, 130)
        let history = [reading(1_800_000_000, 110), reading(1_800_000_300, 120), reading(1_800_000_600, 999), reading(1_800_000_900, 0)]
        let payload = CalendarSharePayload(reading: current, historyReadings: history, sourceAlias: "Kid")
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.history?.count, 2)
        let notes = try XCTUnwrap(payload.encodedNotes())
        XCTAssertTrue(notes.hasPrefix(ConstantsCalendar.calendarSharePayloadPrefix))

        let decoded = try XCTUnwrap(CalendarSharePayload.decode(from: "Visible title\n" + notes + "\n"))
        XCTAssertEqual(decoded.sourceAlias, "Kid")
        XCTAssertEqual(decoded.followerBgReading.sgv, 130)
        XCTAssertEqual(decoded.followerBgReadings.map(\.sgv), [130, 120, 110])
        XCTAssertEqual(decoded.historicalFollowerBgReadings.map(\.sgv), [120, 110])
        XCTAssertEqual(decoded.followerBgReadings.first?.timeStamp, Date(timeIntervalSince1970: 1_800_000_600))
    }

    func testPayloadDecodingRejectsInvalidNotes() throws {
        XCTAssertNil(CalendarSharePayload.decode(from: nil))
        XCTAssertNil(CalendarSharePayload.decode(from: "no prefix"))
        XCTAssertNil(CalendarSharePayload.decode(from: ConstantsCalendar.calendarSharePayloadPrefix + "%%%"))
        func encoded(_ json: String) -> String { ConstantsCalendar.calendarSharePayloadPrefix + Data(json.utf8).base64EncodedString() }
        XCTAssertNil(CalendarSharePayload.decode(from: encoded(#"{"version":2,"timestampMillis":1,"bgMgDl":100,"sourceAlias":""}"#)))
        XCTAssertNil(CalendarSharePayload.decode(from: encoded(#"{"version":1,"timestampMillis":1,"bgMgDl":0,"sourceAlias":""}"#)))
        XCTAssertNil(CalendarSharePayload.decode(from: encoded(#"{"version":1,"timestampMillis":1,"bgMgDl":100,"sourceAlias":"","history":[{"timestampMillis":0,"bgMgDl":-1}]}"#)))
        let minimal = try XCTUnwrap(CalendarSharePayload.decode(from: encoded(#"{"version":1,"timestampMillis":5000,"bgMgDl":100,"sourceAlias":""}"#)))
        XCTAssertNil(minimal.history)
        XCTAssertEqual(minimal.followerBgReadings.map(\.sgv), [100])
        XCTAssertEqual(minimal.followerBgReading.timeStamp, Date(timeIntervalSince1970: 5))
    }

    func testCalendarShareStatusDescriptionsAreDistinct() {
        let all: [CalendarShareStatus] = [.notConfigured, .active, .waiting, .noData, .stale, .error]
        XCTAssertEqual(Set(all.map(\.description)).count, all.count)
        XCTAssertEqual(CalendarShareStatus(rawValue: "stale"), .stale)
    }
}
