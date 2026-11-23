//
//  WatchPayloadTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the dictionaries the phone sends to the Watch app and the Live Activity style values.
///
/// The Watch does not decode `WatchStatus` with `Codable`: it reads `asDictionary` key by key with
/// `as?` casts and falls back to defaults when a key is missing or has another type. A renamed
/// property or a value encoded in an unexpected shape would therefore not fail, it would silently
/// show default limits or the wrong follower source. The AID status is the exception: it is decoded
/// from its nested dictionary, so it must survive the trip through `JSONSerialization`.
final class WatchPayloadTests: XCTestCase {

    // MARK: - WatchStatus

    /// These keys are read by name in `WatchStateModel.processStatusFromDictionary`.
    func testStatusDictionaryContainsEveryKeyTheWatchReads() throws {
        var status = WatchStatus()
        status.activeSensorDescription = "Libre 3"
        status.sensorNoiseStateRawValue = 2
        status.followerConnectionStatusRawValue = "connected"
        status.timeStampOfLastFollowerConnection = 1732356900.5
        status.secondsUntilFollowerDisconnectWarning = 310
        status.timeStampOfLastHeartBeat = 1732356800.5
        status.secondsUntilHeartBeatDisconnectWarning = 120
        let dictionary = try XCTUnwrap(status.asDictionary)

        let keys = ["generatedAt", "isMgDl", "urgentLowLimitInMgDl", "lowLimitInMgDl", "highLimitInMgDl", "urgentHighLimitInMgDl",
                    "activeSensorDescription", "phoneBLECollectionPaused", "sensorAgeInMinutes", "sensorMaxAgeInMinutes",
                    "preferSensorCountdown", "sensorNoiseStateRawValue", "isMaster", "followerDataSourceTypeRawValue",
                    "followerBackgroundKeepAliveTypeRawValue", "followerConnectionStatusRawValue", "timeStampOfLastFollowerConnection",
                    "secondsUntilFollowerDisconnectWarning", "timeStampOfLastHeartBeat", "secondsUntilHeartBeatDisconnectWarning",
                    "keepAliveIsDisabled"]
        for key in keys {
            XCTAssertNotNil(dictionary[key], key)
        }
        XCTAssertEqual(dictionary["activeSensorDescription"] as? String, "Libre 3")
        XCTAssertEqual(dictionary["followerConnectionStatusRawValue"] as? String, "connected")
        XCTAssertEqual(dictionary["isMaster"] as? Bool, true)
        XCTAssertEqual(dictionary["keepAliveIsDisabled"] as? Bool, false)
    }

    func testNilOptionalsAreOmittedSoTheWatchUsesItsDefaults() throws {
        let dictionary = try XCTUnwrap(WatchStatus().asDictionary)
        for key in ["activeSensorDescription", "sensorNoiseStateRawValue", "followerConnectionStatusRawValue", "timeStampOfLastFollowerConnection",
                    "secondsUntilFollowerDisconnectWarning", "timeStampOfLastHeartBeat", "secondsUntilHeartBeatDisconnectWarning",
                    "aidStatus", "therapyMetrics"] {
            XCTAssertNil(dictionary[key], key)
        }
    }

    /// The Watch maps the raw values back with `FollowerDataSourceType(rawValue:)`.
    func testFollowerSourceRawValueSurvivesTheDictionary() throws {
        for source in FollowerDataSourceType.allCases {
            var status = WatchStatus()
            status.isMaster = false
            status.followerDataSourceTypeRawValue = source.rawValue
            let dictionary = try XCTUnwrap(status.asDictionary)
            let raw = try XCTUnwrap(dictionary["followerDataSourceTypeRawValue"] as? Int)
            XCTAssertEqual(FollowerDataSourceType(rawValue: raw), source)
            XCTAssertEqual(dictionary["isMaster"] as? Bool, false)
        }
    }

    /// The nested AID status is decoded again on the Watch; dates and values must be preserved.
    func testAIDStatusRoundTripsThroughTheWatchDictionary() throws {
        let aidStatus = AIDStatus(
            condition: .active,
            style: .loop,
            statusUpdatedAt: Date(timeIntervalSinceReferenceDate: 754_000_000),
            lastActivityAt: Date(timeIntervalSinceReferenceDate: 753_999_700),
            iob: 1.25,
            cob: 18,
            statusTitle: "Looping",
            staleStatusTitle: "No data"
        )
        var status = WatchStatus()
        status.aidStatus = aidStatus
        let dictionary = try XCTUnwrap(status.asDictionary)

        let nested = try XCTUnwrap(dictionary["aidStatus"] as? [String: Any])
        let decoded = try JSONDecoder().decode(AIDStatus.self, from: JSONSerialization.data(withJSONObject: nested))
        XCTAssertEqual(decoded, aidStatus)
    }

    /// The whole status is also stored as JSON; it must decode back to the same values.
    func testStatusRoundTripsThroughCodable() throws {
        var status = WatchStatus()
        status.isMgDl = false
        status.highLimitInMgDl = 180.5
        status.followerDataSourceTypeRawValue = FollowerDataSourceType.careLink.rawValue
        status.followerBackgroundKeepAliveTypeRawValue = 3
        status.keepAliveIsDisabled = true
        status.sensorAgeInMinutes = 7_200
        let copy = try JSONDecoder().decode(WatchStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(copy.isMgDl, false)
        XCTAssertEqual(copy.highLimitInMgDl, 180.5)
        XCTAssertEqual(copy.followerDataSourceTypeRawValue, 6)
        XCTAssertEqual(copy.followerBackgroundKeepAliveTypeRawValue, 3)
        XCTAssertEqual(copy.keepAliveIsDisabled, true)
        XCTAssertEqual(copy.sensorAgeInMinutes, 7_200)
        XCTAssertEqual(copy.generatedAt, status.generatedAt)
        XCTAssertNil(copy.aidStatus)
    }

    // MARK: - WatchBgReadings and WatchAGP

    func testBgReadingsDictionaryKeepsParallelArraysInOrder() throws {
        var readings = WatchBgReadings()
        readings.bgReadingValues = [120.5, 118, 117.25]
        readings.bgReadingDatesAsDouble = [1732356900.5, 1732356600.5, 1732356300.5]
        readings.slopeOrdinal = 4
        readings.deltaValueInUserUnit = -1.5
        let dictionary = try XCTUnwrap(readings.asDictionary)

        XCTAssertEqual(dictionary["bgReadingValues"] as? [Double], [120.5, 118, 117.25])
        XCTAssertEqual(dictionary["bgReadingDatesAsDouble"] as? [Double], [1732356900.5, 1732356600.5, 1732356300.5])
        XCTAssertEqual(dictionary["slopeOrdinal"] as? Int, 4)
        XCTAssertEqual(dictionary["deltaValueInUserUnit"] as? Double, -1.5)
        XCTAssertNotNil(dictionary["generatedAt"])
        XCTAssertNotNil(dictionary["hoursIncluded"])
    }

    func testAGPDictionaryIsColumnBased() throws {
        var agp = WatchAGP()
        agp.requestID = 42.5
        agp.dayCount = 14
        agp.minuteOfDayValues = [0, 15, 1425]
        agp.p5Values = [60.5, 61.5, 62.5]
        agp.p25Values = [80.5, 81.5, 82.5]
        agp.medianValues = [110.5, 111.5, 112.5]
        agp.p75Values = [140.5, 141.5, 142.5]
        agp.p95Values = [190.5, 191.5, 192.5]
        let dictionary = try XCTUnwrap(agp.asDictionary)

        XCTAssertEqual(dictionary["requestID"] as? Double, 42.5)
        XCTAssertEqual(dictionary["dayCount"] as? Int, 14)
        XCTAssertEqual(dictionary["minuteOfDayValues"] as? [Int], [0, 15, 1425])
        XCTAssertEqual(dictionary["medianValues"] as? [Double], [110.5, 111.5, 112.5])
        XCTAssertEqual(dictionary["p95Values"] as? [Double], [190.5, 191.5, 192.5])
        let copy = try JSONDecoder().decode(WatchAGP.self, from: JSONEncoder().encode(agp))
        XCTAssertEqual(copy.p25Values, agp.p25Values)
        XCTAssertEqual(copy.p75Values, agp.p75Values)
    }

    // MARK: - Live Activity style

    /// Disabled is kept only so old stored values and payloads still decode; it is not selectable.
    func testDisabledLiveActivityStyleIsLegacyOnly() {
        XCTAssertFalse(LiveActivityType.allCasesForList.contains(.disabled))
        XCTAssertEqual(Set(LiveActivityType.allCasesForList), Set(LiveActivityType.allCases).subtracting([.disabled]))
        XCTAssertEqual(LiveActivityType.disabled.description, LiveActivityType.disabled.debugDescription)
        XCTAssertEqual(LiveActivityType.normal.description, Texts_SettingsView.liveActivityTypeNormal)
        XCTAssertEqual(LiveActivityType.minimal.description, Texts_SettingsView.liveActivityTypeMinimal)
        XCTAssertEqual(LiveActivityType.large.description, Texts_SettingsView.liveActivityTypeLarge)
        XCTAssertEqual(Set(LiveActivityType.allCases.map(\.debugDescription)).count, LiveActivityType.allCases.count)
    }

    func testLiveActivityStylesEncodeAsStableRawValues() throws {
        struct Payload: Codable { let style: LiveActivityType; let carPlay: CarPlayLiveActivityType }
        let encoded = try JSONEncoder().encode(Payload(style: .large, carPlay: .basic))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Int])
        XCTAssertEqual(json, ["style": 3, "carPlay": 1])

        let legacy = try JSONDecoder().decode(Payload.self, from: Data(#"{"style":0,"carPlay":0}"#.utf8))
        XCTAssertEqual(legacy.style, .disabled)
        XCTAssertEqual(legacy.carPlay, .chart)
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: Data(#"{"style":4,"carPlay":0}"#.utf8)))
        XCTAssertEqual(CarPlayLiveActivityType.chart.description, Texts_SettingsView.carPlayLiveActivityTypeChart)
        XCTAssertEqual(CarPlayLiveActivityType.basic.description, Texts_SettingsView.carPlayLiveActivityTypeBasic)
    }
}
