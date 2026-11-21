//
//  NightscoutCoverageModelTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

@MainActor final class NightscoutCoverageModelTests: XCTestCase {
    private var coreDataManager: CoreDataManager!

    override func setUp() async throws {
        coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    }

    override func tearDown() async throws {
        coreDataManager = nil
    }

    private var context: NSManagedObjectContext { coreDataManager.mainManagedObjectContext }

    private func profileResponse(_ json: String) throws -> NightscoutProfileResponse {
        try JSONDecoder().decode(NightscoutProfileResponse.self, from: Data(json.utf8))
    }

    private func storeJSON(units: String = "mg/dl", basal: Double = 0.7) -> String {
        """
        {"basal":[{"time":"00:00","value":\(basal),"timeAsSeconds":0},{"time":"06:00","value":1.0,"timeAsSeconds":21600}],
        "carbratio":[{"time":"00:00","value":12,"timeAsSeconds":0}],"sens":[{"time":"00:00","value":50,"timeAsSeconds":0}],
        "target_low":[{"time":"00:00","value":95,"timeAsSeconds":0}],"target_high":[{"time":"00:00","value":115,"timeAsSeconds":0}],
        "timezone":"Europe/Brussels","dia":5.5,"units":"\(units)"}
        """
    }

    // MARK: - Profile models

    func testProfileFromResponseUsesDefaultStore() throws {
        let response = try profileResponse("""
        {"_id":"p1","defaultProfile":"Work","startDate":"2026-03-01T08:00:00.000Z","enteredBy":"Trio","units":"mg/dl",
        "store":{"Home":\(storeJSON(basal: 0.2)),"Work":\(storeJSON(basal: 0.9))}}
        """)
        let before = Date()
        let profile = NightscoutProfile(from: response)
        XCTAssertEqual(profile.id, "p1")
        XCTAssertEqual(profile.profileName, "Work")
        XCTAssertEqual(profile.enteredBy, "Trio")
        XCTAssertEqual(profile.startDate, ISO8601DateFormatter.withFractionalSeconds.date(from: "2026-03-01T08:00:00.000Z"))
        XCTAssertEqual(profile.createdAt, profile.startDate)
        XCTAssertGreaterThanOrEqual(profile.updatedDate, before)
        XCTAssertTrue(profile.hasData())
        XCTAssertEqual(profile.basal?.map(\.value), [0.9, 1.0])
        XCTAssertEqual(profile.basal?.map(\.timeAsSecondsFromMidnight), [0, 21600])
        XCTAssertEqual(profile.carbratio?.first?.value, 12)
        XCTAssertEqual(profile.sensitivity?.first?.value, 50)
        XCTAssertEqual(profile.targetLow?.first?.value, 95)
        XCTAssertEqual(profile.targetHigh?.first?.value, 115)
        XCTAssertEqual(profile.timezone, "Europe/Brussels")
        XCTAssertEqual(profile.dia, 5.5)
        XCTAssertEqual(profile.isMgDl, true)
    }

    func testProfileFallsBackToAnyStoreAndDetectsMmol() throws {
        let response = try profileResponse("""
        {"_id":"p2","defaultProfile":"Missing","startDate":"2026-03-01T08:00:00Z","store":{"Only":\(storeJSON(units: "mmol"))}}
        """)
        let profile = NightscoutProfile(from: response)
        XCTAssertEqual(profile.isMgDl, false)
        XCTAssertEqual(profile.basal?.first?.value, 0.7)
        XCTAssertNil(profile.enteredBy)
        XCTAssertEqual(profile.startDate, ISO8601DateFormatter.withoutFractionalSeconds.date(from: "2026-03-01T08:00:00Z"))
    }

    func testProfileWithEmptyStoreAndInvalidDateHasNoSchedules() throws {
        let profile = NightscoutProfile(from: try profileResponse(#"{"_id":"p3","defaultProfile":"x","startDate":"soon","store":{}}"#))
        XCTAssertEqual(profile.startDate, .distantPast)
        XCTAssertNil(profile.basal)
        XCTAssertNil(profile.isMgDl)
    }

    func testProfileResponseRequiresScheduleFields() {
        XCTAssertThrowsError(try profileResponse(#"{"_id":"p","defaultProfile":"x","startDate":"s","store":{"x":{"basal":[]}}}"#))
        XCTAssertThrowsError(try profileResponse(#"{"defaultProfile":"x","startDate":"s","store":{}}"#))
    }

    func testTimeValueOffsetsFromGivenDateAndProfileDefaults() throws {
        let midnight = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(NightscoutProfile.TimeValue(timeAsSecondsFromMidnight: 5400, value: 1).toDate(date: midnight), midnight.addingTimeInterval(5400))
        let empty = NightscoutProfile()
        XCTAssertFalse(empty.hasData())
        XCTAssertEqual(empty.id, "")
        let decoded = try JSONDecoder().decode(NightscoutProfile.self, from: JSONEncoder().encode(NightscoutProfile(from: try profileResponse("""
        {"_id":"p","defaultProfile":"a","startDate":"2026-03-01T08:00:00Z","store":{"a":\(storeJSON())}}
        """))))
        XCTAssertEqual(decoded.id, "p")
        XCTAssertEqual(decoded.basal?.count, 2)
    }

    // MARK: - Follow type

    func testFollowTypeListRowsAndDescriptions() {
        XCTAssertEqual(NightscoutFollowType.allCasesForList, [.none, .loop, .openAPS])
        XCTAssertEqual(NightscoutFollowType(forRowAt: 0), NightscoutFollowType.none)
        XCTAssertEqual(NightscoutFollowType(forRowAt: 1), .loop)
        XCTAssertEqual(NightscoutFollowType(forRowAt: 2), .openAPS)
        XCTAssertEqual(Set(NightscoutFollowType.allCases.map(\.description)).count, 3)
        XCTAssertEqual(Set(NightscoutFollowType.allCases.map(\.descriptionExpanded)).count, 3)
        XCTAssertEqual(try JSONDecoder().decode(NightscoutFollowType.self, from: Data("2".utf8)), .openAPS)
    }

    // MARK: - Endpoint

    func testLatestEntriesEndpointBuildsQueryAndToken() throws {
        let savedPort = UserDefaults.standard.object(forKey: UserDefaults.Key.nightscoutPort.rawValue)
        defer { UserDefaults.standard.set(savedPort, forKey: UserDefaults.Key.nightscoutPort.rawValue) }
        UserDefaults.standard.nightscoutPort = 0
        let minimum = Date(timeIntervalSince1970: 1_700_000_000.5)
        let endpoint = try XCTUnwrap(Endpoint.getEndpointForLatestNSEntries(hostAndScheme: "https://ns.example.com", count: 12, minimumTimeStamp: minimum, token: "tok"))
        XCTAssertEqual(endpoint.host, "ns.example.com")
        XCTAssertEqual(endpoint.scheme, .https)
        XCTAssertEqual(endpoint.path, "/api/v1/entries/sgv.json")
        let url = try XCTUnwrap(endpoint.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertNil(url.port)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "count", value: "12"),
            URLQueryItem(name: "find[date][$gte]", value: "1700000000500"),
            URLQueryItem(name: "token", value: "tok")
        ])

        UserDefaults.standard.nightscoutPort = 1337
        let withPort = try XCTUnwrap(Endpoint.getEndpointForLatestNSEntries(hostAndScheme: "HTTP://ns.example.com", count: 1, minimumTimeStamp: minimum, token: nil))
        XCTAssertEqual(withPort.scheme, .http)
        XCTAssertEqual(withPort.url?.port, 1337)
        XCTAssertNil(URLComponents(url: withPort.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" })
    }

    func testLatestEntriesEndpointWithoutSchemeClearsStoredURL() {
        let saved = UserDefaults.standard.nightscoutUrl
        defer { UserDefaults.standard.nightscoutUrl = saved }
        UserDefaults.standard.nightscoutUrl = "ns.example.com"
        XCTAssertNil(Endpoint.getEndpointForLatestNSEntries(hostAndScheme: "ns.example.com", count: 1, minimumTimeStamp: Date(), token: nil))
        XCTAssertNil(UserDefaults.standard.nightscoutUrl)
    }

    func testHostAndSchemeSplitting() {
        XCTAssertEqual(EndPointScheme.getHostAndScheme(hostAndScheme: "https://a.b").0, "a.b")
        XCTAssertEqual(EndPointScheme.getHostAndScheme(hostAndScheme: "http://a.b").1, .http)
        XCTAssertNil(EndPointScheme.getHostAndScheme(hostAndScheme: "a.b").1)
    }

    // MARK: - Lightweight readings

    func testFollowerBgReadingParsesNightscoutAndLibreLinkUpEntries() throws {
        let reading = try XCTUnwrap(FollowerBgReading(json: ["sgv": 140.0, "date": 1_700_000_060_000.0]))
        XCTAssertEqual(reading.timeStamp, Date(timeIntervalSince1970: 1_700_000_060))
        XCTAssertNil(FollowerBgReading(json: ["sgv": 140.0, "date": "x"]))
        XCTAssertNil(FollowerBgReading(json: [:]))
        let measurement = RequestGraphResponseGlucoseMeasurement(FactoryTimestamp: Date(timeIntervalSince1970: 42), ValueInMgPerDl: 99)
        let libre = try XCTUnwrap(FollowerBgReading(entry: measurement))
        XCTAssertEqual(libre.sgv, 99)
        XCTAssertEqual(libre.timeStamp, Date(timeIntervalSince1970: 42))
    }

    func testDateFormatterISO8601UsesUTCWithoutFraction() {
        let formatter = DateFormatter.ISO8601DateFormatter()
        XCTAssertEqual(formatter.string(from: Date(timeIntervalSince1970: 0.9)), "1970-01-01T00:00:00Z")
        XCTAssertEqual(formatter.date(from: "2026-01-02T03:04:05+01:00"), Date(timeIntervalSince1970: 1_767_319_445))
    }

    // MARK: - Upload dictionaries

    func testBgReadingNightscoutDictionaryUsesFinalValueAndRawFallbacks() {
        let timeStamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let reading = BgReading(timeStamp: timeStamp, sensor: nil, calibration: nil, rawData: 0, deviceName: "G7", nsManagedObjectContext: context)
        reading.calculatedValue = 120.4
        reading.calculatedValueSlope = 2.5 / 60_000
        reading.hideSlope = false
        reading.ageAdjustedRawValue = 0

        var dictionary = reading.dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(dictionary["_id"] as? String, reading.id)
        XCTAssertEqual(dictionary["device"] as? String, "G7")
        XCTAssertEqual(dictionary["date"] as? Int64, 1_700_000_000_123)
        XCTAssertEqual(dictionary["type"] as? String, "sgv")
        XCTAssertEqual(dictionary["sgv"] as? Int, 120)
        XCTAssertEqual(dictionary["direction"] as? String, "SingleUp")
        XCTAssertEqual(dictionary["filtered"] as? Int, 120_000)
        XCTAssertEqual(dictionary["unfiltered"] as? Int, 120_000)
        XCTAssertEqual(dictionary["noise"] as? Int, 1)
        XCTAssertEqual(dictionary["dateString"] as? String, dictionary["sysTime"] as? String)

        reading.ageAdjustedRawValue = 150.25
        reading.smoothedValue = NSNumber(value: 131.6)
        reading.hideSlope = true
        reading.deviceName = nil
        dictionary = reading.dictionaryRepresentationForNightscoutUpload(reuseDateFormatter: Date.ISODateFormatter())
        XCTAssertEqual(dictionary["sgv"] as? Int, 132)
        XCTAssertEqual(dictionary["filtered"] as? Double, 150_250)
        XCTAssertEqual(dictionary["direction"] as? String, "NOT COMPUTABLE")
        XCTAssertEqual(dictionary["device"] as? String, "")
    }

    func testCalibrationNightscoutDictionaries() {
        let sensor = Sensor(startDate: Date(timeIntervalSince1970: 1_699_000_000), nsManagedObjectContext: context)
        let timeStamp = Date(timeIntervalSince1970: 1_700_000_000)
        let calibration = Calibration(timeStamp: timeStamp, sensor: sensor, bg: 105, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: timeStamp, slope: 2, intercept: 10, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 0, slopeConfidence: 1, deviceName: "Dexcom", nsManagedObjectContext: context)

        let cal = calibration.dictionaryRepresentationForCalRecordNightscoutUpload
        XCTAssertEqual(cal["type"] as? String, "cal")
        XCTAssertEqual(cal["_id"] as? String, calibration.id)
        XCTAssertEqual(cal["device"] as? String, "Dexcom")
        XCTAssertEqual(cal["date"] as? Int64, 1_700_000_000_000)
        XCTAssertEqual(cal["slope"] as? Double, 500)
        XCTAssertEqual(cal["intercept"] as? Double, -5000)
        XCTAssertEqual(cal["scale"] as? Int, 1)

        let mbg = calibration.dictionaryRepresentationForMbgRecordNightscoutUpload
        XCTAssertEqual(mbg["type"] as? String, "mbg")
        XCTAssertEqual(mbg["mbg"] as? Double, 105)
        XCTAssertNotEqual(mbg["_id"] as? String, calibration.id)

        calibration.slope = 0
        calibration.deviceName = nil
        let zero = calibration.dictionaryRepresentationForCalRecordNightscoutUpload
        XCTAssertEqual(zero["slope"] as? Int, 0)
        XCTAssertEqual(zero["intercept"] as? Int, 0)
        XCTAssertEqual(zero["device"] as? String, "")
    }

    func testBgReadingDexcomShareDictionaryTruncatesToWholeSeconds() {
        let reading = BgReading(timeStamp: Date(timeIntervalSince1970: 1_700_000_000.987), sensor: nil, calibration: nil, rawData: 0, deviceName: nil, nsManagedObjectContext: context)
        reading.calculatedValue = 99.5
        reading.calculatedValueSlope = -4.0 / 60_000
        reading.hideSlope = false
        let dictionary = reading.dictionaryRepresentationForDexcomShareUpload
        XCTAssertEqual(dictionary["ST"] as? String, "/Date(1700000000000)/")
        XCTAssertEqual(dictionary["DT"] as? String, "/Date(1700000000000)/")
        XCTAssertEqual(dictionary["Value"] as? Double, 100)
        XCTAssertEqual(dictionary["direction"] as? String, "DoubleDown")
        XCTAssertEqual(dictionary["Trend"] as? Int, 7)
    }
}
