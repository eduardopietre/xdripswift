//
//  NightscoutCoverageSyncFlowTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

/// Plays the role of a Nightscout server for one complete treatment, profile and device-status sync.
private final class SyncFlowStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, String))?
    private static var storedRequests: [(method: String, url: URL)] = []

    static var handler: ((URLRequest) -> (Int, String))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }

    static var requests: [(method: String, url: URL)] {
        lock.lock(); defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock(); storedHandler = nil; storedRequests = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "syncflow.coverage.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append((request.httpMethod ?? "GET", request.url!))
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, body) = handler?(request) ?? (200, "[]")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor final class NightscoutCoverageSyncFlowTests: XCTestCase {
    private let site = "https://syncflow.coverage.test"
    private let keys: [UserDefaults.Key] = [
        .nightscoutUrl, .nightscoutPort, .nightscoutAPIKey, .nightscoutToken, .nightscoutEnabled, .isMaster,
        .masterUploadDataToNightscout, .therapyDataSourceType, .nightscoutFollowType, .nightscoutProfile,
        .nightscoutTreatmentsUpdateCounter, .timeStampOfLastFollowerConnection, .nightscoutSyncRequired,
        .timeStampLatestNightscoutSyncRequest
    ]
    private var saved: [String: Any] = [:]
    private var coreDataManager: CoreDataManager!

    override func setUp() async throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { saved[key.rawValue] = value }
        }
        URLProtocol.registerClass(SyncFlowStubProtocol.self)
        SyncFlowStubProtocol.reset()
        let defaults = UserDefaults.standard
        defaults.timeStampLatestNightscoutSyncRequest = Date()
        defaults.nightscoutAPIKey = nil
        defaults.nightscoutToken = nil
        defaults.nightscoutPort = 0
        defaults.isMaster = true
        defaults.masterUploadDataToNightscout = false
        defaults.nightscoutUrl = site
        defaults.nightscoutEnabled = true
        defaults.therapyDataSourceType = .nightscout
        defaults.nightscoutFollowType = .loop
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    }

    override func tearDown() async throws {
        // Returns once the requests started by the managers have stopped coming, instead of a fixed sleep.
        await waitUntilStable { SyncFlowStubProtocol.requests.count }
        for key in keys {
            if let value = saved[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        URLProtocol.unregisterClass(SyncFlowStubProtocol.self)
        SyncFlowStubProtocol.reset()
        coreDataManager = nil
    }

    private var context: NSManagedObjectContext { coreDataManager.mainManagedObjectContext }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter.withFractionalSeconds.string(from: date) }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func treatments() -> [String: TreatmentEntry] {
        let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
        let all = (try? context.fetch(request)) ?? []
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func testFullSyncUploadsUpdatesDeletesDownloadsAndRefreshesStatusAndProfile() async throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let t1 = now.addingTimeInterval(-1800)
        let t2 = now.addingTimeInterval(-3600)
        let t3 = now.addingTimeInterval(-5400)

        let newLocal = TreatmentEntry(date: t1, value: 15, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let edited = TreatmentEntry(id: "edit-insulin", date: t2, value: 3, treatmentType: .Insulin, uploaded: false, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let deleted = TreatmentEntry(id: "del-carbs", date: t2, value: 5, treatmentType: .Carbs, uploaded: false, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        deleted.treatmentdeleted = true
        let changedRemotely = TreatmentEntry(id: "keep-carbs", date: t3, value: 10, treatmentType: .Carbs, uploaded: true, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        let goneRemotely = TreatmentEntry(id: "gone-carbs", date: t3, value: 20, treatmentType: .Carbs, uploaded: true, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        try context.save()

        let profileStart = now.addingTimeInterval(-86_400)
        let statusTime = now.addingTimeInterval(-60)
        let download = """
        [{"_id":"keep","created_at":"\(iso(t3))","carbs":12},
         {"_id":"remote","created_at":"\(iso(t2))","carbs":40,"eventType":"Meal Bolus","enteredBy":"Loop"},
         {"_id":"srv1","created_at":"\(iso(t1))","carbs":15},
         {"_id":"edit","created_at":"\(iso(t2))","insulin":3}]
        """
        let profile = """
        [{"_id":"prof","defaultProfile":"Default","startDate":"\(iso(profileStart))","store":{"Default":{
        "basal":[{"time":"00:00","value":0.85,"timeAsSeconds":0}],"carbratio":[{"time":"00:00","value":10,"timeAsSeconds":0}],
        "sens":[{"time":"00:00","value":45,"timeAsSeconds":0}],"target_low":[{"time":"00:00","value":90,"timeAsSeconds":0}],
        "target_high":[{"time":"00:00","value":120,"timeAsSeconds":0}],"timezone":"UTC","dia":6,"units":"mg/dl"}}}]
        """
        let status = """
        [{"_id":"ds1","created_at":"\(iso(statusTime))","device":"loop://iPhone","loop":{"iob":{"iob":1.5},"cob":{"cob":12},
        "timestamp":"\(iso(statusTime))","enacted":{"rate":0.9,"duration":30,"timestamp":"\(iso(statusTime))"}},
        "uploader":{"battery":55,"timestamp":"\(iso(statusTime))"},"pump":{"battery":{"percent":70},"clock":"\(iso(statusTime))","reservoir":120}},
        {"_id":"ds0","created_at":"\(iso(statusTime.addingTimeInterval(-300)))","device":"loop://iPhone","override":{"active":true,"name":"Run"}}]
        """
        SyncFlowStubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch (method, path) {
            case ("GET", "/api/v1/profile"):
                return (200, profile)
            case ("GET", "/api/v1/devicestatus"):
                return (200, status)
            case ("POST", "/api/v1/treatments"):
                return (200, #"[{"_id":"srv1","created_at":"\#(ISO8601DateFormatter.withFractionalSeconds.string(from: t1))","carbs":15}]"#)
            case ("GET", "/api/v1/treatments"):
                if let id = query.first(where: { $0.name == "find[_id]" })?.value {
                    return (200, id == "gone" ? "[]" : #"[{"_id":"\#(id)"}]"#)
                }
                return (200, download)
            default:
                return (200, "{}")
            }
        }

        let counter = UserDefaults.standard.nightscoutTreatmentsUpdateCounter
        let manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        manager.syncAllWithNightscout()
        await waitUntil {
            newLocal.uploaded && edited.uploaded && deleted.uploaded && changedRemotely.value == 12 && goneRemotely.treatmentdeleted
                && self.treatments()["remote-carbs"] != nil && manager.profile.id == "prof" && manager.deviceStatus.iob != nil
                && UserDefaults.standard.nightscoutTreatmentsUpdateCounter > counter
        }

        XCTAssertGreaterThan(UserDefaults.standard.nightscoutTreatmentsUpdateCounter, counter)
        XCTAssertTrue(newLocal.uploaded)
        XCTAssertEqual(newLocal.id, "srv1-carbs")
        XCTAssertTrue(edited.uploaded)
        XCTAssertTrue(deleted.uploaded)
        XCTAssertEqual(changedRemotely.value, 12)
        XCTAssertTrue(goneRemotely.treatmentdeleted)
        XCTAssertFalse(changedRemotely.treatmentdeleted)
        let created = try XCTUnwrap(treatments()["remote-carbs"])
        XCTAssertEqual(created.value, 40)
        XCTAssertEqual(created.nightscoutEventType, "Meal Bolus")
        XCTAssertTrue(created.uploaded)

        XCTAssertEqual(manager.profile.basal?.first?.value, 0.85)
        XCTAssertNotNil(UserDefaults.standard.nightscoutProfile)
        XCTAssertEqual(NightscoutProfileAccessor(coreDataManager: coreDataManager).latest()?.id, "prof")

        let deviceStatus = manager.deviceStatus
        XCTAssertEqual(deviceStatus.id, "ds1")
        XCTAssertEqual(deviceStatus.iob, 1.5)
        XCTAssertEqual(deviceStatus.cob, 12)
        XCTAssertEqual(deviceStatus.rate, 0.9)
        XCTAssertEqual(deviceStatus.duration, 30)
        XCTAssertEqual(deviceStatus.uploaderBatteryPercent, 55)
        XCTAssertEqual(deviceStatus.pumpBatteryPercent, 70)
        XCTAssertEqual(deviceStatus.overrideName, "Run")
        XCTAssertEqual(deviceStatus.lastLoopDate, statusTime)
        XCTAssertNotEqual(deviceStatus.lastCheckedDate, .distantPast)
        await waitUntil { NightscoutDeviceStatusAccessor(coreDataManager: self.coreDataManager).latest() != nil }
        XCTAssertEqual(NightscoutDeviceStatusAccessor(coreDataManager: coreDataManager).latest()?.id, "ds1")

        let methods = SyncFlowStubProtocol.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertTrue(methods.contains("PUT /api/v1/treatments"))
        XCTAssertTrue(methods.contains("DELETE /api/v1/treatments/del"))
    }

    func testStatusAndProfileAreNotRequestedWithoutAIDFollowType() async {
        UserDefaults.standard.nightscoutFollowType = .none
        SyncFlowStubProtocol.handler = { request in
            request.url?.path == "/api/v1/treatments" ? (200, "[]") : (500, "")
        }
        let manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        manager.syncAllWithNightscout()
        await waitUntil(timeout: 2) { SyncFlowStubProtocol.requests.contains { $0.url.path == "/api/v1/treatments" } }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(manager.deviceStatus.lastCheckedDate, .distantPast)
        XCTAssertFalse(manager.profile.hasData())
    }

    func testFailedDeviceStatusRequestStillMarksStatusAsChecked() async {
        SyncFlowStubProtocol.handler = { _ in (503, "") }
        let manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        manager.syncAllWithNightscout()
        await waitUntil { manager.deviceStatus.lastCheckedDate != .distantPast }
        XCTAssertNotEqual(manager.deviceStatus.lastCheckedDate, .distantPast)
        XCTAssertNil(manager.deviceStatus.iob)
        XCTAssertFalse(manager.profile.hasData())
    }
}
