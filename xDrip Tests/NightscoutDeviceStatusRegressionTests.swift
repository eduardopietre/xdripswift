//
//  NightscoutDeviceStatusRegressionTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for three ways the follower lost or misreported AID status from Nightscout:
///
/// - AndroidAPS writes the pump's `extended` keys capitalized (`Version`, `ActiveProfile`,
///   `BaseBasalRate`). The model only knew the lowercase keys, so the active profile, base basal
///   and AAPS version were always nil for AAPS users.
/// - Some uploaders send `uploader` as a plain text (e.g. `"GG-Host"`) instead of an object. One
///   such document made the decoding of the whole device status list fail, so the follower showed
///   no AID status at all.
/// - The newer of `suggested` and `enacted` was chosen by comparing the timestamp texts. That is
///   wrong when the two use different offsets or fractional seconds, and then the older decision
///   was shown.
final class NightscoutDeviceStatusRegressionTests: XCTestCase {

    private func decode(_ json: String) throws -> NightscoutDeviceStatusResponse {
        try JSONDecoder().decode(NightscoutDeviceStatusResponse.self, from: Data(json.utf8))
    }

    // MARK: - AndroidAPS pump.extended

    func testAndroidAPSCapitalizedExtendedKeysAreRead() throws {
        let response = try decode("""
        {
          "device": "openaps://samsung SM-G991B",
          "created_at": "2026-11-25T10:00:00.000Z",
          "pump": {
            "clock": "2026-11-25T10:00:00.000Z",
            "reservoir": 120.5,
            "battery": { "percent": 75 },
            "extended": {
              "Version": "3.2.0.4-dev",
              "LastBolus": "25.11.26 09:40",
              "LastBolusAmount": 1.5,
              "BaseBasalRate": 0.85,
              "ActiveProfile": "Weekday"
            }
          }
        }
        """)

        XCTAssertEqual(response.pump?.extended?.version, "3.2.0.4-dev")
        XCTAssertEqual(response.pump?.extended?.activeProfile, "Weekday")
        XCTAssertEqual(response.pump?.extended?.baseBasalRate, 0.85)

        let status = NightscoutDeviceStatus(from: response)
        XCTAssertEqual(status.activeProfile, "Weekday")
        XCTAssertEqual(status.baseBasalRate, 0.85)
        XCTAssertEqual(status.appVersion, "3.2.0.4-dev")
    }

    func testLowercaseExtendedKeysStillWork() throws {
        let response = try decode("""
        { "pump": { "extended": { "version": "1.0", "activeProfile": "Default", "baseBasalRate": 1.1 } } }
        """)

        XCTAssertEqual(response.pump?.extended?.version, "1.0")
        XCTAssertEqual(response.pump?.extended?.activeProfile, "Default")
        XCTAssertEqual(response.pump?.extended?.baseBasalRate, 1.1)
    }

    func testExtendedWithAnUnexpectedTypeDoesNotFailTheDocument() throws {
        let response = try decode("""
        { "pump": { "reservoir": 50, "extended": { "BaseBasalRate": "0.85", "ActiveProfile": "Night" } } }
        """)

        XCTAssertEqual(response.pump?.reservoir, 50)
        XCTAssertNil(response.pump?.extended?.baseBasalRate)
        XCTAssertEqual(response.pump?.extended?.activeProfile, "Night")
    }

    func testExtendedIsEncodedWithTheLowercaseKeys() throws {
        let response = try decode("""
        { "pump": { "extended": { "Version": "3.2", "ActiveProfile": "Weekday", "BaseBasalRate": 0.85 } } }
        """)

        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(response), encoding: .utf8))
        XCTAssertTrue(json.contains("\"activeProfile\":\"Weekday\""), json)
        XCTAssertTrue(json.contains("\"baseBasalRate\":0.85"), json)
        let decodedAgain = try decode(json)
        XCTAssertEqual(decodedAgain.pump?.extended?.activeProfile, "Weekday")
    }

    // MARK: - uploader as text

    func testUploaderSentAsTextIsReadAsItsName() throws {
        let response = try decode("""
        { "device": "GG-Host", "uploader": "GG-Host", "uploaderBattery": 64 }
        """)

        XCTAssertEqual(response.uploader?.name, "GG-Host")
        XCTAssertNil(response.uploader?.battery)
        XCTAssertEqual(NightscoutDeviceStatus(from: response).uploaderBatteryPercent, 64)
    }

    func testOneTextUploaderDoesNotFailTheWholeList() throws {
        let list = """
        [
          { "device": "loop://iPhone", "uploader": { "name": "iPhone", "battery": 80 } },
          { "device": "GG-Host", "uploader": "GG-Host" },
          { "device": "openaps://phone", "uploader": { "battery": 55, "isCharging": true } }
        ]
        """

        let responses = try JSONDecoder().decode([NightscoutDeviceStatusResponse].self, from: Data(list.utf8))

        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses.map { $0.uploader?.name }, ["iPhone", "GG-Host", nil])
        XCTAssertEqual(responses[2].uploader?.battery, 55)
    }

    func testUploaderOfAnotherTypeIsIgnored() throws {
        let response = try decode("""
        { "device": "odd", "uploader": 12, "uploaderBattery": 30 }
        """)

        XCTAssertNil(response.uploader?.name)
        XCTAssertNil(response.uploader?.battery)
        XCTAssertEqual(response.uploaderBattery, 30)
    }

    // MARK: - suggested versus enacted

    /// The enacted decision is at 10:15 UTC but written with a +01:00 offset; the suggestion is at
    /// 10:20 UTC. As texts "…T11:15…" sorts after "…T10:20…", which picked the older enacted one.
    func testTheNewerDecisionWinsWhateverTheTimestampFormat() throws {
        let response = try decode("""
        {
          "device": "openaps://phone",
          "openaps": {
            "enacted":   { "timestamp": "2026-11-25T11:15:00+01:00", "eventualBG": 150, "reason": "older" },
            "suggested": { "timestamp": "2026-11-25T10:20:00Z",      "eventualBG": 110, "reason": "newer" }
          }
        }
        """)

        let status = NightscoutDeviceStatus(from: response)

        XCTAssertEqual(status.eventualBG, 110)
        XCTAssertEqual(status.timestamp, ISO8601DateFormatter.withoutFractionalSeconds.date(from: "2026-11-25T10:20:00Z"))
    }

    /// Same second, but the enacted decision is 200 ms later. As texts "…30Z" sorts after
    /// "…30.200Z" because "Z" comes after ".", which picked the older suggestion.
    func testFractionalSecondsAreComparedAsTime() throws {
        let response = try decode("""
        {
          "device": "openaps://phone",
          "openaps": {
            "suggested": { "timestamp": "2026-11-25T10:15:30Z",     "eventualBG": 120 },
            "enacted":   { "timestamp": "2026-11-25T10:15:30.200Z", "eventualBG": 130 }
          }
        }
        """)

        XCTAssertEqual(NightscoutDeviceStatus(from: response).eventualBG, 130)
    }

    func testUnparseableTimestampsKeepTheTextComparison() throws {
        let response = try decode("""
        {
          "device": "openaps://phone",
          "openaps": {
            "enacted":   { "timestamp": "b", "eventualBG": 150 },
            "suggested": { "timestamp": "c", "eventualBG": 110 }
          }
        }
        """)

        XCTAssertEqual(NightscoutDeviceStatus(from: response).eventualBG, 110)
    }
}
