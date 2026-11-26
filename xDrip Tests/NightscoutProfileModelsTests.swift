//
//  NightscoutProfileModelsTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the decoding of the Nightscout `profile` endpoint and its conversion into the internal
/// `NightscoutProfile` used for scheduled basal, ISF, carb ratio and target analytics.
///
/// Real profile documents carry many fields xDrip does not use (`mills`, `loopSettings`,
/// `carbs_hr`, per-profile `startDate` ...) and come from different uploaders with different date
/// precision and unit spellings. A wrong default-profile choice or a unit misread as mmol/L would
/// scale every scheduled value in the reports, so these rules are checked with realistic documents.
final class NightscoutProfileModelsTests: XCTestCase {

    // MARK: - helpers

    /// One profile store entry with the given units and basal rates (other schedules are fixed).
    private func store(units: String, basal: [(String, Double, Int)], timezone: String = "Europe/Amsterdam", dia: Double = 6) -> String {
        let basalJSON = basal.map { #"{"time":"\#($0.0)","value":\#($0.1),"timeAsSeconds":\#($0.2)}"# }.joined(separator: ",")
        return """
        {
          "dia": \(dia),
          "carbratio": [{"time":"00:00","value":10,"timeAsSeconds":0},{"time":"12:00","value":8.5,"timeAsSeconds":43200}],
          "carbs_hr": 20,
          "delay": 20,
          "sens": [{"time":"00:00","value":45,"timeAsSeconds":0}],
          "timezone": "\(timezone)",
          "basal": [\(basalJSON)],
          "target_low": [{"time":"00:00","value":100,"timeAsSeconds":0}],
          "target_high": [{"time":"00:00","value":120,"timeAsSeconds":0},{"time":"22:00","value":140,"timeAsSeconds":79200}],
          "startDate": "1970-01-01T00:00:00.000Z",
          "units": "\(units)"
        }
        """
    }

    /// A document as returned by `/api/v1/profile`, with fields xDrip ignores.
    private func document(defaultProfile: String, stores: [String: String], startDate: String = "2024-11-20T08:30:00.000Z", extra: String = "") -> String {
        let storeJSON = stores.map { #""\#($0.key)": \#($0.value)"# }.joined(separator: ",")
        return """
        {
          "_id": "673d9c1e2f0a4b0012345678",
          "defaultProfile": "\(defaultProfile)",
          "store": { \(storeJSON) },
          "startDate": "\(startDate)",
          "mills": 1732091400000,
          "units": "mg/dl",
          "created_at": "2024-11-20T08:30:01.000Z",
          "loopSettings": { "dosingEnabled": true, "maximumBasalRatePerHour": 3 }\(extra)
        }
        """
    }

    private func decode(_ json: String) throws -> NightscoutProfileResponse {
        try JSONDecoder().decode(NightscoutProfileResponse.self, from: Data(json.utf8))
    }

    // MARK: - default profile selection

    func testDefaultProfileIsChosenAmongSeveralStores() throws {
        let json = document(defaultProfile: "Weekend", stores: [
            "Default": store(units: "mg/dl", basal: [("00:00", 0.8, 0)]),
            "Weekend": store(units: "mg/dl", basal: [("00:00", 0.6, 0), ("06:30", 0.95, 23400)], timezone: "America/New_York", dia: 5),
            "Sick day": store(units: "mg/dl", basal: [("00:00", 1.4, 0)])
        ], extra: #", "enteredBy": "Loop""#)
        let profile = NightscoutProfile(from: try decode(json))

        XCTAssertEqual(profile.profileName, "Weekend")
        XCTAssertEqual(profile.basal, [.init(timeAsSecondsFromMidnight: 0, value: 0.6), .init(timeAsSecondsFromMidnight: 23400, value: 0.95)])
        XCTAssertEqual(profile.timezone, "America/New_York")
        XCTAssertEqual(profile.dia, 5)
        XCTAssertEqual(profile.enteredBy, "Loop")
        XCTAssertEqual(profile.id, "673d9c1e2f0a4b0012345678")
        XCTAssertEqual(profile.carbratio?.map(\.value), [10, 8.5])
        XCTAssertEqual(profile.sensitivity?.map(\.value), [45])
        XCTAssertEqual(profile.targetLow?.map(\.value), [100])
        XCTAssertEqual(profile.targetHigh?.map(\.timeAsSecondsFromMidnight), [0, 79200])
        XCTAssertTrue(profile.hasData())
    }

    /// When the named default is missing, the only remaining store is used rather than no schedule.
    func testMissingDefaultNameFallsBackToTheAvailableStore() throws {
        let json = document(defaultProfile: "Deleted", stores: ["Only": store(units: "mmol", basal: [("00:00", 0.7, 0)])])
        let profile = NightscoutProfile(from: try decode(json))
        XCTAssertEqual(profile.profileName, "Deleted", "the name reported by Nightscout is kept")
        XCTAssertEqual(profile.basal?.map(\.value), [0.7])
        XCTAssertEqual(profile.isMgDl, false)
    }

    func testEmptyStoreLeavesSchedulesUnknownButMarksDataReceived() throws {
        let profile = NightscoutProfile(from: try decode(document(defaultProfile: "Default", stores: [:])))
        XCTAssertNil(profile.basal)
        XCTAssertNil(profile.isMgDl)
        XCTAssertNil(profile.dia)
        XCTAssertTrue(profile.hasData())
        XCTAssertFalse(NightscoutProfile().hasData())
    }

    // MARK: - units

    func testUnitsAreMatchedCaseInsensitively() throws {
        let expectations: [(String, Bool)] = [("mg/dl", true), ("mg/dL", true), ("MG/DL", true), ("mmol", false), ("mmol/L", false)]
        for (units, isMgDl) in expectations {
            let json = document(defaultProfile: "Default", stores: ["Default": store(units: units, basal: [("00:00", 1, 0)])])
            XCTAssertEqual(NightscoutProfile(from: try decode(json)).isMgDl, isMgDl, units)
        }
    }

    // MARK: - dates

    func testStartDateAcceptsBothPrecisionsAndFallsBackWhenInvalid() throws {
        let stores = ["Default": store(units: "mg/dl", basal: [("00:00", 1, 0)])]
        let expected = Date(timeIntervalSince1970: 1732091400)

        let withFraction = NightscoutProfile(from: try decode(document(defaultProfile: "Default", stores: stores, startDate: "2024-11-20T08:30:00.000Z")))
        XCTAssertEqual(withFraction.startDate, expected)
        XCTAssertEqual(withFraction.createdAt, withFraction.startDate)

        let withoutFraction = NightscoutProfile(from: try decode(document(defaultProfile: "Default", stores: stores, startDate: "2024-11-20T08:30:00Z")))
        XCTAssertEqual(withoutFraction.startDate, expected)

        let invalid = NightscoutProfile(from: try decode(document(defaultProfile: "Default", stores: stores, startDate: "20/11/2024")))
        XCTAssertEqual(invalid.startDate, .distantPast)
        XCTAssertEqual(invalid.basal?.count, 1, "an invalid date does not drop the schedules")
    }

    // MARK: - strictness

    /// The schedules are required: a profile without them cannot provide scheduled-basal analytics,
    /// so decoding fails instead of producing a profile with silently empty schedules.
    func testStoreWithoutARequiredScheduleFailsToDecode() {
        let broken = store(units: "mg/dl", basal: [("00:00", 1, 0)]).replacingOccurrences(of: "\"target_low\"", with: "\"targetLow\"")
        XCTAssertThrowsError(try decode(document(defaultProfile: "Default", stores: ["Default": broken])))
        XCTAssertThrowsError(try decode(#"{"defaultProfile":"Default","store":{},"startDate":"2024-11-20T08:30:00Z"}"#), "the _id is required")
    }

    func testIntegerScheduleValuesDecodeAsDoubles() throws {
        let json = document(defaultProfile: "Default", stores: ["Default": store(units: "mg/dl", basal: [("00:00", 1, 0), ("23:30", 2, 84600)])])
        let profile = NightscoutProfile(from: try decode(json))
        XCTAssertEqual(profile.basal?.map(\.value), [1.0, 2.0])
        XCTAssertEqual(profile.basal?.last?.timeAsSecondsFromMidnight, 84600)
    }

    // MARK: - internal model

    func testTimeValueIsAnOffsetFromTheGivenMidnight() {
        let midnight = Date(timeIntervalSince1970: 1732320000) // 2024-11-23T00:00:00Z
        let value = NightscoutProfile.TimeValue(timeAsSecondsFromMidnight: 23400, value: 0.95)
        XCTAssertEqual(value.toDate(date: midnight), Date(timeIntervalSince1970: 1732320000 + 23400))
        XCTAssertEqual(NightscoutProfile.TimeValue(timeAsSecondsFromMidnight: 0, value: 1).toDate(date: midnight), midnight)
    }

    /// The internal profile is cached as JSON; every field must survive a round trip.
    func testInternalProfileRoundTripsThroughCodable() throws {
        let json = document(defaultProfile: "Default", stores: ["Default": store(units: "mmol", basal: [("00:00", 0.8, 0), ("06:00", 1.1, 21600)])], extra: #", "enteredBy": "Trio""#)
        let profile = NightscoutProfile(from: try decode(json))
        let copy = try JSONDecoder().decode(NightscoutProfile.self, from: JSONEncoder().encode(profile))

        XCTAssertEqual(copy.basal, profile.basal)
        XCTAssertEqual(copy.carbratio, profile.carbratio)
        XCTAssertEqual(copy.sensitivity, profile.sensitivity)
        XCTAssertEqual(copy.targetLow, profile.targetLow)
        XCTAssertEqual(copy.targetHigh, profile.targetHigh)
        XCTAssertEqual(copy.timezone, profile.timezone)
        XCTAssertEqual(copy.dia, profile.dia)
        XCTAssertEqual(copy.isMgDl, false)
        XCTAssertEqual(copy.id, profile.id)
        XCTAssertEqual(copy.startDate, profile.startDate)
        XCTAssertEqual(copy.profileName, "Default")
        XCTAssertEqual(copy.enteredBy, "Trio")
        XCTAssertEqual(copy.updatedDate.timeIntervalSince1970, profile.updatedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testProfileListDecodesNewestFirstDocuments() throws {
        let newest = document(defaultProfile: "Default", stores: ["Default": store(units: "mg/dl", basal: [("00:00", 0.9, 0)])])
        let older = document(defaultProfile: "Default", stores: ["Default": store(units: "mg/dl", basal: [("00:00", 0.7, 0)])], startDate: "2024-10-01T00:00:00Z")
        let profiles = try JSONDecoder().decode([NightscoutProfileResponse].self, from: Data("[\(newest),\(older)]".utf8)).map(NightscoutProfile.init(from:))
        XCTAssertEqual(profiles.map { $0.basal?.first?.value }, [0.9, 0.7])
        XCTAssertGreaterThan(profiles[0].startDate, profiles[1].startDate)
    }
}
