//
//  NightscoutCoverageSyncManagerTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

/// Records requests the sync manager sends through the shared session to the fake host.
private final class SyncStubProtocol: URLProtocol {
    struct Recorded {
        let method: String
        let url: URL
        let body: Data?
    }

    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, Data))?
    private static var storedRequests: [Recorded] = []

    static var handler: ((URLRequest) -> (Int, Data))? {
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
        request.url?.host == "sync.coverage.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(Recorded(method: request.httpMethod ?? "GET", url: request.url!, body: Self.body(of: request)))
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, data) = handler?(request) ?? (200, Data("{}".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor final class NightscoutCoverageSyncManagerTests: XCTestCase {
    private let site = "https://sync.coverage.test"
    private let keys: [UserDefaults.Key] = [
        .nightscoutUrl, .nightscoutPort, .nightscoutAPIKey, .nightscoutToken, .nightscoutEnabled, .isMaster,
        .masterUploadDataToNightscout, .followerUploadDataToNightscout, .followerDataSourceType, .therapyDataSourceType,
        .storeFrequentReadingsInNightscout, .timeStampLatestNSUploadedBgReadingToNightscout, .timeStampOfLastFollowerConnection,
        .nightscoutSyncRequired, .timeStampLatestNightscoutSyncRequest
    ]
    private var saved: [String: Any] = [:]
    private var coreDataManager: CoreDataManager!
    private var manager: NightscoutSyncManager!

    override func setUp() async throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { saved[key.rawValue] = value }
        }
        URLProtocol.registerClass(SyncStubProtocol.self)
        SyncStubProtocol.reset()
        let defaults = UserDefaults.standard
        defaults.timeStampLatestNightscoutSyncRequest = Date()
        defaults.nightscoutAPIKey = nil
        defaults.nightscoutToken = nil
        defaults.nightscoutPort = 0
        defaults.storeFrequentReadingsInNightscout = false
        defaults.timeStampLatestNightscoutUploadedBgReading = nil
        defaults.isMaster = true
        defaults.masterUploadDataToNightscout = true
        defaults.nightscoutUrl = site
        defaults.nightscoutEnabled = true
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
    }

    override func tearDown() async throws {
        manager = nil
        try? await Task.sleep(nanoseconds: 200_000_000)
        for key in keys {
            if let value = saved[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        URLProtocol.unregisterClass(SyncStubProtocol.self)
        SyncStubProtocol.reset()
        coreDataManager = nil
    }

    private var context: NSManagedObjectContext { coreDataManager.mainManagedObjectContext }

    private func reading(at timeStamp: Date, value: Double = 120) -> BgReading {
        let reading = BgReading(timeStamp: timeStamp, sensor: nil, calibration: nil, rawData: value, deviceName: "test", nsManagedObjectContext: context)
        reading.calculatedValue = value
        return reading
    }

    @discardableResult
    private func treatment(id: String, minutesAgo: Double, type: TreatmentType = .Carbs, uploaded: Bool = true, value: Double = 10) -> TreatmentEntry {
        TreatmentEntry(id: id, date: Date().addingTimeInterval(-minutesAgo * 60), value: value, treatmentType: type, uploaded: uploaded, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func millis(_ date: Date) -> String { String(date.toMillisecondsAsInt64()) }

    private func queryValues(_ url: URL, _ name: String) -> [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name == name }.compactMap(\.value)
    }

    // MARK: - Write gate

    func testBgWriteGateFollowsDataFlowPolicy() {
        XCTAssertTrue(manager.shouldAllowNightscoutBgWrites())
        XCTAssertTrue(manager.shouldAllowNightscoutBgPostProcessingWrites())
        UserDefaults.standard.masterUploadDataToNightscout = false
        XCTAssertFalse(manager.shouldAllowNightscoutBgWrites())
        UserDefaults.standard.masterUploadDataToNightscout = true
        UserDefaults.standard.isMaster = false
        UserDefaults.standard.followerDataSourceType = .nightscout
        UserDefaults.standard.followerUploadDataToNightscout = true
        XCTAssertFalse(manager.shouldAllowNightscoutBgWrites())
        UserDefaults.standard.followerDataSourceType = .dexcomShare
        XCTAssertTrue(manager.shouldAllowNightscoutBgPostProcessingWrites())
        UserDefaults.standard.isMaster = true
    }

    func testInitialPublishedStatusIsUncheckedAndEmpty() {
        XCTAssertEqual(manager.deviceStatus.lastCheckedDate, .distantPast)
        XCTAssertEqual(manager.deviceStatus.updatedDate, .distantPast)
        XCTAssertFalse(manager.deviceStatus.hasData())
    }

    // MARK: - Historical BG replacement

    func testReplacementDeletesExactTimestampsThenUploadsWithoutIDsAndMovesHandoff() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = reading(at: t0)
        let second = reading(at: t0.addingTimeInterval(300), value: 130)
        let hidden = reading(at: t0.addingTimeInterval(-600))
        manager.replaceBgReadingsInNightscout(bgReadings: [second, first], bgReadingsToDelete: [hidden, hidden])

        let expectedHandoff = t0.addingTimeInterval(300 - ConstantsNightscout.minimiumTimeBetweenTwoReadingsInMinutes * 60)
        await waitUntil { UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading == expectedHandoff }
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, expectedHandoff)

        let requests = SyncStubProtocol.requests
        XCTAssertEqual(requests.map(\.method), ["DELETE", "POST"])
        XCTAssertEqual(requests[0].url.path, "/api/v1/entries.json")
        XCTAssertEqual(queryValues(requests[0].url, "find[type]"), ["sgv"])
        XCTAssertEqual(queryValues(requests[0].url, "find[date][$in][]"), [millis(hidden.timeStamp)])
        XCTAssertEqual(requests[1].url.path, "/api/v1/entries")
        let body = try XCTUnwrap(requests[1].body)
        let uploaded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(uploaded.compactMap { $0["sgv"] as? Int }.sorted(), [120, 130])
        XCTAssertTrue(uploaded.allSatisfy { $0["_id"] == nil })
    }

    func testReplacementHandoffNeverMovesBackwards() async {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let later = t0.addingTimeInterval(3600)
        UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading = later
        manager.replaceBgReadingsInNightscout(bgReadings: [reading(at: t0)])
        await waitUntil { SyncStubProtocol.requests.contains { $0.method == "POST" } }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, later)
    }

    func testFrequentUploadsUseShorterHandoff() async {
        UserDefaults.standard.storeFrequentReadingsInNightscout = true
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        manager.replaceBgReadingsInNightscout(bgReadings: [reading(at: t0)])
        let expected = t0.addingTimeInterval(-ConstantsNightscout.minimiumTimeBetweenTwoReadingsInMinutesFrequentUploads * 60)
        await waitUntil { UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading == expected }
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, expected)
    }

    func testFailedReplacementUploadDoesNotMoveHandoff() async {
        SyncStubProtocol.handler = { request in request.httpMethod == "POST" ? (500, Data(#"{"description":{"code":11000}}"#.utf8)) : (200, Data("{}".utf8)) }
        manager.replaceBgReadingsInNightscout(bgReadings: [reading(at: Date(timeIntervalSince1970: 1_800_000_000))])
        await waitUntil { SyncStubProtocol.requests.contains { $0.method == "POST" } }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading)
    }

    func testDuplicateKeyErrorSixtySixCountsAsSuccess() async {
        SyncStubProtocol.handler = { request in request.httpMethod == "POST" ? (500, Data(#"{"description":{"code":66}}"#.utf8)) : (200, Data("{}".utf8)) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        manager.replaceBgReadingsInNightscout(bgReadings: [reading(at: t0)])
        let expected = t0.addingTimeInterval(-ConstantsNightscout.minimiumTimeBetweenTwoReadingsInMinutes * 60)
        await waitUntil { UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading == expected }
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, expected)
        XCTAssertNotNil(UserDefaults.standard.timeStampOfLastFollowerConnection)
    }

    func testReplacementIsSkippedWhenWritesAreNotAllowedOrNothingToDo() async {
        manager.replaceBgReadingsInNightscout(bgReadings: [], bgReadingsToDelete: [])
        UserDefaults.standard.masterUploadDataToNightscout = false
        manager.replaceBgReadingsInNightscout(bgReadings: [reading(at: Date())])
        manager.deleteBgReadingFromNightscout(timeStampOfBgReadingToDelete: Date())
        UserDefaults.standard.masterUploadDataToNightscout = true
        UserDefaults.standard.nightscoutEnabled = false
        manager.replaceBgReadingsInNightscout(bgReadings: [reading(at: Date())])
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(SyncStubProtocol.requests.isEmpty)
    }

    func testTokenAndPortAreAppliedToReplacementRequests() async throws {
        UserDefaults.standard.nightscoutPort = 8443
        UserDefaults.standard.nightscoutToken = "abc"
        manager.replaceBgReadingsInNightscout(bgReadings: [reading(at: Date(timeIntervalSince1970: 1_800_000_000))], bgReadingsToDelete: [reading(at: Date(timeIntervalSince1970: 1_799_999_000))])
        let entryRequests = { SyncStubProtocol.requests.filter { $0.url.path.hasPrefix("/api/v1/entries") } }
        await waitUntil { entryRequests().count >= 2 }
        let requests = entryRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url.port, 8443)
            XCTAssertEqual(queryValues(request.url, "token"), ["abc"])
        }
    }

    func testDeleteSingleReadingUsesHalfCadenceWindow() async throws {
        let timeStamp = Date(timeIntervalSince1970: 1_800_000_000)
        SyncStubProtocol.handler = { _ in (200, Data(#"{"result":{"n":1}}"#.utf8)) }
        manager.deleteBgReadingFromNightscout(timeStampOfBgReadingToDelete: timeStamp)
        await waitUntil { !SyncStubProtocol.requests.isEmpty }
        let request = try XCTUnwrap(SyncStubProtocol.requests.first)
        let half = ConstantsNightscout.minimiumTimeBetweenTwoReadingsInMinutes * 60 / 2
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(queryValues(request.url, "find[type]"), ["sgv"])
        XCTAssertEqual(queryValues(request.url, "find[date][$gte]"), [millis(timeStamp.addingTimeInterval(-half))])
        XCTAssertEqual(queryValues(request.url, "find[date][$lte]"), [millis(timeStamp.addingTimeInterval(half))])
    }

    func testLargeDeletionIsChunkedByFiftyTimestamps() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let hidden = (0..<120).map { reading(at: base.addingTimeInterval(Double($0) * 60)) }
        manager.replaceBgReadingsInNightscout(bgReadings: [], bgReadingsToDelete: hidden)
        await waitUntil { SyncStubProtocol.requests.count >= 3 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let counts = SyncStubProtocol.requests.map { queryValues($0.url, "find[date][$in][]").count }
        XCTAssertEqual(counts, [50, 50, 20])
        XCTAssertNil(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading)
    }

    // MARK: - Remote deletion reconciliation

    func testReconcileHidesOnlyConfirmedRemoteDeletions() {
        let present = treatment(id: "present-carbs", minutesAgo: 10)
        let goneCarbs = treatment(id: "gone-carbs", minutesAgo: 20)
        let goneInsulin = treatment(id: "gone-insulin", minutesAgo: 20, type: .Insulin)
        let stillThere = treatment(id: "kept-carbs", minutesAgo: 30)
        let failed = treatment(id: "failed-carbs", minutesAgo: 40)
        let old = treatment(id: "old-carbs", minutesAgo: 60 * (ConstantsNightscout.maxHoursTreatmentsToDownload + 1))
        let notUploaded = treatment(id: "pending-carbs", minutesAgo: 5, uploaded: false)
        let empty = treatment(id: TreatmentEntry.EmptyId, minutesAgo: 5)
        let alreadyDeleted = treatment(id: "deleted-carbs", minutesAgo: 5)
        alreadyDeleted.treatmentdeleted = true
        let all = [present, goneCarbs, goneInsulin, stillThere, failed, old, notUploaded, empty, alreadyDeleted]
        let downloaded = TreatmentNSResponse.fromNightscout(dictionary: ["_id": "present", "created_at": ISO8601DateFormatter.withFractionalSeconds.string(from: present.date), "carbs": 10.0] as NSDictionary)

        var lookedUp: [String] = []
        var deletedCount: Int?
        manager.reconcileRemoteTreatmentDeletions(treatments: all, downloaded: downloaded, lookup: { id, completion in
            lookedUp.append(id)
            switch id {
            case "gone": completion(Data("[]".utf8), true)
            case "kept": completion(Data(#"[{"_id":"kept"}]"#.utf8), true)
            default: completion(nil, false)
            }
        }, completion: { deletedCount = $0 })

        XCTAssertEqual(lookedUp, ["failed", "gone", "kept"])
        XCTAssertEqual(deletedCount, 2)
        XCTAssertTrue(goneCarbs.treatmentdeleted)
        XCTAssertTrue(goneInsulin.treatmentdeleted)
        XCTAssertTrue(goneCarbs.uploaded)
        XCTAssertFalse(present.treatmentdeleted)
        XCTAssertFalse(stillThere.treatmentdeleted)
        XCTAssertFalse(failed.treatmentdeleted)
        XCTAssertFalse(old.treatmentdeleted)
        XCTAssertFalse(notUploaded.treatmentdeleted)
    }

    func testReconcileSkipsTreatmentsEditedWhileLookupRuns() {
        let edited = treatment(id: "remote-carbs", minutesAgo: 10)
        var deletedCount: Int?
        manager.reconcileRemoteTreatmentDeletions(treatments: [edited], downloaded: [], lookup: { _, completion in
            edited.uploaded = false
            completion(Data("[]".utf8), true)
        }, completion: { deletedCount = $0 })
        XCTAssertEqual(deletedCount, 0)
        XCTAssertFalse(edited.treatmentdeleted)
    }

    func testReconcileWithNoCandidatesCompletesImmediately() {
        var deletedCount: Int?
        manager.reconcileRemoteTreatmentDeletions(treatments: [], downloaded: [], lookup: { _, _ in XCTFail("no lookup expected") }, completion: { deletedCount = $0 })
        XCTAssertEqual(deletedCount, 0)
    }

    // MARK: - Downloaded treatment creation

    private func responses(_ dictionaries: [[String: Any]]) -> [TreatmentNSResponse] {
        dictionaries.flatMap { TreatmentNSResponse.fromNightscout(dictionary: $0 as NSDictionary) }
    }

    func testNewTreatmentsAreCreatedOnlyForUnknownIDs() async throws {
        UserDefaults.standard.therapyDataSourceType = .nightscout
        let created = ISO8601DateFormatter.withFractionalSeconds.string(from: Date())
        treatment(id: "known-carbs", minutesAgo: 1)
        try context.save()
        let downloaded = responses([
            ["_id": "known", "created_at": created, "carbs": 10.0],
            ["_id": "meal", "created_at": created, "carbs": 30.0, "insulin": 2.0],
            ["_id": "meal", "created_at": created, "carbs": 30.0]
        ])
        let count = try await manager.newTreatmentsIfRequired(treatmentNSResponses: downloaded)
        XCTAssertEqual(count, 2)
        let ids = context.insertedObjects.compactMap { ($0 as? TreatmentEntry)?.id }.sorted()
        XCTAssertEqual(ids, ["meal-carbs", "meal-insulin"])

        let again = try await manager.newTreatmentsIfRequired(treatmentNSResponses: downloaded)
        XCTAssertEqual(again, 0)
    }

    func testPendingUnsavedTreatmentPreventsDuplicateCreation() async throws {
        UserDefaults.standard.therapyDataSourceType = .nightscout
        treatment(id: "pending-carbs", minutesAgo: 1)
        let downloaded = responses([["_id": "pending", "created_at": ISO8601DateFormatter.withFractionalSeconds.string(from: Date()), "carbs": 10.0]])
        let count = try await manager.newTreatmentsIfRequired(treatmentNSResponses: downloaded)
        XCTAssertEqual(count, 0)
    }

    func testResponseFromPreviousSourceIsRejected() async {
        UserDefaults.standard.therapyDataSourceType = .nightscout
        let downloaded = responses([["_id": "x", "created_at": ISO8601DateFormatter.withFractionalSeconds.string(from: Date()), "carbs": 1.0]])
        do {
            _ = try await manager.newTreatmentsIfRequired(treatmentNSResponses: downloaded, sourceURL: "https://old.coverage.test", sourcePort: 0)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            UserDefaults.standard.therapyDataSourceType = .none
            _ = try await manager.newTreatmentsIfRequired(treatmentNSResponses: downloaded)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(context.insertedObjects.isEmpty)
    }

    // MARK: - Post-processing notes

    func testPostProcessingNotesDeleteRemoteNotesAndUploadReplacement() async {
        UserDefaults.standard.nightscoutAPIKey = "secret"
        let remote = TreatmentEntry(id: "old-note", date: Date(), value: 0, treatmentType: .Note, uploaded: true, nightscoutEventType: "Note", enteredBy: nil, notes: "old", nsManagedObjectContext: context)
        let local = TreatmentEntry(date: Date(), value: 0, treatmentType: .Note, nightscoutEventType: "Note", enteredBy: nil, notes: "local only", nsManagedObjectContext: context)
        let replacement = TreatmentEntry(date: Date(), value: 0, treatmentType: .Note, nightscoutEventType: "Note", enteredBy: nil, notes: "new", nsManagedObjectContext: context)
        SyncStubProtocol.handler = { request in
            request.httpMethod == "POST" ? (200, Data(#"[{"_id":"new-id","created_at":"2026-01-01T00:00:00.000Z","eventType":"Note","notes":"new"}]"#.utf8)) : (200, Data("{}".utf8))
        }
        manager.replacePostProcessingNotesInNightscout(notesToDelete: [remote, local], noteToUpload: replacement)
        let treatmentRequests = { SyncStubProtocol.requests.filter { $0.url.path.hasPrefix("/api/v1/treatments") } }
        await waitUntil { treatmentRequests().contains { $0.method == "POST" } }
        XCTAssertEqual(treatmentRequests().map(\.method), ["DELETE", "POST"])
        XCTAssertEqual(treatmentRequests().first?.url.path, "/api/v1/treatments/old")
        XCTAssertTrue(local.uploaded)
    }

    func testPostProcessingNotesRequireCredentials() async {
        let replacement = TreatmentEntry(date: Date(), value: 0, treatmentType: .Note, nightscoutEventType: "Note", enteredBy: nil, notes: "new", nsManagedObjectContext: context)
        manager.replacePostProcessingNotesInNightscout(notesToDelete: [], noteToUpload: replacement)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(SyncStubProtocol.requests.isEmpty)
    }
}
