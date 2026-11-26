//
//  NightscoutCoverageFollowManagerTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

private final class FollowStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, Data))?
    private static var storedRequests: [URLRequest] = []

    static var handler: ((URLRequest) -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock(); storedHandler = nil; storedRequests = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("follow.coverage.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, data) = handler?(request) ?? (200, Data("[]".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FollowDelegateSpy: FollowerDelegate {
    var received: [[FollowerBgReading]] = []
    var onReceive: (() -> Void)?
    func followerInfoReceived(followGlucoseDataArray: inout [FollowerBgReading]) {
        received.append(followGlucoseDataArray)
        onReceive?()
    }
}

private final class FollowKeepAliveSpy: FollowerBackgroundKeepAliveManaging {
    var started: [FollowerBackgroundKeepAliveSource] = []
    var stopped: [FollowerBackgroundKeepAliveSource] = []
    func start(for source: FollowerBackgroundKeepAliveSource, backgroundRefresh: (() -> Void)?) { started.append(source) }
    func stop(for source: FollowerBackgroundKeepAliveSource) { stopped.append(source) }
}

@MainActor final class NightscoutCoverageFollowManagerTests: XCTestCase {
    private let site = "https://ns.follow.coverage.test"
    private let keys: [UserDefaults.Key] = [
        .isMaster, .followerDataSourceType, .nightscoutUrl, .nightscoutPort, .nightscoutEnabled, .nightscoutAPIKey,
        .nightscoutToken, .followerBackgroundKeepAliveType, .timeStampLatestNightscoutSyncRequest, .nightscoutSyncRequired,
        .timeStampOfLastFollowerConnection
    ]
    private var saved: [String: Any] = [:]
    private var coreDataManager: CoreDataManager!
    private var delegate: FollowDelegateSpy!
    private var keepAlive: FollowKeepAliveSpy!

    override func setUp() async throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { saved[key.rawValue] = value }
        }
        URLProtocol.registerClass(FollowStubProtocol.self)
        FollowStubProtocol.reset()
        let defaults = UserDefaults.standard
        defaults.timeStampLatestNightscoutSyncRequest = Date()
        defaults.followerBackgroundKeepAliveType = .heartbeat
        defaults.nightscoutEnabled = false
        defaults.nightscoutAPIKey = "secret"
        defaults.nightscoutToken = "follower-token"
        defaults.nightscoutPort = 0
        defaults.nightscoutUrl = site
        defaults.isMaster = false
        defaults.followerDataSourceType = .nightscout
        defaults.nightscoutEnabled = true
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        delegate = FollowDelegateSpy()
        keepAlive = FollowKeepAliveSpy()
    }

    override func tearDown() async throws {
        UserDefaults.standard.isMaster = saved[UserDefaults.Key.isMaster.rawValue] as? Bool ?? true
        try? await Task.sleep(nanoseconds: 300_000_000)
        for key in keys {
            if let value = saved[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        URLProtocol.unregisterClass(FollowStubProtocol.self)
        FollowStubProtocol.reset()
        delegate = nil
        coreDataManager = nil
    }

    private func makeManager() -> NightscoutFollowManager {
        NightscoutFollowManager(coreDataManager: coreDataManager, followerDelegate: delegate, backgroundKeepAliveManager: keepAlive, startsInitialDownload: false)
    }

    private func downloadAndWait(_ manager: NightscoutFollowManager) async -> [FollowerBgReading]? {
        let before = delegate.received.count
        manager.download()
        let deadline = Date().addingTimeInterval(5)
        while delegate.received.count == before && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return delegate.received.count > before ? delegate.received.last : nil
    }

    private func storeReading(secondsAgo: TimeInterval, value: Double) {
        let context = coreDataManager.mainManagedObjectContext
        let reading = BgReading(timeStamp: Date().addingTimeInterval(-secondsAgo), sensor: nil, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: context)
        reading.calculatedValue = value
        try? context.save()
    }

    func testActiveConfigurationStartsKeepAlive() {
        let manager = makeManager()
        XCTAssertEqual(keepAlive.started, [.nightscout])
        withExtendedLifetime(manager) {}
    }

    func testDownloadSendsAuthenticatedRequestAndDeliversNewestFirst() async throws {
        let now = Date()
        let ms = { (seconds: Double) in Int64(now.addingTimeInterval(-seconds).timeIntervalSince1970 * 1000) }
        FollowStubProtocol.handler = { _ in
            (200, Data("""
            [{"sgv":110,"date":\(ms(600))},{"sgv":130,"date":\(ms(60))},{"sgv":"bad","date":1},42,{"sgv":120,"date":\(ms(300))}]
            """.utf8))
        }
        let manager = makeManager()
        let downloaded = await downloadAndWait(manager)
        let readings = try XCTUnwrap(downloaded)
        XCTAssertEqual(readings.map(\.sgv), [130, 120, 110])
        XCTAssertNotNil(UserDefaults.standard.timeStampOfLastFollowerConnection)

        let request = try XCTUnwrap(FollowStubProtocol.requests.first { $0.url?.path == "/api/v1/entries/sgv.json" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "secret".sha1())
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "follower-token")
        let count = Int(items.first { $0.name == "count" }?.value ?? "") ?? 0
        XCTAssertGreaterThan(count, 1)
        let gte = Double(items.first { $0.name == "find[date][$gte]" }?.value ?? "") ?? 0
        XCTAssertEqual(gte / 1000, now.addingTimeInterval(-Double(ConstantsFollower.maxiumDaysOfReadingsToDownload) * 86_400).timeIntervalSince1970, accuracy: 5)
    }

    func testDownloadStartsFromLatestStoredReading() async throws {
        storeReading(secondsAgo: 3600, value: 100)
        let manager = makeManager()
        _ = await downloadAndWait(manager)
        let request = try XCTUnwrap(FollowStubProtocol.requests.last { $0.url?.path == "/api/v1/entries/sgv.json" })
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let gte = Double(items.first { $0.name == "find[date][$gte]" }?.value ?? "") ?? 0
        XCTAssertEqual(gte / 1000, Date().addingTimeInterval(-3600).timeIntervalSince1970, accuracy: 5)
        let count = Double(items.first { $0.name == "count" }?.value ?? "") ?? 0
        XCTAssertEqual(count, ceil(3600 / (ConstantsNightscout.minimiumTimeBetweenTwoReadingsInMinutesFrequentUploads * 60)) + 1, accuracy: 2)
    }

    func testHTTPErrorAndInvalidPayloadsDeliverEmptyArray() async {
        let manager = makeManager()
        for (status, body) in [(500, "[]"), (200, "{\"sgv\":1}"), (200, "not json")] {
            FollowStubProtocol.handler = { _ in (status, Data(body.utf8)) }
            let readings = await downloadAndWait(manager)
            XCTAssertEqual(readings?.count, 0, "status \(status) body \(body)")
        }
    }

    func testDownloadIsSkippedWhenNotAFollowerOrRecentReadingExists() async {
        let manager = makeManager()
        UserDefaults.standard.nightscoutEnabled = false
        manager.download()
        UserDefaults.standard.nightscoutEnabled = true
        UserDefaults.standard.followerDataSourceType = .dexcomShare
        manager.download()
        UserDefaults.standard.followerDataSourceType = .nightscout
        storeReading(secondsAgo: 5, value: 100)
        manager.download()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testUnsupportedSchemeClearsURLAndDoesNotDownload() async {
        let manager = makeManager()
        UserDefaults.standard.nightscoutUrl = "ftp://ns.follow.coverage.test"
        manager.download()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(UserDefaults.standard.nightscoutUrl)
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testCreateBgReadingUsesSlopeOfStoredReadings() {
        let manager = makeManager()
        let first = manager.createBgReading(followGlucoseData: FollowerBgReading(timeStamp: Date(), sgv: 140))
        XCTAssertEqual(first.calculatedValue, 140)
        XCTAssertEqual(first.rawData, 140)
        XCTAssertTrue(first.hideSlope)
        coreDataManager.mainManagedObjectContext.delete(first)

        storeReading(secondsAgo: 600, value: 100)
        storeReading(secondsAgo: 300, value: 110)
        let next = manager.createBgReading(followGlucoseData: FollowerBgReading(timeStamp: Date(), sgv: 120))
        XCTAssertFalse(next.hideSlope)
        XCTAssertGreaterThan(next.calculatedValueSlope, 0)
    }

    func testSourceChangeStopsKeepAlive() {
        let manager = makeManager()
        UserDefaults.standard.isMaster = true
        XCTAssertEqual(keepAlive.stopped.last, .nightscout)
        withExtendedLifetime(manager) {}
    }
}
