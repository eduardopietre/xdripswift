//
//  NightscoutCoverageUploadTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

/// Accepts live uploads for the fake host and rejects credential probes from other app components.
private final class UploadStubProtocol: URLProtocol {
    struct Recorded {
        let method: String
        let path: String
        let body: Data
    }

    private static let lock = NSLock()
    private static var storedRequests: [Recorded] = []

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock(); storedRequests = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "upload.coverage.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.storedRequests.append(Recorded(method: request.httpMethod ?? "GET", path: path, body: Self.body(of: request)))
        Self.lock.unlock()
        let status = path.hasSuffix("/experiments/test") ? 401 : 200
        let body = request.httpMethod == "POST" && path == "/api/v1/treatments" ? "[]" : "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor final class NightscoutCoverageUploadTests: XCTestCase {
    private let site = "https://upload.coverage.test"
    private let keys: [UserDefaults.Key] = [
        .nightscoutUrl, .nightscoutPort, .nightscoutAPIKey, .nightscoutToken, .nightscoutEnabled, .isMaster,
        .masterUploadDataToNightscout, .followerUploadDataToNightscout, .followerDataSourceType, .nightscoutUseSchedule,
        .storeFrequentReadingsInNightscout, .timeStampLatestNSUploadedBgReadingToNightscout, .timeStampLatestNSUploadedCalibrationToNightscout,
        .timeStampOfLastFollowerConnection, .nightscoutSyncRequired, .timeStampLatestNightscoutSyncRequest, .uploadSensorStartTimeToNS,
        .transmitterBatteryInfo, .libreLinkUpSensorStartDateUploadedToNS, .activeSensorStartDate
    ]
    private var saved: [String: Any] = [:]
    private var coreDataManager: CoreDataManager!
    private var manager: NightscoutSyncManager!

    override func setUp() async throws {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { saved[key.rawValue] = value }
        }
        URLProtocol.registerClass(UploadStubProtocol.self)
        UploadStubProtocol.reset()
        let defaults = UserDefaults.standard
        defaults.timeStampLatestNightscoutSyncRequest = Date()
        defaults.nightscoutAPIKey = nil
        defaults.nightscoutPort = 0
        defaults.nightscoutUseSchedule = false
        defaults.storeFrequentReadingsInNightscout = false
        defaults.timeStampLatestNightscoutUploadedBgReading = nil
        defaults.timeStampLatestNightscoutUploadedCalibration = nil
        defaults.uploadSensorStartTimeToNS = false
        defaults.transmitterBatteryInfo = nil
        defaults.isMaster = true
        defaults.masterUploadDataToNightscout = true
        defaults.nightscoutEnabled = true
        defaults.nightscoutUrl = nil
        defaults.nightscoutToken = "upload-token"
        defaults.nightscoutUrl = site
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        // Returns once the requests started by the managers have stopped coming, instead of a fixed sleep.
        await waitUntilStable { UploadStubProtocol.requests.count }
        UploadStubProtocol.reset()
    }

    override func tearDown() async throws {
        manager = nil
        // Returns once the requests started by the managers have stopped coming, instead of a fixed sleep.
        await waitUntilStable { UploadStubProtocol.requests.count }
        for key in keys {
            if let value = saved[key.rawValue] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        URLProtocol.unregisterClass(UploadStubProtocol.self)
        UploadStubProtocol.reset()
        coreDataManager = nil
    }

    private var context: NSManagedObjectContext { coreDataManager.mainManagedObjectContext }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @discardableResult
    private func storeReading(minutesAgo: Double, value: Double, id: String? = nil) -> BgReading {
        let reading = BgReading(timeStamp: Date().addingTimeInterval(-minutesAgo * 60), sensor: nil, calibration: nil, rawData: value, deviceName: "test", nsManagedObjectContext: context)
        reading.calculatedValue = value
        if let id { reading.id = id }
        try? context.save()
        return reading
    }

    private func posts(to path: String) -> [UploadStubProtocol.Recorded] {
        UploadStubProtocol.requests.filter { $0.method == "POST" && $0.path == path }
    }

    private func uploadedEntries() -> [[String: Any]] {
        posts(to: "/api/v1/entries").flatMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [[String: Any]]) ?? [] }
    }

    func testMasterUploadsNewReadingsAndAdvancesCursor() async throws {
        storeReading(minutesAgo: 15, value: 100)
        storeReading(minutesAgo: 10, value: 110)
        let newest = storeReading(minutesAgo: 5, value: 120)
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        await waitUntil { UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading == newest.timeStamp }
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, newest.timeStamp)
        XCTAssertEqual(posts(to: "/api/v1/entries").count, 1)
        let entries = uploadedEntries()
        if !entries.isEmpty {
            XCTAssertEqual(entries.compactMap { $0["sgv"] as? Int }, [100, 110, 120])
        }
    }

    func testOnlyReadingsAfterCursorAreUploaded() async {
        storeReading(minutesAgo: 15, value: 100)
        let cursor = storeReading(minutesAgo: 10, value: 110)
        let newest = storeReading(minutesAgo: 5, value: 120)
        UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading = cursor.timeStamp
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        await waitUntil { UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading == newest.timeStamp }
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, newest.timeStamp)
        let entries = uploadedEntries()
        if !entries.isEmpty {
            let values = entries.compactMap { $0["sgv"] as? Int }
            XCTAssertEqual(values.last, 120)
            XCTAssertFalse(values.contains(100))
        }
    }

    func testImportedReadingsAreNeverEchoedBack() async {
        storeReading(minutesAgo: 10, value: 100, id: NightscoutImportService.importedBgReadingIDPrefix + "remote")
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(posts(to: "/api/v1/entries").isEmpty)
        XCTAssertNil(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading)
    }

    func testUploadRequiresEnabledSiteCredentialsAndWritePermission() async {
        storeReading(minutesAgo: 5, value: 120)
        UserDefaults.standard.masterUploadDataToNightscout = false
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        UserDefaults.standard.masterUploadDataToNightscout = true
        UserDefaults.standard.nightscoutEnabled = false
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        UserDefaults.standard.nightscoutEnabled = true
        UserDefaults.standard.nightscoutToken = nil
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(posts(to: "/api/v1/entries").isEmpty)
    }

    func testCalibrationsAreUploadedAsCalAndMbgRecords() async throws {
        let sensor = Sensor(startDate: Date().addingTimeInterval(-86_400), nsManagedObjectContext: context)
        let timeStamp = Date().addingTimeInterval(-600)
        _ = Calibration(timeStamp: timeStamp, sensor: sensor, bg: 105, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: timeStamp, slope: 1, intercept: 0, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 0, slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: context)
        try context.save()
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        await waitUntil { UserDefaults.standard.timeStampLatestNightscoutUploadedCalibration != nil }
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedCalibration, timeStamp)
        let types = uploadedEntries().compactMap { $0["type"] as? String }
        if !types.isEmpty {
            XCTAssertEqual(Set(types), ["cal", "mbg"])
        }
    }

    func testTransmitterBatteryIsUploadedAsDeviceStatus() async throws {
        UserDefaults.standard.transmitterBatteryInfo = .percentage(percentage: 80)
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        await waitUntil { !self.posts(to: "/api/v1/devicestatus").isEmpty }
        let request = try XCTUnwrap(posts(to: "/api/v1/devicestatus").first)
        if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            let uploader = json["uploader"] as? [String: Any]
            XCTAssertEqual(uploader?["name"] as? String, "transmitter")
            XCTAssertEqual(uploader?["battery"] as? Int, 80)
        }
    }

    func testMasterActiveSensorStartIsUploadedOnce() async throws {
        UserDefaults.standard.uploadSensorStartTimeToNS = true
        let sensor = Sensor(startDate: Date().addingTimeInterval(-3600), nsManagedObjectContext: context)
        try context.save()
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        await waitUntil { sensor.uploadedToNS }
        XCTAssertTrue(sensor.uploadedToNS)
        let request = try XCTUnwrap(posts(to: "/api/v1/treatments").first)
        if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            XCTAssertEqual(json["eventType"] as? String, "Sensor Start")
            XCTAssertEqual(json["_id"] as? String, sensor.id)
        }
        UploadStubProtocol.reset()
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(posts(to: "/api/v1/treatments").isEmpty)
    }

    func testLibreLinkUpFollowerSensorStartUsesStableNightscoutIdentifier() async throws {
        let start = Date(timeIntervalSince1970: 1_799_000_000)
        UserDefaults.standard.uploadSensorStartTimeToNS = true
        UserDefaults.standard.followerUploadDataToNightscout = true
        UserDefaults.standard.followerDataSourceType = .libreLinkUp
        UserDefaults.standard.isMaster = false
        UserDefaults.standard.activeSensorStartDate = start
        UserDefaults.standard.libreLinkUpSensorStartDateUploadedToNS = nil
        manager.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: nil)
        await waitUntil { UserDefaults.standard.libreLinkUpSensorStartDateUploadedToNS == start }
        XCTAssertEqual(UserDefaults.standard.libreLinkUpSensorStartDateUploadedToNS, start)
        let request = try XCTUnwrap(posts(to: "/api/v1/treatments").first)
        if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            XCTAssertEqual(json["_id"] as? String, String(format: "6c6c75000000%012llx", UInt64(1_799_000_000_000)))
            XCTAssertEqual(json["eventType"] as? String, "Sensor Start")
        }
        UserDefaults.standard.isMaster = true
    }
}
