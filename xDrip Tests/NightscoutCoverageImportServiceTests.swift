//
//  NightscoutCoverageImportServiceTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

/// Serves every request made through the import service's injected session.
private final class ImportStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, [String: String], Data))?
    private static var storedRequests: [URLRequest] = []

    static var handler: ((URLRequest) -> (Int, [String: String], Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock()
        storedHandler = nil
        storedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, headers, data) = handler?(request) ?? (200, [:], Data("[]".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func importQuery(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NightscoutImportProgress] = []
    func append(_ progress: NightscoutImportProgress) { lock.lock(); values.append(progress); lock.unlock() }
    var all: [NightscoutImportProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor final class NightscoutCoverageImportServiceTests: XCTestCase {
    private let site = "https://ns.coverage.test"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let defaultsKeys: [UserDefaults.Key] = [.nightscoutUrl, .nightscoutPort, .nightscoutAPIKey, .nightscoutToken, .retentionPeriodInDays, .timeStampOfLastFollowerConnection]
    private var savedDefaults: [String: Any] = [:]
    private var checkpointDefaults: UserDefaults!
    private var checkpointSuite = ""
    private var coreDataManager: CoreDataManager!
    private var session: URLSession!
    private var service: NightscoutImportService!

    override func setUp() async throws {
        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { savedDefaults[key.rawValue] = value }
        }
        ImportStubProtocol.reset()
        UserDefaults.standard.nightscoutAPIKey = nil
        UserDefaults.standard.nightscoutToken = nil
        UserDefaults.standard.nightscoutPort = 0
        UserDefaults.standard.retentionPeriodInDays = 365
        UserDefaults.standard.nightscoutUrl = site
        checkpointSuite = "NightscoutCoverageImport-\(UUID().uuidString)"
        checkpointDefaults = UserDefaults(suiteName: checkpointSuite)
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportStubProtocol.self]
        session = URLSession(configuration: configuration)
        service = NightscoutImportService(coreDataManager: coreDataManager, checkpointStore: NightscoutImportCheckpointStore(userDefaults: checkpointDefaults), session: session)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        ImportStubProtocol.reset()
        checkpointDefaults.removePersistentDomain(forName: checkpointSuite)
        for key in defaultsKeys {
            if let value = savedDefaults[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        service = nil
        coreDataManager = nil
    }

    // MARK: - Helpers

    private func respond(_ handler: @escaping (URLRequest) -> (Int, [String: String], Data)) {
        ImportStubProtocol.handler = handler
    }

    private func respondJSON(_ json: String, status: Int = 200) {
        respond { _ in (status, [:], Data(json.utf8)) }
    }

    private func query(_ request: URLRequest) -> [String: String] {
        importQuery(request)
    }

    private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter.withFractionalSeconds.string(from: date) }

    private func hour(endingAt end: Date? = nil) -> DateInterval {
        let end = end ?? now
        return DateInterval(start: end.addingTimeInterval(-3600), end: end)
    }

    private func bgReadings() -> [BgReading] {
        let context = coreDataManager.mainManagedObjectContext
        var readings: [BgReading] = []
        context.performAndWait {
            let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timeStamp", ascending: true)]
            readings = (try? context.fetch(request)) ?? []
        }
        return readings
    }

    private func treatments() -> [TreatmentEntry] {
        let context = coreDataManager.mainManagedObjectContext
        var entries: [TreatmentEntry] = []
        context.performAndWait {
            let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            entries = (try? context.fetch(request)) ?? []
        }
        return entries
    }

    private func expectImportError(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line, _ matches: (NightscoutImportError) -> Bool) async {
        do {
            try await operation()
            XCTFail("expected NightscoutImportError", file: file, line: line)
        } catch let error as NightscoutImportError {
            XCTAssertTrue(matches(error), "unexpected error \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func profileJSON(id: String, start: Date, name: String = "Default", basal: Double = 0.8) -> String {
        """
        {"_id":"\(id)","defaultProfile":"\(name)","startDate":"\(iso(start))","enteredBy":"Loop","units":"mg/dl","store":{"\(name)":{
        "basal":[{"time":"00:00","value":\(basal),"timeAsSeconds":0}],"carbratio":[{"time":"00:00","value":10,"timeAsSeconds":0}],
        "sens":[{"time":"00:00","value":45,"timeAsSeconds":0}],"target_low":[{"time":"00:00","value":90,"timeAsSeconds":0}],
        "target_high":[{"time":"00:00","value":120,"timeAsSeconds":0}],"timezone":"UTC","dia":6,"units":"mg/dl"}}}
        """
    }

    // MARK: - Value types

    func testPeriodSupportAvailabilityAndSingleValueCoding() throws {
        XCTAssertTrue(NightscoutImportPeriod.sevenDays.isSupported)
        XCTAssertTrue(NightscoutImportPeriod.oneYear.isSupported)
        XCTAssertFalse(NightscoutImportPeriod(rawValue: 8).isSupported)
        XCTAssertEqual(NightscoutImportPeriod.thirtyDays.id, 30)
        XCTAssertFalse(NightscoutImportPeriod.ninetyDays.title.isEmpty)
        XCTAssertEqual(NightscoutImportPeriod.available(retentionDays: 90).map(\.rawValue), [7, 30, 90])
        XCTAssertEqual(NightscoutImportPeriod.available(retentionDays: 6), [])
        XCTAssertEqual(NightscoutImportPeriod.available(retentionDays: 365).count, 5)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(NightscoutImportPeriod.oneHundredEightyDays), as: UTF8.self), "180")
        XCTAssertEqual(try JSONDecoder().decode(NightscoutImportPeriod.self, from: Data("30".utf8)), .thirtyDays)
    }

    func testOptionsSelectionAndLegacyDecodingWithoutDeviceStatus() throws {
        XCTAssertFalse(NightscoutImportOptions(period: .sevenDays, includesBgReadings: false, includesTreatments: false, includesDeviceStatus: false).hasSelection)
        XCTAssertTrue(NightscoutImportOptions(period: .sevenDays, includesBgReadings: false, includesTreatments: false, includesDeviceStatus: true).hasSelection)
        let legacy = try JSONDecoder().decode(NightscoutImportOptions.self, from: Data(#"{"period":7,"includesBgReadings":true,"includesTreatments":false}"#.utf8))
        XCTAssertEqual(legacy.period, .sevenDays)
        XCTAssertTrue(legacy.includesBgReadings)
        XCTAssertFalse(legacy.includesDeviceStatus)
        XCTAssertThrowsError(try JSONDecoder().decode(NightscoutImportOptions.self, from: Data(#"{"period":7}"#.utf8)))
    }

    func testCountsDecodeMissingFieldsAsZero() throws {
        let counts = try JSONDecoder().decode(NightscoutImportCounts.self, from: Data(#"{"bgReadingsAdded":4,"treatmentsSkipped":2}"#.utf8))
        XCTAssertEqual(counts.bgReadingsAdded, 4)
        XCTAssertEqual(counts.treatmentsSkipped, 2)
        XCTAssertEqual(counts.deviceStatusAdded, 0)
        XCTAssertEqual(counts.bgDocumentsDownloaded, 0)
        var roundTrip = counts
        roundTrip.deviceStatusDocumentsInvalid = 3
        let decoded = try JSONDecoder().decode(NightscoutImportCounts.self, from: JSONEncoder().encode(roundTrip))
        XCTAssertEqual(decoded.deviceStatusDocumentsInvalid, 3)
        XCTAssertEqual(decoded.bgReadingsAdded, 4)
    }

    func testProgressFractionIsClamped() {
        func progress(_ done: Int, _ total: Int) -> Double {
            NightscoutImportProgress(completedUnits: done, totalUnits: total, chunkNumber: 1, totalChunks: 1, counts: NightscoutImportCounts()).fractionCompleted
        }
        XCTAssertEqual(progress(0, 0), 0)
        XCTAssertEqual(progress(1, 4), 0.25)
        XCTAssertEqual(progress(9, 4), 1)
        XCTAssertEqual(progress(-1, 4), 0)
    }

    func testErrorsHaveDistinctDescriptions() {
        let errors: [NightscoutImportError] = [.noDataSelected, .unsupportedPeriod, .periodExceedsRetention, .missingURL, .invalidURL, .checkpointUnavailable, .checkpointSiteChanged, .authenticationFailed, .endpointNotFound, .rateLimited, .serverError(502), .unexpectedStatus(418), .invalidResponse, .responseLimitExceeded]
        let descriptions = errors.compactMap(\.errorDescription)
        XCTAssertEqual(descriptions.count, errors.count)
        XCTAssertEqual(Set(descriptions).count, errors.count)
        XCTAssertTrue(NightscoutImportError.serverError(502).errorDescription!.contains("502"))
        XCTAssertTrue(NightscoutImportError.unexpectedStatus(418).errorDescription!.contains("418"))
    }

    func testMakeChunksUsesWholeDaysAndShorterFinalChunk() {
        let start = now
        let chunks = NightscoutImportService.makeChunks(from: start, to: start.addingTimeInterval(2.5 * 86_400))
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], DateInterval(start: start, end: start.addingTimeInterval(86_400)))
        XCTAssertEqual(chunks[2].duration, 43_200, accuracy: 0.001)
        XCTAssertEqual(chunks.last?.end, start.addingTimeInterval(2.5 * 86_400))
        XCTAssertEqual(NightscoutImportService.makeChunks(from: start, to: start), [])
        XCTAssertEqual(NightscoutImportService.makeChunks(from: start, to: start.addingTimeInterval(-1)), [])
    }

    func testNormalizedSiteIdentityRemovesSecretsAndTrailingSlashes() {
        XCTAssertEqual(NightscoutImportService.normalizedSiteIdentity(from: URLComponents(string: "https://user:pw@ns.example.com/base///?token=x#frag")!), "https://ns.example.com/base")
        XCTAssertEqual(NightscoutImportService.normalizedSiteIdentity(from: URLComponents(string: "HTTP://ns.example.com:8080/")!), "HTTP://ns.example.com:8080")
        XCTAssertNil(NightscoutImportService.normalizedSiteIdentity(from: URLComponents(string: "ftp://ns.example.com")!))
        XCTAssertNil(NightscoutImportService.normalizedSiteIdentity(from: URLComponents(string: "ns.example.com")!))
        var badPort = URLComponents(string: "https://ns.example.com")!
        badPort.port = 70_000
        XCTAssertNil(NightscoutImportService.normalizedSiteIdentity(from: badPort))
    }

    func testImportedBgReadingIdentifierPrefix() {
        XCTAssertTrue(NightscoutImportService.isImportedBgReadingID("nightscout-import:abc"))
        XCTAssertFalse(NightscoutImportService.isImportedBgReadingID("abc"))
        XCTAssertFalse(NightscoutImportService.isImportedBgReadingID("xnightscout-import:abc"))
    }

    func testCheckpointStoreRoundTripsAndIgnoresCorruptData() throws {
        let store = NightscoutImportCheckpointStore(userDefaults: checkpointDefaults)
        XCTAssertNil(store.load())
        checkpointDefaults.set(Data("garbage".utf8), forKey: "nightscoutHistoricalImportCheckpointV1")
        XCTAssertNil(store.load())
        let json = """
        {"id":"\(UUID().uuidString)","createdAt":0,"siteURL":"https://a.coverage.test","requestedFrom":0,"requestedTo":604800,
        "options":{"period":7,"includesBgReadings":true,"includesTreatments":true,"includesDeviceStatus":false},
        "nextChunkIndex":9,"nextPhase":"treatments","counts":{"bgReadingsAdded":5}}
        """
        let checkpoint = try JSONDecoder().decode(NightscoutImportCheckpoint.self, from: Data(json.utf8))
        XCTAssertEqual(checkpoint.totalChunks, 7)
        XCTAssertEqual(checkpoint.completedChunks, 7)
        try store.save(checkpoint)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.id, checkpoint.id)
        XCTAssertEqual(loaded.counts.bgReadingsAdded, 5)
        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - Configuration and request building

    func testEmptyOrReversedIntervalsReturnWithoutNetwork() async throws {
        UserDefaults.standard.nightscoutUrl = nil
        let bg = try await service.mergeBgReadings(in: [DateInterval(start: now, end: now)])
        XCTAssertEqual(bg.readingsAdded, 0)
        let treatments = try await service.mergeTreatments(in: DateInterval(start: now, end: now))
        XCTAssertEqual(treatments.documentsDownloaded, 0)
        let status = try await service.mergeDeviceStatus(in: DateInterval(start: now, end: now))
        XCTAssertEqual(status.documentsDownloaded, 0)
        let profiles = try await service.mergeProfiles(in: DateInterval(start: now, end: now))
        XCTAssertEqual(profiles.documentsDownloaded, 0)
        XCTAssertTrue(ImportStubProtocol.requests.isEmpty)
    }

    func testMissingAndInvalidSiteConfigurationsAreRejected() async {
        UserDefaults.standard.nightscoutUrl = nil
        await expectImportError({ _ = try await self.service.mergeBgReadings(in: [self.hour()]) }) { if case .missingURL = $0 { return true }; return false }
        UserDefaults.standard.nightscoutUrl = "ftp://ns.coverage.test"
        await expectImportError({ _ = try await self.service.mergeTreatments(in: self.hour()) }) { if case .invalidURL = $0 { return true }; return false }
        UserDefaults.standard.nightscoutUrl = "not a url"
        await expectImportError({ _ = try await self.service.mergeDeviceStatus(in: self.hour()) }) { if case .invalidURL = $0 { return true }; return false }
        UserDefaults.standard.nightscoutUrl = site
        UserDefaults.standard.nightscoutPort = 70_000
        await expectImportError({ _ = try await self.service.mergeProfiles(in: self.hour()) }) { if case .invalidURL = $0 { return true }; return false }
        XCTAssertTrue(ImportStubProtocol.requests.isEmpty)
    }

    func testBgRequestUsesBasePathPortRangeTokenAndHashedSecret() async throws {
        UserDefaults.standard.nightscoutUrl = "  https://ns.coverage.test/base/?token=stale#frag "
        UserDefaults.standard.nightscoutPort = 8443
        UserDefaults.standard.nightscoutToken = "  follower-token "
        UserDefaults.standard.nightscoutAPIKey = "secret"
        respondJSON("[]")
        let interval = hour()
        _ = try await service.mergeBgReadings(in: [interval])

        let request = try XCTUnwrap(ImportStubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "ns.coverage.test")
        XCTAssertEqual(request.url?.port, 8443)
        XCTAssertEqual(request.url?.path, "/base/api/v1/entries/sgv.json")
        XCTAssertNil(request.url?.fragment)
        let query = query(request)
        XCTAssertEqual(query["find[date][$gte]"], String(millis(interval.start)))
        XCTAssertEqual(query["find[date][$lt]"], String(millis(interval.end)))
        XCTAssertEqual(query["count"], "2000")
        XCTAssertEqual(query["token"], "follower-token")
        XCTAssertEqual(request.url?.query?.components(separatedBy: "token=").count, 2)
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "secret".sha1())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNotNil(UserDefaults.standard.timeStampOfLastFollowerConnection)
    }

    func testRequestWithoutCredentialsHasNoTokenOrSecret() async throws {
        UserDefaults.standard.nightscoutToken = "   "
        respondJSON("[]")
        _ = try await service.mergeBgReadings(in: [hour()])
        let request = try XCTUnwrap(ImportStubProtocol.requests.first)
        XCTAssertNil(query(request)["token"])
        XCTAssertNil(request.value(forHTTPHeaderField: "api-secret"))
    }

    func testTreatmentAndDeviceStatusRequestsUseCreatedAtISORanges() async throws {
        respondJSON("[]")
        let interval = hour()
        _ = try await service.mergeTreatments(in: interval)
        _ = try await service.mergeDeviceStatus(in: interval)
        let requests = ImportStubProtocol.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/v1/treatments.json", "/api/v1/devicestatus.json"])
        for request in requests {
            XCTAssertEqual(query(request)["find[created_at][$gte]"], iso(interval.start))
            XCTAssertEqual(query(request)["find[created_at][$lt]"], iso(interval.end))
            XCTAssertEqual(query(request)["count"], "1000")
        }
    }

    func testMultipleBgIntervalsAreSortedAndInvalidOnesDropped() async throws {
        respondJSON("[]")
        let later = hour()
        let earlier = hour(endingAt: now.addingTimeInterval(-7200))
        _ = try await service.mergeBgReadings(in: [later, DateInterval(start: now, end: now), earlier])
        XCTAssertEqual(ImportStubProtocol.requests.map { importQuery($0)["find[date][$gte]"] }, [String(millis(earlier.start)), String(millis(later.start))])
    }

    // MARK: - HTTP status handling

    func testAuthenticationNotFoundAndUnexpectedStatusesFailImmediately() async {
        for (status, matcher) in [
            (401, { (e: NightscoutImportError) -> Bool in if case .authenticationFailed = e { return true }; return false }),
            (403, { (e: NightscoutImportError) -> Bool in if case .authenticationFailed = e { return true }; return false }),
            (404, { (e: NightscoutImportError) -> Bool in if case .endpointNotFound = e { return true }; return false }),
            (418, { (e: NightscoutImportError) -> Bool in if case .unexpectedStatus(418) = e { return true }; return false })
        ] {
            ImportStubProtocol.reset()
            respondJSON("[]", status: status)
            await expectImportError({ _ = try await self.service.mergeBgReadings(in: [self.hour()]) }, matcher)
            XCTAssertEqual(ImportStubProtocol.requests.count, 1, "status \(status)")
        }
    }

    func testServerErrorIsRetriedAndThenSucceeds() async throws {
        var attempts = 0
        respond { _ in
            attempts += 1
            return attempts == 1 ? (503, ["Retry-After": "0"], Data()) : (200, [:], Data("[]".utf8))
        }
        _ = try await service.mergeBgReadings(in: [hour()])
        XCTAssertEqual(ImportStubProtocol.requests.count, 2)
    }

    func testRateLimitIsRetriedUntilAttemptsAreExhausted() async {
        respond { _ in (429, ["Retry-After": "0.1"], Data()) }
        await expectImportError({ _ = try await self.service.mergeBgReadings(in: [self.hour()]) }) { if case .rateLimited = $0 { return true }; return false }
        XCTAssertEqual(ImportStubProtocol.requests.count, 4)
    }

    func testPersistentServerErrorReportsStatusAfterFourAttempts() async {
        respond { _ in (502, ["Retry-After": "0"], Data()) }
        await expectImportError({ _ = try await self.service.mergeTreatments(in: self.hour()) }) { if case .serverError(502) = $0 { return true }; return false }
        XCTAssertEqual(ImportStubProtocol.requests.count, 4)
    }

    func testMalformedAndNonArrayResponsesAreInvalid() async {
        for body in ["{", #"{"sgv":100}"#, "null"] {
            respondJSON(body)
            await expectImportError({ _ = try await self.service.mergeBgReadings(in: [self.hour()]) }) { if case .invalidResponse = $0 { return true }; return false }
        }
        respondJSON("{")
        await expectImportError({ _ = try await self.service.mergeProfiles(in: self.hour()) }) { if case .invalidResponse = $0 { return true }; return false }
    }

    // MARK: - Response subdivision

    func testFullResponseIsSplitIntoHalfOpenHalves() async throws {
        let full = "[" + Array(repeating: "{}", count: 2000).joined(separator: ",") + "]"
        var calls = 0
        respond { _ in
            calls += 1
            return (200, [:], Data((calls == 1 ? full : "[]").utf8))
        }
        let interval = hour()
        let result = try await service.mergeBgReadings(in: [interval])
        let ranges = ImportStubProtocol.requests.map { (importQuery($0)["find[date][$gte]"]!, importQuery($0)["find[date][$lt]"]!) }
        let midpoint = String(millis(interval.start.addingTimeInterval(1800)))
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[1].0, String(millis(interval.start)))
        XCTAssertEqual(ranges[1].1, midpoint)
        XCTAssertEqual(ranges[2].0, midpoint)
        XCTAssertEqual(ranges[2].1, String(millis(interval.end)))
        XCTAssertEqual(result.documentsDownloaded, 0)
    }

    func testFullResponseForMinimumIntervalThrowsLimitExceeded() async {
        let full = "[" + Array(repeating: "{}", count: 2000).joined(separator: ",") + "]"
        respondJSON(full)
        let interval = DateInterval(start: now.addingTimeInterval(-300), end: now)
        await expectImportError({ _ = try await self.service.mergeBgReadings(in: [interval]) }) { if case .responseLimitExceeded = $0 { return true }; return false }
        XCTAssertEqual(ImportStubProtocol.requests.count, 1)
    }

    // MARK: - BG merge

    func testBgDocumentsAreValidatedNamespacedAndSloped() async throws {
        let interval = hour()
        let t1 = interval.start.addingTimeInterval(60)
        let t2 = interval.start.addingTimeInterval(360)
        let t3 = interval.start.addingTimeInterval(660)
        respondJSON("""
        [{"_id":"a","date":\(millis(t1)),"sgv":120,"type":"sgv","device":"uploader","direction":"SingleUp"},
         {"identifier":"b","dateString":"\(iso(t2))","sgv":"130","direction":"flat"},
         {"date":"\(millis(t3))","sgv":140.0,"direction":"NOT COMPUTABLE","device":""},
         {"_id":"mbg","date":\(millis(t1)),"sgv":100,"type":"mbg"},
         {"_id":"zero","date":\(millis(t1)),"sgv":0},
         {"_id":"huge","date":\(millis(t1)),"sgv":1001},
         {"_id":"nodate","sgv":100},
         {"_id":"outside","date":\(millis(interval.end)),"sgv":100},
         {"_id":"a","date":\(millis(t2)),"sgv":100},
         {"_id":123,"date":\(millis(t1)),"sgv":{"x":1}}]
        """)
        let result = try await service.mergeBgReadings(in: [interval])
        XCTAssertEqual(result.documentsDownloaded, 10)
        XCTAssertEqual(result.documentsInvalid, 7)
        XCTAssertEqual(result.readingsAdded, 3)
        XCTAssertEqual(result.readingsSkipped, 0)

        let readings = bgReadings()
        XCTAssertEqual(readings.map(\.timeStamp), [t1, t2, t3])
        XCTAssertEqual(readings.map(\.calculatedValue), [120, 130, 140])
        XCTAssertEqual(readings[0].id, "nightscout-import:a")
        XCTAssertEqual(readings[1].id, "nightscout-import:b")
        XCTAssertEqual(readings[2].id, "nightscout-import:\(millis(t3)):\(Double(140).bitPattern)")
        XCTAssertEqual(readings[0].deviceName, "uploader")
        XCTAssertEqual(readings[2].deviceName, "Nightscout")
        XCTAssertEqual(readings[0].calculatedValueSlope, 2.5 / 60_000, accuracy: 1e-12)
        XCTAssertFalse(readings[0].hideSlope)
        XCTAssertEqual(readings[1].calculatedValueSlope, 0)
        XCTAssertFalse(readings[1].hideSlope)
        XCTAssertTrue(readings[2].hideSlope)
        XCTAssertTrue(readings.allSatisfy { !$0.isSuppressedByFiveMinuteCadence })
    }

    func testEveryNightscoutDirectionMapsToSlope() async throws {
        let interval = hour()
        let directions: [(String, Double)] = [("DoubleUp", 4), ("SingleUp", 2.5), ("FortyFiveUp", 1.5), ("Flat", 0), ("FortyFiveDown", -1.5), ("SingleDown", -2.5), ("DoubleDown", -4)]
        let docs = directions.enumerated().map { index, entry in
            #"{"_id":"d\#(index)","date":\#(millis(interval.start.addingTimeInterval(Double(index) * 300))),"sgv":100,"direction":"\#(entry.0)"}"#
        }
        respondJSON("[" + docs.joined(separator: ",") + "]")
        _ = try await service.mergeBgReadings(in: [interval])
        let readings = bgReadings()
        XCTAssertEqual(readings.count, directions.count)
        for (reading, entry) in zip(readings, directions) {
            XCTAssertEqual(reading.calculatedValueSlope, entry.1 / 60_000, accuracy: 1e-12, entry.0)
        }
    }

    func testBgMergeSkipsLocalReadingsWithinThirtySecondsAndKnownIDs() async throws {
        let interval = hour()
        let localTime = interval.start.addingTimeInterval(600)
        let context = coreDataManager.mainManagedObjectContext
        context.performAndWait {
            let local = BgReading(timeStamp: localTime, sensor: nil, calibration: nil, rawData: 100, deviceName: "local", nsManagedObjectContext: context)
            local.calculatedValue = 100
            try? context.save()
        }
        respondJSON("""
        [{"_id":"near","date":\(millis(localTime.addingTimeInterval(30))),"sgv":101},
         {"_id":"far","date":\(millis(localTime.addingTimeInterval(31))),"sgv":102}]
        """)
        let first = try await service.mergeBgReadings(in: [interval])
        XCTAssertEqual(first.readingsAdded, 1)
        XCTAssertEqual(first.readingsSkipped, 1)

        let second = try await service.mergeBgReadings(in: [interval])
        XCTAssertEqual(second.readingsAdded, 0)
        XCTAssertEqual(second.readingsSkipped, 2)
        XCTAssertEqual(bgReadings().count, 2)
    }

    // MARK: - Treatment merge

    func testTreatmentDocumentsExpandIntoLocalTreatmentTypes() async throws {
        let interval = hour()
        let t = interval.start.addingTimeInterval(600)
        respondJSON("""
        [{"_id":"meal","created_at":"\(iso(t))","eventType":"Meal Bolus","carbs":30,"insulin":"2.5","enteredBy":"Loop"},
         {"_id":"ex","created_at":"\(iso(t))","eventType":"Exercise","duration":45},
         {"_id":"bg","mills":\(millis(t)),"eventType":"BG Check","glucose":5.5,"units":"mmol"},
         {"_id":"bgmg","eventTime":"\(iso(t))","glucose":110},
         {"_id":"temp","created_at":"\(iso(t))","eventType":"Temp Basal","rate":0.65,"duration":30},
         {"_id":"site","created_at":"\(iso(t))","eventType":"Site Change"},
         {"_id":"sensor","created_at":"\(iso(t))","eventType":"Sensor Change"},
         {"_id":"battery","created_at":"\(iso(t))","eventType":"Pump Battery Change"},
         {"_id":"note","created_at":"\(iso(t))","eventType":"Note","notes":"  hello  "}]
        """)
        let result = try await service.mergeTreatments(in: interval)
        XCTAssertEqual(result.documentsDownloaded, 9)
        XCTAssertEqual(result.documentsUnsupported, 0)
        XCTAssertEqual(result.treatmentsAdded, 10)

        let byID = Dictionary(uniqueKeysWithValues: treatments().map { ($0.id, $0) })
        XCTAssertEqual(byID["meal-carbs"]?.value, 30)
        XCTAssertEqual(byID["meal-carbs"]?.treatmentType, .Carbs)
        XCTAssertEqual(byID["meal-carbs"]?.enteredBy, "Loop")
        XCTAssertEqual(byID["meal-carbs"]?.nightscoutEventType, "Meal Bolus")
        XCTAssertEqual(byID["meal-insulin"]?.value, 2.5)
        XCTAssertEqual(byID["ex-exericse"]?.value, 45)
        XCTAssertEqual(try XCTUnwrap(byID["bg-glucose"]?.value), 5.5.mmolToMgdl(), accuracy: 0.0001)
        XCTAssertEqual(byID["bgmg-glucose"]?.value, 110)
        XCTAssertEqual(byID["temp-rate"]?.treatmentType, .Basal)
        XCTAssertEqual(byID["temp-rate"]?.value, 0.65)
        XCTAssertEqual(byID["temp-rate"]?.valueSecondary, 30)
        XCTAssertEqual(byID["site-"]?.treatmentType, .SiteChange)
        XCTAssertEqual(byID["sensor-"]?.treatmentType, .SensorStart)
        XCTAssertEqual(byID["battery-"]?.treatmentType, .PumpBatteryChange)
        XCTAssertEqual(byID["note-note"]?.notes, "hello")
        XCTAssertTrue(treatments().allSatisfy { $0.uploaded && !$0.treatmentdeleted && $0.date == t })
    }

    func testBasalInjectionNoteCreatesOnlyInjection() async throws {
        let interval = hour()
        let t = interval.start.addingTimeInterval(60)
        let notes = try XCTUnwrap(BasalInjectionPayload(units: 12.5, insulinDescription: "Tresiba")?.encodedNotes())
        let encodedNotes = String(data: try JSONSerialization.data(withJSONObject: [notes]), encoding: .utf8)!.dropFirst().dropLast()
        respondJSON(#"[{"_id":"inj","created_at":"\#(iso(t))","eventType":"note","notes":\#(encodedNotes),"insulin":12.5}]"#)
        let result = try await service.mergeTreatments(in: interval)
        XCTAssertEqual(result.treatmentsAdded, 1)
        let entry = try XCTUnwrap(treatments().first)
        XCTAssertEqual(entry.id, "inj-note")
        XCTAssertEqual(entry.treatmentType, .BasalInjection)
        XCTAssertEqual(entry.value, 12.5)
        XCTAssertEqual(entry.notes, "Tresiba")
    }

    func testUnsupportedTreatmentDocumentsAreCounted() async throws {
        let interval = hour()
        let t = interval.start.addingTimeInterval(60)
        respondJSON("""
        [{"created_at":"\(iso(t))","carbs":10},
         {"_id":"nodate","carbs":10},
         {"_id":"outside","created_at":"\(iso(interval.end))","carbs":10},
         {"_id":"emptyNote","created_at":"\(iso(t))","eventType":"Note","notes":"   "},
         {"_id":"unknown","created_at":"\(iso(t))","eventType":"Announcement"},
         {"_id":"negative","created_at":"\(iso(t))","carbs":-1,"glucose":0}]
        """)
        let result = try await service.mergeTreatments(in: interval)
        XCTAssertEqual(result.documentsUnsupported, 6)
        XCTAssertEqual(result.treatmentsAdded, 0)
        XCTAssertTrue(treatments().isEmpty)
    }

    func testTreatmentMergeSkipsExistingIDsAndFingerprints() async throws {
        let interval = hour()
        let t = interval.start.addingTimeInterval(60)
        let context = coreDataManager.mainManagedObjectContext
        context.performAndWait {
            _ = TreatmentEntry(date: t, value: 20, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
            try? context.save()
        }
        respondJSON("""
        [{"_id":"dup","created_at":"\(iso(t))","carbs":20},
         {"_id":"new","created_at":"\(iso(t))","insulin":1}]
        """)
        let first = try await service.mergeTreatments(in: interval)
        XCTAssertEqual(first.treatmentsAdded, 1)
        XCTAssertEqual(first.treatmentsSkipped, 1)
        let second = try await service.mergeTreatments(in: interval)
        XCTAssertEqual(second.treatmentsAdded, 0)
        XCTAssertEqual(second.treatmentsSkipped, 2)
        XCTAssertEqual(treatments().count, 2)
    }

    func testTreatmentMergeSplitsLongWindowsIntoDailyRequests() async throws {
        respondJSON("[]")
        _ = try await service.mergeTreatments(in: DateInterval(start: now.addingTimeInterval(-2.5 * 86_400), end: now))
        XCTAssertEqual(ImportStubProtocol.requests.count, 3)
    }

    // MARK: - Device status merge

    func testDeviceStatusMergeValidatesDeduplicatesAndPersists() async throws {
        let interval = hour()
        let t1 = interval.start.addingTimeInterval(60)
        let t2 = interval.start.addingTimeInterval(120)
        respondJSON("""
        [{"_id":"s1","created_at":"\(iso(t1))","device":"loop://phone","loop":{"iob":{"iob":1.5}}},
         {"created_at":"\(iso(t2))","pump":{"reservoir":100}},
         {"_id":"s1","created_at":"\(iso(t2))"},
         {"_id":"nodate"},
         {"_id":"outside","created_at":"\(iso(interval.end))"}]
        """)
        let result = try await service.mergeDeviceStatus(in: interval)
        XCTAssertEqual(result.documentsDownloaded, 5)
        XCTAssertEqual(result.documentsInvalid, 3)
        XCTAssertEqual(result.statusesAdded, 2)
        let stored = NightscoutDeviceStatusAccessor(coreDataManager: coreDataManager).fetch(fromDate: nil, toDate: nil)
        XCTAssertEqual(stored.map(\.id), ["s1", "createdAt-\(Int(t2.timeIntervalSince1970 * 1000))"])
        XCTAssertEqual(stored.first?.iob, 1.5)
        XCTAssertEqual(stored.first?.lastCheckedDate, t1)
        XCTAssertEqual(stored.last?.pumpReservoir, 100)

        let again = try await service.mergeDeviceStatus(in: interval)
        XCTAssertEqual(again.statusesAdded, 0)
        XCTAssertEqual(again.statusesSkipped, 2)
    }

    // MARK: - Profile merge

    func testProfileMergeKeepsBaselineAndInWindowProfilesOnly() async throws {
        let interval = hour()
        respondJSON("[" + [
            profileJSON(id: "old", start: interval.start.addingTimeInterval(-7200)),
            profileJSON(id: "baseline", start: interval.start.addingTimeInterval(-60), basal: 1.1),
            profileJSON(id: "inside", start: interval.start.addingTimeInterval(60)),
            profileJSON(id: "future", start: interval.end),
            profileJSON(id: "inside", start: interval.start.addingTimeInterval(120)),
            #"{"_id":"bad","defaultProfile":"x","startDate":"not a date","store":{}}"#
        ].joined(separator: ",") + "]")
        let result = try await service.mergeProfiles(in: interval)
        XCTAssertEqual(ImportStubProtocol.requests.first?.url?.path, "/api/v1/profile")
        XCTAssertEqual(result.documentsDownloaded, 6)
        XCTAssertEqual(result.documentsInvalid, 3)
        XCTAssertEqual(result.profilesAdded, 2)
        let stored = NightscoutProfileAccessor(coreDataManager: coreDataManager).fetch(fromDate: nil, toDate: nil)
        XCTAssertEqual(stored.map(\.id), ["baseline", "inside"])
        XCTAssertEqual(stored.first?.basal.map(\.value), [1.1])
        XCTAssertEqual(stored.first?.isMgDl, true)

        let again = try await service.mergeProfiles(in: interval)
        XCTAssertEqual(again.profilesAdded, 0)
        XCTAssertEqual(again.profilesSkipped, 2)
    }

    // MARK: - Historical import lifecycle

    func testStartRejectsInvalidOptionsBeforeNetwork() async {
        await expectImportError({ _ = try await self.service.start(options: .init(period: .sevenDays, includesBgReadings: false, includesTreatments: false, includesDeviceStatus: false), now: self.now) { _ in } }) { if case .noDataSelected = $0 { return true }; return false }
        await expectImportError({ _ = try await self.service.start(options: .init(period: .init(rawValue: 8), includesBgReadings: true, includesTreatments: false, includesDeviceStatus: false), now: self.now) { _ in } }) { if case .unsupportedPeriod = $0 { return true }; return false }
        UserDefaults.standard.retentionPeriodInDays = 30
        await expectImportError({ _ = try await self.service.start(options: .init(period: .ninetyDays, includesBgReadings: true, includesTreatments: false, includesDeviceStatus: false), now: self.now) { _ in } }) { if case .periodExceedsRetention = $0 { return true }; return false }
        UserDefaults.standard.nightscoutUrl = nil
        await expectImportError({ _ = try await self.service.start(options: .init(period: .sevenDays, includesBgReadings: true, includesTreatments: false, includesDeviceStatus: false), now: self.now) { _ in } }) { if case .missingURL = $0 { return true }; return false }
        XCTAssertTrue(ImportStubProtocol.requests.isEmpty)
        XCTAssertNil(service.savedCheckpoint)
    }

    func testStartRunsEverySelectedPhasePerDayAndClearsCheckpoint() async throws {
        respond { request in
            if request.url!.path.hasSuffix("sgv.json") {
                let gte = Int64(importQuery(request)["find[date][$gte]"]!)!
                return (200, [:], Data(#"[{"_id":"bg\#(gte)","date":\#(gte + 60_000),"sgv":110}]"#.utf8))
            }
            return (200, [:], Data("[]".utf8))
        }
        let recorder = ProgressRecorder()
        let result = try await service.start(options: .init(period: .sevenDays, includesBgReadings: true, includesTreatments: true, includesDeviceStatus: true), now: now) { recorder.append($0) }

        let paths = ImportStubProtocol.requests.map { URL(fileURLWithPath: $0.url!.path).lastPathComponent }
        XCTAssertEqual(paths.count, 21)
        XCTAssertEqual(Array(paths.prefix(3)), ["sgv.json", "treatments.json", "devicestatus.json"])
        XCTAssertEqual(result.requestedTo, now)
        XCTAssertEqual(result.requestedFrom, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(result.siteDisplayName, "ns.coverage.test")
        XCTAssertEqual(result.counts.bgDocumentsDownloaded, 7)
        XCTAssertEqual(result.counts.bgReadingsAdded, 7)
        XCTAssertNil(service.savedCheckpoint)
        XCTAssertEqual(bgReadings().count, 7)

        let progress = recorder.all
        XCTAssertEqual(progress.first?.completedUnits, 0)
        XCTAssertEqual(progress.first?.totalUnits, 21)
        XCTAssertEqual(progress.last?.fractionCompleted, 1)
        XCTAssertEqual(progress.last?.chunkNumber, 7)
        XCTAssertEqual(progress.map(\.completedUnits), progress.map(\.completedUnits).sorted())
    }

    func testFailedImportKeepsCheckpointAndResumeFinishesRemainingDays() async throws {
        var calls = 0
        respond { _ in
            calls += 1
            return calls == 3 ? (404, [:], Data()) : (200, [:], Data("[]".utf8))
        }
        let options = NightscoutImportOptions(period: .sevenDays, includesBgReadings: true, includesTreatments: false, includesDeviceStatus: false)
        await expectImportError({ _ = try await self.service.start(options: options, now: self.now) { _ in } }) { if case .endpointNotFound = $0 { return true }; return false }

        let checkpoint = try XCTUnwrap(service.savedCheckpoint)
        XCTAssertEqual(checkpoint.nextChunkIndex, 2)
        XCTAssertEqual(checkpoint.completedChunks, 2)
        XCTAssertEqual(checkpoint.siteURL, site)

        ImportStubProtocol.reset()
        respondJSON("[]")
        let result = try await service.resume { _ in }
        XCTAssertEqual(ImportStubProtocol.requests.count, 5)
        XCTAssertEqual(result.requestedFrom, checkpoint.requestedFrom)
        XCTAssertNil(service.savedCheckpoint)
    }

    func testResumeRequiresCheckpointAndUnchangedSite() async throws {
        await expectImportError({ _ = try await self.service.resume { _ in } }) { if case .checkpointUnavailable = $0 { return true }; return false }

        respondJSON("[]", status: 401)
        let options = NightscoutImportOptions(period: .sevenDays, includesBgReadings: false, includesTreatments: true, includesDeviceStatus: false)
        await expectImportError({ _ = try await self.service.start(options: options, now: self.now) { _ in } }) { if case .authenticationFailed = $0 { return true }; return false }
        XCTAssertNotNil(service.savedCheckpoint)

        UserDefaults.standard.nightscoutUrl = "https://other.coverage.test"
        await expectImportError({ _ = try await self.service.resume { _ in } }) { if case .checkpointSiteChanged = $0 { return true }; return false }

        UserDefaults.standard.nightscoutUrl = site
        UserDefaults.standard.retentionPeriodInDays = 7
        service.discardCheckpoint()
        XCTAssertNil(service.savedCheckpoint)
    }

    func testResumeRejectsCheckpointBeyondRetention() async throws {
        respondJSON("[]", status: 401)
        let options = NightscoutImportOptions(period: .thirtyDays, includesBgReadings: true, includesTreatments: false, includesDeviceStatus: false)
        await expectImportError({ _ = try await self.service.start(options: options, now: self.now) { _ in } }) { _ in true }
        UserDefaults.standard.retentionPeriodInDays = 7
        await expectImportError({ _ = try await self.service.resume { _ in } }) { if case .periodExceedsRetention = $0 { return true }; return false }
    }

    func testCancelledImportThrowsCancellationAndKeepsCheckpoint() async throws {
        respond { _ in (200, [:], Data("[]".utf8)) }
        let options = NightscoutImportOptions(period: .oneYear, includesBgReadings: true, includesTreatments: false, includesDeviceStatus: false)
        let service = service!
        let now = now
        let task = Task { try await service.start(options: options, now: now) { progress in
            if progress.completedUnits >= 2 { withUnsafeCurrentTask { $0?.cancel() } }
        } }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let checkpoint = try XCTUnwrap(service.savedCheckpoint)
        XCTAssertGreaterThanOrEqual(checkpoint.nextChunkIndex, 2)
        XCTAssertLessThan(checkpoint.nextChunkIndex, 365)
    }
}
