//
//  FollowerCoverageDexcomShareFollowTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Serves the Dexcom Share follower endpoints for every regional host.
private final class ShareFollowStubProtocol: URLProtocol {
    struct Recorded {
        let host: String
        let path: String
        let query: [String: String]
        let body: [String: String]
    }

    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, String))?
    private static var storedRequests: [Recorded] = []

    static var handler: ((URLRequest) -> (Int, String))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock(); storedHandler = nil; storedRequests = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.contains("dexcom") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(request))) as? [String: String] ?? [:]
        Self.lock.lock()
        Self.storedRequests.append(Recorded(
            host: request.url?.host ?? "",
            path: URL(fileURLWithPath: request.url?.path ?? "").lastPathComponent,
            query: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a }),
            body: body
        ))
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, text) = handler?(request) ?? (500, "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ShareDelegateSpy: FollowerDelegate {
    var received: [[FollowerBgReading]] = []
    func followerInfoReceived(followGlucoseDataArray: inout [FollowerBgReading]) {
        received.append(followGlucoseDataArray)
    }
}

private final class ShareKeepAliveSpy: FollowerBackgroundKeepAliveManaging {
    var started: [FollowerBackgroundKeepAliveSource] = []
    var stopped: [FollowerBackgroundKeepAliveSource] = []
    func start(for source: FollowerBackgroundKeepAliveSource, backgroundRefresh: (() -> Void)?) { started.append(source) }
    func stop(for source: FollowerBackgroundKeepAliveSource) { stopped.append(source) }
}

@MainActor final class FollowerCoverageDexcomShareFollowTests: XCTestCase {
    private let keys: [UserDefaults.Key] = [
        .isMaster, .followerDataSourceType, .dexcomShareAccountName, .dexcomSharePassword, .dexcomShareManuallyLoggedOut,
        .dexcomShareRegion, .dexcomShareLoginFailedTimestamp, .timeStampOfLastFollowerConnection,
        .timeStampLatestNightscoutSyncRequest, .nightscoutSyncRequired, .followerBackgroundKeepAliveType
    ]
    private var saved: [String: Any] = [:]
    private var coreDataManager: CoreDataManager!
    private var delegate: ShareDelegateSpy!
    private var keepAlive: ShareKeepAliveSpy!
    private let accountID = "11111111-2222-3333-4444-555555555555"
    private let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    override func setUp() async throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { saved[key.rawValue] = value }
        }
        URLProtocol.registerClass(ShareFollowStubProtocol.self)
        ShareFollowStubProtocol.reset()
        let defaults = UserDefaults.standard
        defaults.timeStampLatestNightscoutSyncRequest = Date()
        defaults.followerBackgroundKeepAliveType = .heartbeat
        defaults.dexcomShareManuallyLoggedOut = true
        defaults.isMaster = false
        defaults.followerDataSourceType = .dexcomShare
        defaults.dexcomShareAccountName = "follower"
        defaults.dexcomSharePassword = "secret"
        defaults.dexcomShareManuallyLoggedOut = false
        defaults.dexcomShareRegion = .none
        defaults.dexcomShareLoginFailedTimestamp = nil
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        delegate = ShareDelegateSpy()
        keepAlive = ShareKeepAliveSpy()
    }

    override func tearDown() async throws {
        UserDefaults.standard.dexcomShareManuallyLoggedOut = true
        UserDefaults.standard.isMaster = saved[UserDefaults.Key.isMaster.rawValue] as? Bool ?? true
        // Returns once the requests started by the managers have stopped coming, instead of a fixed sleep.
        await waitUntilStable { ShareFollowStubProtocol.requests.count }
        for key in keys {
            if let value = saved[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        URLProtocol.unregisterClass(ShareFollowStubProtocol.self)
        ShareFollowStubProtocol.reset()
        delegate = nil
        coreDataManager = nil
    }

    private func makeManager() -> DexcomShareFollowManager {
        DexcomShareFollowManager(coreDataManager: coreDataManager, followerDelegate: delegate, backgroundKeepAliveManager: keepAlive, startsInitialDownload: false)
    }

    private func serve(authHosts: Set<String>? = nil, session: String? = nil, egvs: [String] = ["", ""], egvStatus: [Int] = []) {
        let accountID = accountID
        let session = session ?? sessionID
        var egvCall = 0
        ShareFollowStubProtocol.handler = { request in
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""
            if path.hasSuffix("AuthenticatePublisherAccount") {
                if let authHosts, !authHosts.contains(host) { return (500, #"{"Code":"AccountPasswordInvalid"}"#) }
                return (200, "\"\(accountID)\"")
            }
            if path.hasSuffix("LoginPublisherAccountById") { return (200, "\"\(session)\"") }
            if path.hasSuffix("ReadPublisherLatestGlucoseValues") {
                defer { egvCall += 1 }
                let status = egvCall < egvStatus.count ? egvStatus[egvCall] : 200
                return (status, egvs[min(egvCall, egvs.count - 1)])
            }
            return (404, "")
        }
    }

    private func egvJSON(_ readings: [(Int64, Int)]) -> String {
        "[" + readings.map { #"{"DT":"/Date(\#($0.0))/","ST":"/Date(\#($0.0)-0700)/","WT":"Date(\#($0.0))","Value":\#($0.1)}"# }.joined(separator: ",") + "]"
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func storeReading(minutesAgo: Double) {
        let context = coreDataManager.mainManagedObjectContext
        let reading = BgReading(timeStamp: Date().addingTimeInterval(-minutesAgo * 60), sensor: nil, calibration: nil, rawData: 100, deviceName: nil, nsManagedObjectContext: context)
        reading.calculatedValue = 100
        try? context.save()
    }

    // MARK: - Tests

    func testLoginTriesRegionsUntilOneAuthenticatesAndDeliversSortedReadings() async throws {
        let egvs = egvJSON([(1_800_000_000_000, 110), (1_800_000_600_000, 130), (1_800_000_300_000, 120)])
        serve(authHosts: ["shareous1.dexcom.com"], egvs: [egvs])
        let manager = makeManager()
        XCTAssertEqual(keepAlive.started, [.dexcomShare])
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }

        let readings = try XCTUnwrap(delegate.received.first)
        XCTAssertEqual(readings.map(\.sgv), [130, 120, 110])
        XCTAssertEqual(readings.first?.timeStamp, Date(timeIntervalSince1970: 1_800_000_600))
        XCTAssertEqual(UserDefaults.standard.dexcomShareRegion, .global)
        XCTAssertNil(UserDefaults.standard.dexcomShareLoginFailedTimestamp)

        let requests = ShareFollowStubProtocol.requests
        XCTAssertEqual(requests.map(\.host), ["share2.dexcom.com", "shareous1.dexcom.com", "shareous1.dexcom.com", "shareous1.dexcom.com"])
        XCTAssertEqual(requests.map(\.path), ["AuthenticatePublisherAccount", "AuthenticatePublisherAccount", "LoginPublisherAccountById", "ReadPublisherLatestGlucoseValues"])
        if !requests[1].body.isEmpty {
            XCTAssertEqual(requests[1].body, ["accountName": "follower", "password": "secret", "applicationId": ConstantsDexcomShare.applicationId])
            XCTAssertEqual(requests[2].body["accountId"], accountID)
        }
        XCTAssertEqual(requests[3].query, ["sessionId": sessionID, "minutes": "1440", "maxCount": "288"])
        await waitUntil { FollowerSessionState.shared.status(for: .dexcomShare) == .loggedIn }
        XCTAssertEqual(FollowerSessionState.shared.status(for: .dexcomShare), .loggedIn)
    }

    func testStoredJapanRegionIsUsedDirectlyWithJapaneseApplicationID() async {
        UserDefaults.standard.dexcomShareRegion = .jp
        serve(egvs: [egvJSON([(1_800_000_000_000, 99)])])
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        let requests = ShareFollowStubProtocol.requests
        XCTAssertEqual(Set(requests.map(\.host)), ["share.dexcom.jp"])
        if let body = requests.first?.body, !body.isEmpty {
            XCTAssertEqual(body["applicationId"], ConstantsDexcomShare.applicationIdJapan)
        }
        XCTAssertEqual(UserDefaults.standard.dexcomShareRegion, .jp)
    }

    func testFailedSessionIDInEveryRegionClearsRegionAndRecordsFailure() async {
        serve(session: ConstantsDexcomShare.failedSessionId)
        let manager = makeManager()
        manager.download()
        await waitUntil { UserDefaults.standard.dexcomShareLoginFailedTimestamp != nil }
        XCTAssertNotNil(UserDefaults.standard.dexcomShareLoginFailedTimestamp)
        XCTAssertEqual(UserDefaults.standard.dexcomShareRegion, DexcomShareRegion.none)
        XCTAssertEqual(ShareFollowStubProtocol.requests.filter { $0.path == "LoginPublisherAccountById" }.count, 3)
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testExpiredSessionReauthenticatesOnceAndRetries() async {
        UserDefaults.standard.dexcomShareRegion = .us
        serve(egvs: ["[]", egvJSON([(1_800_000_000_000, 140)])], egvStatus: [401, 200])
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertEqual(delegate.received.first?.map(\.sgv), [140])
        XCTAssertEqual(ShareFollowStubProtocol.requests.filter { $0.path == "LoginPublisherAccountById" }.count, 2)
    }

    func testFetchWindowScalesWithLatestStoredReading() async {
        UserDefaults.standard.dexcomShareRegion = .us
        storeReading(minutesAgo: 60)
        serve(egvs: [egvJSON([(1_800_000_000_000, 140)])])
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        let query = ShareFollowStubProtocol.requests.last { $0.path == "ReadPublisherLatestGlucoseValues" }?.query
        XCTAssertEqual(query?["minutes"], "60")
        XCTAssertEqual(query?["maxCount"], "12")
    }

    func testRecentReadingRequestsOnlyLatestValue() async {
        UserDefaults.standard.dexcomShareRegion = .us
        storeReading(minutesAgo: 3)
        serve(egvs: [egvJSON([(1_800_000_000_000, 140)])])
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        let query = ShareFollowStubProtocol.requests.last { $0.path == "ReadPublisherLatestGlucoseValues" }?.query
        XCTAssertEqual(query?["minutes"], "6")
        XCTAssertEqual(query?["maxCount"], "1")
    }

    func testUnparseableDatesAreSkippedAndEmptyResponseIsNotDelivered() async {
        UserDefaults.standard.dexcomShareRegion = .us
        serve(egvs: [#"[{"DT":"bad","ST":"bad","WT":"","Value":100},{"DT":"/Date(1800000000000)/","ST":"nope","WT":"","Value":101}]"#])
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertEqual(delegate.received.first?.map(\.sgv), [101])

        delegate.received = []
        ShareFollowStubProtocol.reset()
        serve(egvs: ["[]"])
        manager.download()
        await waitUntil { !ShareFollowStubProtocol.requests.isEmpty }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testManualLogoutBlocksDownloadsAndLoginReenables() async {
        serve()
        let manager = makeManager()
        manager.logOut()
        XCTAssertTrue(UserDefaults.standard.dexcomShareManuallyLoggedOut)
        XCTAssertEqual(keepAlive.stopped.last, .dexcomShare)
        manager.download()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(ShareFollowStubProtocol.requests.isEmpty)
        XCTAssertEqual(FollowerSessionState.shared.status(for: .dexcomShare), .loggedOut)

        UserDefaults.standard.dexcomShareLoginFailedTimestamp = Date()
        manager.logIn()
        XCTAssertFalse(UserDefaults.standard.dexcomShareManuallyLoggedOut)
        XCTAssertNil(UserDefaults.standard.dexcomShareLoginFailedTimestamp)
        XCTAssertEqual(keepAlive.started.last, .dexcomShare)
    }

    func testCredentialChangeLogsOutAndResetsRegion() {
        let manager = makeManager()
        UserDefaults.standard.dexcomShareRegion = .us
        UserDefaults.standard.timeStampOfLastFollowerConnection = Date()
        UserDefaults.standard.dexcomSharePassword = "changed"
        XCTAssertTrue(UserDefaults.standard.dexcomShareManuallyLoggedOut)
        XCTAssertEqual(UserDefaults.standard.dexcomShareRegion, DexcomShareRegion.none)
        XCTAssertNil(UserDefaults.standard.timeStampOfLastFollowerConnection)
        withExtendedLifetime(manager) {}
    }

    func testLeavingFollowerModeStopsAndPublishesEmptyArray() {
        let manager = makeManager()
        UserDefaults.standard.isMaster = true
        XCTAssertEqual(keepAlive.stopped.last, .dexcomShare)
        XCTAssertEqual(delegate.received.last?.count, 0)
        withExtendedLifetime(manager) {}
    }

    func testInitClearsFailedLoginTimestampAndCreateBgReadingNamesDevice() {
        UserDefaults.standard.dexcomShareLoginFailedTimestamp = Date()
        let manager = makeManager()
        XCTAssertNil(UserDefaults.standard.dexcomShareLoginFailedTimestamp)
        let reading = manager.createBgReading(followGlucoseData: FollowerBgReading(timeStamp: Date(), sgv: 111))
        XCTAssertEqual(reading.deviceName, ConstantsHomeView.applicationName + " (Dexcom Share)")
        XCTAssertEqual(reading.calculatedValue, 111)
        XCTAssertTrue(reading.hideSlope)
    }
}
