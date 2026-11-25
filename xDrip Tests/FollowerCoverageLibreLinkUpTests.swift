//
//  FollowerCoverageLibreLinkUpTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Serves the LibreLinkUp login, connections and graph endpoints without contacting LibreView.
private final class LibreStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, String))?
    private static var storedRequests: [URLRequest] = []

    static var handler: ((URLRequest) -> (Int, String))? {
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
        request.url?.host?.contains("libreview") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, body) = handler?(request) ?? (500, "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LibreDelegateSpy: FollowerDelegate {
    var received: [[FollowerBgReading]] = []
    func followerInfoReceived(followGlucoseDataArray: inout [FollowerBgReading]) {
        received.append(followGlucoseDataArray)
    }
}

private final class LibreKeepAliveSpy: FollowerBackgroundKeepAliveManaging {
    var started: [FollowerBackgroundKeepAliveSource] = []
    var stopped: [FollowerBackgroundKeepAliveSource] = []
    func start(for source: FollowerBackgroundKeepAliveSource, backgroundRefresh: (() -> Void)?) { started.append(source) }
    func stop(for source: FollowerBackgroundKeepAliveSource) { stopped.append(source) }
}

@MainActor final class FollowerCoverageLibreLinkUpTests: XCTestCase {
    private let keys: [UserDefaults.Key] = [
        .isMaster, .followerDataSourceType, .libreLinkUpEmail, .libreLinkUpPassword, .libreLinkUpManuallyLoggedOut,
        .libreLinkUpPreventLogin, .libreLinkUpReAcceptNeeded, .libreLinkUpRegion, .libreLinkUpCountry, .libreLinkUpVersion,
        .libreLinkUpIs15DaySensor, .activeSensorSerialNumber, .activeSensorDescription, .activeSensorStartDate,
        .activeSensorMaxSensorAgeInDays, .timeStampOfLastFollowerConnection, .timeStampLatestNightscoutSyncRequest,
        .nightscoutSyncRequired, .followerBackgroundKeepAliveType
    ]
    private var saved: [String: Any] = [:]
    private var coreDataManager: CoreDataManager!
    private var delegate: LibreDelegateSpy!
    private var keepAlive: LibreKeepAliveSpy!
    private let sensorStart: Double = 1_799_000_000
    private let readingTime = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { saved[key.rawValue] = value }
        }
        URLProtocol.registerClass(LibreStubProtocol.self)
        LibreStubProtocol.reset()
        let defaults = UserDefaults.standard
        defaults.timeStampLatestNightscoutSyncRequest = Date()
        defaults.followerBackgroundKeepAliveType = .heartbeat
        defaults.libreLinkUpManuallyLoggedOut = true
        defaults.isMaster = false
        defaults.followerDataSourceType = .libreLinkUp
        defaults.libreLinkUpEmail = "follower@coverage.test"
        defaults.libreLinkUpPassword = "password"
        defaults.libreLinkUpManuallyLoggedOut = false
        defaults.libreLinkUpPreventLogin = false
        defaults.libreLinkUpReAcceptNeeded = false
        defaults.libreLinkUpIs15DaySensor = false
        defaults.libreLinkUpVersion = ConstantsLibreLinkUp.libreLinkUpVersionDefault
        defaults.activeSensorSerialNumber = nil
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        delegate = LibreDelegateSpy()
        keepAlive = LibreKeepAliveSpy()
    }

    override func tearDown() async throws {
        UserDefaults.standard.libreLinkUpManuallyLoggedOut = true
        UserDefaults.standard.isMaster = saved[UserDefaults.Key.isMaster.rawValue] as? Bool ?? true
        // Returns once the requests started by the managers have stopped coming, instead of a fixed sleep.
        await waitUntilStable { LibreStubProtocol.requests.count }
        for key in keys {
            if let value = saved[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        URLProtocol.unregisterClass(LibreStubProtocol.self)
        LibreStubProtocol.reset()
        delegate = nil
        coreDataManager = nil
    }

    private func makeManager() -> LibreLinkUpFollowManager {
        LibreLinkUpFollowManager(coreDataManager: coreDataManager, followerDelegate: delegate, backgroundKeepAliveManager: keepAlive, startsInitialDownload: false)
    }

    private func factoryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        return formatter.string(from: date)
    }

    private func loginBody(userID: String = "user-1", expires: Double = Date().timeIntervalSince1970 + 3600) -> String {
        #"{"status":0,"data":{"user":{"id":"\#(userID)","country":"BE"},"authTicket":{"token":"jwt-token","expires":\#(expires)}}}"#
    }

    private func graphBody(serial: String? = "MH12345678", inConnection: Bool = false, includeData: Bool = true) -> String {
        let sensor = serial.map { #"{"sn":"\#($0)","a":\#(sensorStart)}"# }
        let current = #"{"FactoryTimestamp":"\#(factoryTimestamp(readingTime))","ValueInMgPerDl":130}"#
        let history = [readingTime.addingTimeInterval(-600), readingTime.addingTimeInterval(-300)].enumerated().map {
            #"{"FactoryTimestamp":"\#(factoryTimestamp($0.element))","ValueInMgPerDl":\#(110 + $0.offset * 10)}"#
        }
        var connection: [String] = []
        if includeData { connection.append(#""glucoseMeasurement":\#(current)"#) }
        if inConnection, let sensor { connection.append(#""sensor":\#(sensor)"#) }
        var data = [#""connection":{\#(connection.joined(separator: ","))}"#]
        if !inConnection, let sensor { data.append(#""activeSensors":[{"sensor":\#(sensor)}]"#) }
        if includeData { data.append(#""graphData":[\#(history.joined(separator: ","))]"#) }
        return #"{"status":0,"data":{\#(data.joined(separator: ","))}}"#
    }

    private func serve(login: String? = nil, connections: String = #"{"status":0,"data":[{"patientId":"patient-9"}]}"#, graph: String? = nil, graphStatus: Int = 200) {
        let login = login ?? loginBody()
        let graph = graph ?? graphBody()
        LibreStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") { return (200, login) }
            if path.hasSuffix("/graph") { return (graphStatus, graph) }
            if path.hasSuffix("/connections") { return (200, connections) }
            return (404, "")
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func paths() -> [String] { LibreStubProtocol.requests.compactMap { $0.url?.path } }

    // MARK: - Tests

    func testFullFlowDeliversReadingsAndStoresSensorAndAccountDetails() async throws {
        serve()
        let manager = makeManager()
        XCTAssertEqual(keepAlive.started, [.libreLinkUp])
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }

        let readings = try XCTUnwrap(delegate.received.first)
        XCTAssertEqual(readings.map(\.sgv), [130, 120, 110])
        XCTAssertEqual(readings.first?.timeStamp, readingTime)
        XCTAssertEqual(paths(), ["/llu/auth/login", "/llu/connections", "/llu/connections/patient-9/graph"])

        let defaults = UserDefaults.standard
        XCTAssertEqual(defaults.libreLinkUpCountry, "BE")
        XCTAssertEqual(defaults.libreLinkUpRegion, .notConfigured)
        XCTAssertEqual(defaults.activeSensorSerialNumber, "MH12345678")
        XCTAssertEqual(defaults.activeSensorStartDate, Date(timeIntervalSince1970: sensorStart))
        XCTAssertEqual(defaults.activeSensorMaxSensorAgeInDays, ConstantsLibreLinkUp.libreLinkUpMaxSensorAgeInDays)
        XCTAssertEqual(defaults.activeSensorDescription, "LibreLinkUp (Libre 2)")
        XCTAssertNotNil(defaults.timeStampOfLastFollowerConnection)
        await waitUntil { FollowerSessionState.shared.status(for: .libreLinkUp) == .loggedIn }
        XCTAssertEqual(FollowerSessionState.shared.status(for: .libreLinkUp), .loggedIn)

        let login = try XCTUnwrap(LibreStubProtocol.requests.first)
        XCTAssertEqual(login.httpMethod, "POST")
        XCTAssertEqual(login.value(forHTTPHeaderField: "version"), ConstantsLibreLinkUp.libreLinkUpVersionDefault)
        let graph = try XCTUnwrap(LibreStubProtocol.requests.last)
        XCTAssertEqual(graph.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")
        XCTAssertEqual(graph.value(forHTTPHeaderField: "Account-Id"), "user-1".sha256())
    }

    func testSecondDownloadReusesValidTokenAndPatient() async {
        serve()
        let manager = makeManager()
        manager.download()
        await waitUntil { self.delegate.received.count == 1 }
        manager.download()
        await waitUntil { self.delegate.received.count == 2 }
        XCTAssertEqual(paths().filter { $0.hasSuffix("/auth/login") }.count, 1)
        XCTAssertEqual(paths().filter { $0.hasSuffix("/graph") }.count, 2)
    }

    func testExpiredTokenTriggersNewLogin() async {
        serve(login: loginBody(expires: Date().timeIntervalSince1970 - 10))
        let manager = makeManager()
        manager.download()
        await waitUntil { self.delegate.received.count == 1 }
        manager.download()
        await waitUntil { self.delegate.received.count == 2 }
        XCTAssertEqual(paths().filter { $0.hasSuffix("/auth/login") }.count, 2)
    }

    func testRegionRedirectRetriesAgainstRegionalHost() async throws {
        let normalLogin = loginBody()
        let graph = graphBody()
        LibreStubProtocol.handler = { request in
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                return host == "api.libreview.io" ? (200, #"{"status":0,"data":{"redirect":true,"region":"eu"}}"#) : (200, normalLogin)
            }
            if path.hasSuffix("/graph") { return (200, graph) }
            return (200, #"{"status":0,"data":[{"patientId":"patient-9"}]}"#)
        }
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertEqual(LibreStubProtocol.requests.compactMap { $0.url?.host }, ["api.libreview.io", "api-eu.libreview.io", "api-eu.libreview.io", "api-eu.libreview.io"])
        XCTAssertEqual(UserDefaults.standard.libreLinkUpRegion, .eu)
    }

    func testInvalidCredentialsPreventFurtherLoginAttempts() async {
        serve(login: #"{"status":2}"#)
        let manager = makeManager()
        manager.download()
        await waitUntil { UserDefaults.standard.libreLinkUpPreventLogin }
        XCTAssertTrue(UserDefaults.standard.libreLinkUpPreventLogin)
        XCTAssertEqual(UserDefaults.standard.timeStampOfLastFollowerConnection, .distantPast)
        XCTAssertNil(UserDefaults.standard.activeSensorSerialNumber)

        manager.download()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(paths(), ["/llu/auth/login"])
        XCTAssertTrue(delegate.received.isEmpty)

        manager.logIn()
        XCTAssertFalse(UserDefaults.standard.libreLinkUpPreventLogin)
    }

    func testTermsReacceptanceIsFlagged() async {
        serve(login: #"{"status":4,"data":{}}"#)
        let manager = makeManager()
        manager.download()
        await waitUntil { UserDefaults.standard.libreLinkUpReAcceptNeeded }
        XCTAssertTrue(UserDefaults.standard.libreLinkUpReAcceptNeeded)
        XCTAssertEqual(paths(), ["/llu/auth/login"])
    }

    func testMissingAuthPayloadOrPatientStopsBeforeGraph() async {
        serve(login: #"{"status":0,"data":{"user":{"id":"u"}}}"#)
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.paths().isEmpty }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(paths(), ["/llu/auth/login"])

        LibreStubProtocol.reset()
        serve(connections: #"{"status":0,"data":[]}"#)
        manager.download()
        await waitUntil { self.paths().count >= 2 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(paths(), ["/llu/auth/login", "/llu/connections"])
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testConnectionsPreferPatientMatchingUser() async {
        serve(connections: #"{"status":0,"data":[{"patientId":"other"},{"patientId":"user-1"}]}"#)
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertEqual(paths().last, "/llu/connections/user-1/graph")
    }

    func testLibre3SerialDropsCheckDigitAndFifteenDaySensorAge() async {
        UserDefaults.standard.libreLinkUpIs15DaySensor = true
        serve(graph: graphBody(serial: "0D1234567890", inConnection: true))
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertEqual(UserDefaults.standard.activeSensorSerialNumber, "0D123456789")
        XCTAssertEqual(UserDefaults.standard.activeSensorDescription, "LibreLinkUp (Libre 3)")
        XCTAssertEqual(UserDefaults.standard.activeSensorMaxSensorAgeInDays, ConstantsLibreLinkUp.libreLinkUpMaxSensorAgeInDaysLibrePlus)
    }

    func testLibre2PlusSerialDescription() async {
        serve(graph: graphBody(serial: "0123456789"))
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertEqual(UserDefaults.standard.activeSensorSerialNumber, "0123456789")
        XCTAssertEqual(UserDefaults.standard.activeSensorDescription, "LibreLinkUp (Libre 2 Plus)")
    }

    func testMissingSensorClearsStoredSensorButStillDeliversReadings() async {
        UserDefaults.standard.activeSensorSerialNumber = "OLD"
        serve(graph: graphBody(serial: nil))
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertNil(UserDefaults.standard.activeSensorSerialNumber)
        XCTAssertEqual(delegate.received.first?.count, 3)
    }

    func testEmptyGraphOrHTTPErrorDoesNotCallDelegate() async {
        serve(graph: graphBody(serial: "MH1", includeData: false))
        let manager = makeManager()
        manager.download()
        await waitUntil { self.paths().contains { $0.hasSuffix("/graph") } }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(delegate.received.isEmpty)

        LibreStubProtocol.reset()
        serve(graphStatus: 500)
        manager.download()
        await waitUntil { self.paths().contains { $0.hasSuffix("/graph") } }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(delegate.received.isEmpty)
    }

    func testManualLogoutStopsFollowingWithoutNetwork() async {
        serve()
        let manager = makeManager()
        UserDefaults.standard.activeSensorSerialNumber = "MH1"
        manager.logOut()
        XCTAssertTrue(UserDefaults.standard.libreLinkUpManuallyLoggedOut)
        XCTAssertNil(UserDefaults.standard.activeSensorSerialNumber)
        XCTAssertEqual(keepAlive.stopped.last, .libreLinkUp)
        manager.download()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(paths().isEmpty)
        await waitUntil { FollowerSessionState.shared.status(for: .libreLinkUpRussia) == .loggedOut }
        XCTAssertEqual(FollowerSessionState.shared.status(for: .libreLinkUpRussia), .loggedOut)
    }

    func testDownloadIgnoredOutsideLibreLinkUpFollowerMode() async {
        serve()
        let manager = makeManager()
        UserDefaults.standard.isMaster = true
        manager.download()
        UserDefaults.standard.followerDataSourceType = .dexcomShare
        UserDefaults.standard.isMaster = false
        manager.download()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(paths().isEmpty)
    }

    func testRussianSourceUsesRussianHost() async {
        UserDefaults.standard.followerDataSourceType = .libreLinkUpRussia
        serve()
        let manager = makeManager()
        manager.download()
        await waitUntil { !self.delegate.received.isEmpty }
        XCTAssertEqual(Set(LibreStubProtocol.requests.compactMap { $0.url?.host }), ["api.libreview.ru"])
        XCTAssertEqual(UserDefaults.standard.activeSensorDescription, "LibreLinkUp Russia (Libre 2)")
    }

    func testVersionDefaultIsPromotedButNewerOverrideIsKept() {
        UserDefaults.standard.libreLinkUpVersion = "1.0.0"
        _ = makeManager()
        XCTAssertEqual(UserDefaults.standard.libreLinkUpVersion, ConstantsLibreLinkUp.libreLinkUpVersionDefault)
        UserDefaults.standard.libreLinkUpVersion = "99.0.0"
        _ = makeManager()
        XCTAssertEqual(UserDefaults.standard.libreLinkUpVersion, "99.0.0")
    }

    func testCreateBgReadingUsesFollowerValue() {
        let manager = makeManager()
        let reading = manager.createBgReading(followGlucoseData: FollowerBgReading(timeStamp: readingTime, sgv: 155))
        XCTAssertEqual(reading.calculatedValue, 155)
        XCTAssertEqual(reading.timeStamp, readingTime)
        XCTAssertTrue(reading.hideSlope)
    }
}
