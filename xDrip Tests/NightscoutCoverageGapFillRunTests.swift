//
//  NightscoutCoverageGapFillRunTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

/// Answers every request sent to the fake `coverage.test` Nightscout host.
private final class GapFillStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, Data))?
    private static var storedPaths: [String] = []

    static var handler: ((URLRequest) -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }

    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedPaths
    }

    static func reset() {
        lock.lock(); storedHandler = nil; storedPaths = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gapfill.coverage.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedPaths.append(request.url?.path ?? "")
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, data) = handler?(request) ?? (200, Data("[]".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor final class NightscoutCoverageGapFillRunTests: XCTestCase {
    private let site = "https://gapfill.coverage.test"
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var coreDataManager: CoreDataManager!
    private var merged: [NightscoutFollowerGapFillResult] = []
    private var savedStandard: [String: Any] = [:]
    private let standardKeys: [UserDefaults.Key] = [.nightscoutUrl, .nightscoutPort, .nightscoutAPIKey, .nightscoutToken, .timeStampOfLastFollowerConnection]

    override func setUp() async throws {
        for key in standardKeys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { savedStandard[key.rawValue] = value }
        }
        URLProtocol.registerClass(GapFillStubProtocol.self)
        GapFillStubProtocol.reset()
        UserDefaults.standard.nightscoutAPIKey = nil
        UserDefaults.standard.nightscoutToken = nil
        UserDefaults.standard.nightscoutPort = 0
        UserDefaults.standard.nightscoutUrl = site

        suiteName = "NightscoutCoverageGapFill-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.nightscoutEnabled = true
        defaults.isMaster = false
        defaults.followerDataSourceType = .nightscout
        defaults.nightscoutUrl = site
        defaults.nightscoutPort = 0
        defaults.therapyDataSourceType = .none
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        merged = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        for key in standardKeys {
            if let value = savedStandard[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        URLProtocol.unregisterClass(GapFillStubProtocol.self)
        GapFillStubProtocol.reset()
        coreDataManager = nil
    }

    private func makeService() -> NightscoutFollowerGapFillService {
        NightscoutFollowerGapFillService(coreDataManager: coreDataManager, defaults: defaults) { [weak self] result in
            self?.merged.append(result)
        }
    }

    private func coverage() -> NightscoutFollowerGapFillService.CoverageState? {
        defaults.nightscoutFollowerGapFillCoverage.flatMap { try? JSONDecoder().decode(NightscoutFollowerGapFillService.CoverageState.self, from: $0) }
    }

    private func storeReadings(every interval: TimeInterval, from start: Date, to end: Date) {
        let context = coreDataManager.mainManagedObjectContext
        var timeStamp = start
        while timeStamp <= end {
            let reading = BgReading(timeStamp: timeStamp, sensor: nil, calibration: nil, rawData: 100, deviceName: nil, nsManagedObjectContext: context)
            reading.calculatedValue = 100
            timeStamp = timeStamp.addingTimeInterval(interval)
        }
        try? context.save()
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    func testInactiveFollowerConfigurationsDoNothing() async {
        let auditEnd = Date()
        for configure in [
            { (d: UserDefaults) in d.isMaster = true },
            { (d: UserDefaults) in d.nightscoutEnabled = false },
            { (d: UserDefaults) in d.followerDataSourceType = .dexcomShare },
            { (d: UserDefaults) in d.nightscoutUrl = nil },
            { (d: UserDefaults) in d.nightscoutPort = 70_000 }
        ] {
            let suite = "NightscoutCoverageGapFillInactive-\(UUID().uuidString)"
            let local = UserDefaults(suiteName: suite)!
            defer { local.removePersistentDomain(forName: suite) }
            local.nightscoutEnabled = true
            local.isMaster = false
            local.followerDataSourceType = .nightscout
            local.nightscoutUrl = site
            configure(local)
            let service = NightscoutFollowerGapFillService(coreDataManager: coreDataManager, defaults: local) { _ in XCTFail("unexpected merge") }
            service.run(endingAt: auditEnd)
            await settle()
            XCTAssertNil(local.nightscoutFollowerGapFillCoverage)
        }
        XCTAssertTrue(GapFillStubProtocol.paths.isEmpty)
    }

    func testCompleteLocalHistoryAdvancesGlucoseCheckpointWithoutDownloading() async throws {
        let auditEnd = Date()
        storeReadings(every: 5 * 60, from: auditEnd.addingTimeInterval(-72 * 3600 - 60), to: auditEnd)
        let service = makeService()
        service.run(endingAt: auditEnd)
        await waitUntil { self.coverage()?.bgReadingsEnd != nil }

        let coverage = try XCTUnwrap(coverage())
        XCTAssertEqual(coverage.site, site)
        XCTAssertEqual(coverage.bgReadingsEnd, auditEnd)
        XCTAssertNil(coverage.treatmentsEnd)
        XCTAssertEqual(defaults.nightscoutFollowerGapFillSite, site)
        XCTAssertEqual(defaults.nightscoutFollowerGapFillLastAuditEndDate, auditEnd)
        XCTAssertTrue(GapFillStubProtocol.paths.isEmpty)
        XCTAssertTrue(merged.isEmpty)
        withExtendedLifetime(service) {}
    }

    func testRecentCoverageProducesNoWork() async throws {
        let auditEnd = Date()
        let recent = auditEnd.addingTimeInterval(-60)
        let stored = NightscoutFollowerGapFillService.CoverageState(site: site, bgReadingsEnd: recent)
        defaults.nightscoutFollowerGapFillCoverage = try JSONEncoder().encode(stored)
        let service = makeService()
        service.run(endingAt: auditEnd)
        await settle()
        XCTAssertEqual(coverage(), stored)
        XCTAssertTrue(GapFillStubProtocol.paths.isEmpty)
        withExtendedLifetime(service) {}
    }

    func testRunFromBackgroundThreadIsForwardedToMain() async throws {
        let auditEnd = Date()
        storeReadings(every: 5 * 60, from: auditEnd.addingTimeInterval(-72 * 3600 - 60), to: auditEnd)
        let service = makeService()
        DispatchQueue.global().async { service.run(endingAt: auditEnd) }
        await waitUntil { self.coverage()?.bgReadingsEnd != nil }
        XCTAssertEqual(coverage()?.bgReadingsEnd, auditEnd)
        withExtendedLifetime(service) {}
    }

    func testLegacyCheckpointForOtherSiteIsReplacedWithFreshCoverage() async throws {
        let auditEnd = Date()
        defaults.nightscoutFollowerGapFillSite = "https://old.coverage.test"
        defaults.nightscoutFollowerGapFillLastAuditEndDate = auditEnd.addingTimeInterval(-60)
        storeReadings(every: 5 * 60, from: auditEnd.addingTimeInterval(-72 * 3600 - 60), to: auditEnd)
        let service = makeService()
        service.run(endingAt: auditEnd)
        await waitUntil { self.coverage()?.bgReadingsEnd != nil }
        XCTAssertEqual(coverage()?.site, site)
        XCTAssertEqual(coverage()?.bgReadingsEnd, auditEnd)
        XCTAssertEqual(defaults.nightscoutFollowerGapFillSite, site)
        withExtendedLifetime(service) {}
    }

    func testResultAccountingHelpers() {
        var result = NightscoutFollowerGapFillResult()
        XCTAssertFalse(result.hasChanges)
        result.treatmentsAdded = 2
        result.deviceStatusesAdded = 1
        result.profilesAdded = 1
        XCTAssertEqual(result.totalAdded, 4)
        let late = DateInterval(start: Date(timeIntervalSince1970: 200), duration: 10)
        let early = DateInterval(start: Date(timeIntervalSince1970: 100), duration: 10)
        result.recordChangedWindow(late)
        result.recordChangedWindow(early)
        result.recordChangedWindow(late)
        XCTAssertEqual(result.earliestChangedDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(NightscoutFollowerGapFillService.Resource.allCases.count, 4)
        var coverage = NightscoutFollowerGapFillService.CoverageState(site: site)
        for resource in NightscoutFollowerGapFillService.Resource.allCases {
            XCTAssertNil(coverage.endDate(for: resource))
            coverage.setEndDate(Date(timeIntervalSince1970: 5), for: resource)
            XCTAssertEqual(coverage.endDate(for: resource), Date(timeIntervalSince1970: 5))
        }
    }
}
