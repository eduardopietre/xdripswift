//
//  NightscoutDeviceStatusDecodingTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the decoding of complete, realistic Nightscout `devicestatus` documents as uploaded by
/// Loop, AAPS, Trio and iAPS, and their conversion into the internal `NightscoutDeviceStatus`.
///
/// Each AID system publishes a different shape (Loop's `loop` object, the OpenAPS `openaps`
/// suggested/enacted pair, iAPS's `recieved` typo, Omnipod pumps without a reservoir level, AAPS's
/// top-level uploader battery). The tests use whole documents with the extra fields the real apps
/// send, so a model change that breaks one system's mapping, or that makes an unknown field fail
/// the decoding of the whole list, is caught before followers lose their AID status.
final class NightscoutDeviceStatusDecodingTests: XCTestCase {

    // MARK: - helpers

    private func decode(_ json: String) throws -> NightscoutDeviceStatusResponse {
        try JSONDecoder().decode(NightscoutDeviceStatusResponse.self, from: Data(json.utf8))
    }

    private func status(_ json: String) throws -> NightscoutDeviceStatus {
        NightscoutDeviceStatus(from: try decode(json))
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter.withFractionalSeconds.date(from: string) ?? ISO8601DateFormatter.withoutFractionalSeconds.date(from: string)!
    }

    /// A Loop 3 document: Omnipod DASH (no reservoir level above 50 U), an active override and an
    /// automatic dose recommendation next to the enacted temp basal.
    private let loopDocument = """
    {
      "_id": "6741a1f0c2b1a2b3c4d5e6f7",
      "created_at": "2024-11-23T10:15:30.000Z",
      "device": "loop://iPhone",
      "mills": 1732356930000,
      "utcOffset": 60,
      "loop": {
        "name": "Loop",
        "version": "3.4.4",
        "timestamp": "2024-11-23T10:15:28Z",
        "iob": { "iob": 1.234, "timestamp": "2024-11-23T10:15:00Z" },
        "cob": { "cob": 12.5, "timestamp": "2024-11-23T10:15:28Z" },
        "predicted": { "startDate": "2024-11-23T10:15:00Z", "values": [120, 118, 115.5, 112] },
        "automaticDoseRecommendation": {
          "timestamp": "2024-11-23T10:15:28Z",
          "tempBasalAdjustment": { "rate": 0.8, "duration": 30 },
          "bolusVolume": 0.1
        },
        "enacted": { "rate": 0.8, "duration": 30, "timestamp": "2024-11-23T10:15:29Z", "received": true, "bolusVolume": 0.1 },
        "recommendedBolus": 0.35,
        "rileylinks": []
      },
      "pump": {
        "clock": "2024-11-23T10:15:20Z",
        "pumpID": "1F2E3D",
        "manufacturer": "Insulet",
        "model": "Dash",
        "suspended": false,
        "bolusing": false,
        "secondsFromGMT": 3600
      },
      "uploader": { "timestamp": "2024-11-23T10:15:30Z", "name": "iPhone", "battery": 64 },
      "override": {
        "timestamp": "2024-11-23T10:15:30Z",
        "active": true,
        "name": "Exercise",
        "symbol": "🏃",
        "multiplier": 0.6,
        "duration": 3600,
        "currentCorrectionRange": { "minValue": 140, "maxValue": 160 }
      }
    }
    """

    /// An AAPS document. AAPS sends the uploader battery at the top level, the IOB summary as
    /// `openaps.iob` and many algorithm fields xDrip does not use (`predBGs`, `tick`, `smb` ...).
    private let aapsDocument = """
    {
      "_id": "6741a3550000000000000001",
      "app": "AAPS",
      "device": "openaps://samsung SM-G991B",
      "created_at": "2024-11-23T10:20:05.123Z",
      "date": 1732357205123,
      "uploaderBattery": 55,
      "isCharging": true,
      "pump": {
        "clock": "2024-11-23T10:20:00.000Z",
        "reservoir": 123,
        "battery": { "percent": 75 },
        "status": { "status": "normal", "timestamp": "2024-11-23T10:19:50.000Z" }
      },
      "openaps": {
        "suggested": {
          "temp": "absolute", "bg": 143, "tick": "+3", "eventualBG": 121, "targetBG": 100,
          "insulinReq": 0.42, "sensitivityRatio": 1.1, "variable_sens": 45.2,
          "predBGs": { "IOB": [143, 140, 137] }, "COB": 18, "IOB": 2.1,
          "reason": "COB: 18, Dev: 9, BGI: -2.1, ISF: 45, CR: 10, Target: 100; Eventual BG 121 &gt; 100",
          "rate": 1.2, "duration": 30, "timestamp": "2024-11-23T10:20:01.000Z"
        },
        "enacted": {
          "temp": "absolute", "bg": 143, "eventualBG": 121, "insulinReq": 0.42, "sensitivityRatio": 1.1,
          "variable_sens": 45.2, "COB": 18, "IOB": 2.1, "reason": "COB: 18, Dev: 9",
          "rate": 1.2, "duration": 30, "smb": 0.3, "received": true, "timestamp": "2024-11-23T10:20:02.000Z"
        },
        "iob": { "iob": 2.1, "basaliob": 0.4, "activity": 0.01, "time": "2024-11-23T10:20:00.000Z" }
      }
    }
    """

    // MARK: - Loop

    func testLoopDocumentMapsLoopPumpUploaderAndOverride() throws {
        let status = try status(loopDocument)

        XCTAssertEqual(status.id, "6741a1f0c2b1a2b3c4d5e6f7")
        XCTAssertEqual(status.createdAt, date("2024-11-23T10:15:30Z"))
        XCTAssertEqual(status.mills, 1732356930000)
        XCTAssertEqual(status.utcOffset, 60)
        XCTAssertEqual(status.systemName(), "Loop")
        XCTAssertEqual(status.deviceName(), "Iphone")
        XCTAssertEqual(status.appVersion, "3.4.4")

        XCTAssertEqual(status.iob, 1.234)
        XCTAssertEqual(status.cob, 12.5)
        XCTAssertEqual(status.eventualBG, 112, "the last predicted value is the eventual BG")
        XCTAssertEqual(status.insulinReq, 0.35)
        XCTAssertEqual(status.rate, 0.8)
        XCTAssertEqual(status.duration, 30)
        XCTAssertEqual(status.bolusVolume, 0.1)
        XCTAssertNil(status.error)
        XCTAssertNil(status.timestamp, "Loop has no OpenAPS algorithm timestamp")
        XCTAssertEqual(status.lastLoopDate, date("2024-11-23T10:15:29Z"), "the newest of enacted and loop timestamps")

        XCTAssertEqual(status.pumpManufacturer, "Insulet")
        XCTAssertEqual(status.pumpModel, "Dash")
        XCTAssertEqual(status.pumpID, "1F2E3D")
        XCTAssertEqual(status.pumpClock, date("2024-11-23T10:15:20Z"))
        XCTAssertEqual(status.pumpIsSuspended, false)
        XCTAssertEqual(status.pumpIsBolusing, false)
        XCTAssertEqual(status.pumpReservoir, ConstantsNightscout.omniPodReservoirFlagNumber, "a pod without a level shows 50+")
        XCTAssertNil(status.pumpBatteryPercent)

        XCTAssertEqual(status.uploaderBatteryPercent, 64)
        XCTAssertNil(status.uploaderIsCharging)

        XCTAssertEqual(status.overrideActive, true)
        XCTAssertEqual(status.overrideName, "Exercise")
        XCTAssertEqual(status.overrideMultiplier, 0.6)
        XCTAssertEqual(status.overrideMinValue, 140)
        XCTAssertEqual(status.overrideMaxValue, 160)
    }

    /// A recommendation that Loop did not enact must not be shown as the running temp basal.
    func testLoopRecommendationWithoutEnactedDoseIsNotShownAsDelivered() throws {
        let status = try status("""
        {"device":"loop://iPhone","created_at":"2024-11-23T10:15:30Z","loop":{
          "timestamp":"2024-11-23T10:15:28Z",
          "automaticDoseRecommendation":{"timestamp":"2024-11-23T10:15:28Z","tempBasalAdjustment":{"rate":2.5,"duration":30},"bolusVolume":0.4}}}
        """)
        XCTAssertNil(status.rate)
        XCTAssertNil(status.duration)
        XCTAssertNil(status.bolusVolume)
        XCTAssertEqual(status.lastLoopDate, date("2024-11-23T10:15:28Z"))
    }

    func testLoopFailureKeepsTheFailureReasonAndLastLoopTime() throws {
        let status = try status("""
        {"device":"loop://iPhone","loop":{"timestamp":"2024-11-23T10:15:28Z","failureReason":"Pump communication timed out",
          "iob":{"iob":0.5,"timestamp":"2024-11-23T10:10:00Z"}}}
        """)
        XCTAssertEqual(status.error, "Pump communication timed out")
        XCTAssertEqual(status.iob, 0.5)
        XCTAssertNil(status.cob)
        XCTAssertNil(status.eventualBG)
        XCTAssertEqual(status.lastLoopDate, date("2024-11-23T10:15:28Z"))
    }

    // MARK: - OpenAPS family

    func testAAPSDocumentMapsEnactedValuesAndTopLevelUploaderBattery() throws {
        let status = try status(aapsDocument)

        XCTAssertEqual(status.systemName(), "AAPS")
        XCTAssertEqual(status.deviceName(), "Samsung sm-g991b")
        XCTAssertTrue(status.useSuggestedAsEnacted())
        XCTAssertEqual(status.createdAt, date("2024-11-23T10:20:05.123Z"))

        // enacted (10:20:02) is newer than suggested (10:20:01), so its values are shown
        XCTAssertEqual(status.timestamp, date("2024-11-23T10:20:02Z"))
        XCTAssertEqual(status.reason, "COB: 18, Dev: 9")
        XCTAssertEqual(status.rate, 1.2)
        XCTAssertEqual(status.duration, 30)
        XCTAssertEqual(status.eventualBG, 121)
        XCTAssertEqual(status.isf, 45.2, "dynamic ISF is used when no fixed ISF is sent")
        XCTAssertEqual(status.sensitivityRatio, 1.1)
        XCTAssertEqual(status.insulinReq, 0.42)
        XCTAssertEqual(status.cob, 18)
        XCTAssertEqual(status.iob, 2.1)
        XCTAssertEqual(status.lastLoopDate, date("2024-11-23T10:20:02Z"))

        XCTAssertEqual(status.uploaderBatteryPercent, 55)
        XCTAssertEqual(status.uploaderIsCharging, true)
        XCTAssertEqual(status.pumpBatteryPercent, 75)
        XCTAssertEqual(status.pumpReservoir, 123)
        XCTAssertEqual(status.pumpStatus, "normal")
        XCTAssertEqual(status.pumpStatusTimestamp, date("2024-11-23T10:19:50Z"))
        XCTAssertNil(status.pumpManufacturer)
    }

    func testAAPSSuggestionReasonIsSplitAndUnescaped() throws {
        var status = try status(aapsDocument)
        // show the suggestion's longer reason as AAPS does when it is the newest record
        status.reason = try decode(aapsDocument).openAPS?.suggested?.reason
        let values = try XCTUnwrap(status.reasonValuesArray())
        XCTAssertEqual(values.first, "COB: 18")
        XCTAssertEqual(values.last, "Target: 100; Eventual BG 121 > 100")
        XCTAssertEqual(values.count, 6)
    }

    /// iAPS writes `recieved` (sic). A received suggestion counts as a loop run even though iAPS
    /// does not treat suggestions as enacted.
    func testIAPSTypoFieldMarksTheSuggestionAsReceived() throws {
        let status = try status("""
        {"device":"iAPS","created_at":"2024-11-23T10:00:30Z","openaps":{"version":"4.0.1",
          "enacted":{"timestamp":"2024-11-23T09:55:00Z","rate":0.4,"duration":30,"COB":3,"IOB":0.8},
          "suggested":{"timestamp":"2024-11-23T10:00:00Z","rate":0.6,"duration":30,"COB":4,"IOB":0.9,"recieved":true,
                       "current_target":100,"ISF":50,"TDD":32.5,"CR":10}}}
        """)
        XCTAssertEqual(status.systemName(), "iAPS")
        XCTAssertFalse(status.useSuggestedAsEnacted())
        XCTAssertEqual(status.appVersion, "4.0.1")
        XCTAssertEqual(status.rate, 0.6)
        XCTAssertEqual(status.currentTarget, 100)
        XCTAssertEqual(status.isf, 50, "a fixed ISF wins over the dynamic one")
        XCTAssertEqual(status.tdd, 32.5)
        XCTAssertEqual(status.cob, 4)
        XCTAssertEqual(status.iob, 0.9)
        XCTAssertEqual(status.lastLoopDate, date("2024-11-23T10:00:00Z"))
    }

    func testTrioUnreceivedSuggestionDoesNotAdvanceTheLoopTime() throws {
        let status = try status("""
        {"device":"Trio","openaps":{
          "enacted":{"timestamp":"2024-11-23T09:55:00Z","received":true,"rate":0.4},
          "suggested":{"timestamp":"2024-11-23T10:00:00Z","received":false,"rate":0.6}}}
        """)
        XCTAssertEqual(status.systemName(), "Trio")
        XCTAssertEqual(status.rate, 0.6, "the newest algorithm output is still displayed")
        XCTAssertEqual(status.lastLoopDate, date("2024-11-23T09:55:00Z"))
    }

    func testEnactedCOBAndIOBAreUsedWhenTheSuggestionHasNone() throws {
        let status = try status("""
        {"device":"openaps://rig","openaps":{
          "suggested":{"timestamp":"2024-11-23T10:00:00Z"},
          "enacted":{"timestamp":"2024-11-23T09:55:00Z","COB":7,"IOB":1.5}}}
        """)
        XCTAssertEqual(status.cob, 7)
        XCTAssertEqual(status.iob, 1.5)
    }

    // MARK: - dates

    func testCreatedAtAcceptsCommonISO8601Variants() throws {
        let expected = date("2024-11-23T10:15:30Z")
        XCTAssertEqual(try status(#"{"created_at":"2024-11-23T10:15:30Z"}"#).createdAt, expected)
        XCTAssertEqual(try status(#"{"created_at":"2024-11-23T11:15:30+01:00"}"#).createdAt, expected)
        XCTAssertEqual(try status(#"{"created_at":"2024-11-23T10:15:30.000Z"}"#).createdAt, expected)
        XCTAssertEqual(try status(#"{"created_at":"2024-11-23T10:15:30.250Z"}"#).createdAt.timeIntervalSince(expected), 0.25, accuracy: 0.001)
    }

    func testUnparseableDatesFallBackWithoutFailingTheDocument() throws {
        let status = try status("""
        {"created_at":"1732356930000","device":"loop://iPhone","loop":{"timestamp":"yesterday",
          "iob":{"iob":0.7,"timestamp":"not a date"},"enacted":{"timestamp":"2024-11-23","rate":1}},
         "pump":{"clock":"23/11/2024 10:15","status":{"status":"normal","timestamp":""}}}
        """)
        XCTAssertEqual(status.createdAt, .distantPast)
        XCTAssertEqual(status.lastLoopDate, .distantPast, "no valid loop timestamp")
        XCTAssertEqual(status.iob, 0.7, "a value with an invalid timestamp is still used")
        XCTAssertEqual(status.rate, 1)
        XCTAssertNil(status.pumpClock)
        XCTAssertNil(status.pumpStatusTimestamp)
        XCTAssertEqual(status.pumpStatus, "normal")
    }

    // MARK: - pumps

    func testOmnipodDetectionIsCaseInsensitiveAndOtherPumpsKeepAMissingReservoir() throws {
        XCTAssertEqual(try status(#"{"pump":{"manufacturer":"INSULET"}}"#).pumpReservoir, ConstantsNightscout.omniPodReservoirFlagNumber)
        XCTAssertEqual(try status(#"{"pump":{"model":"DASH"}}"#).pumpReservoir, ConstantsNightscout.omniPodReservoirFlagNumber)
        XCTAssertEqual(try status(#"{"pump":{"manufacturer":"Insulet","model":"Dash","reservoir":42.5}}"#).pumpReservoir, 42.5, "a reported level wins")
        XCTAssertNil(try status(#"{"pump":{"manufacturer":"Medtronic","model":"723"}}"#).pumpReservoir)
        XCTAssertNil(try status(#"{"device":"loop://iPhone"}"#).pumpReservoir, "no pump object at all")
    }

    // MARK: - lists and composition

    /// Nightscout returns the newest documents first. A heartbeat-like newest document must keep
    /// its own values and take the missing ones from the full document before it.
    func testDecodedListComposesHeartbeatWithOlderFullStatus() throws {
        let heartbeat = #"{"_id":"new","device":"openaps://samsung SM-G991B","created_at":"2024-11-23T10:25:00Z","uploaderBattery":50,"isCharging":false}"#
        let data = Data("[\(heartbeat),\(aapsDocument)]".utf8)
        let responses = try JSONDecoder().decode([NightscoutDeviceStatusResponse].self, from: data)
        XCTAssertEqual(responses.count, 2)

        let composed = try XCTUnwrap(NightscoutDeviceStatus.composingDisplayValues(fromNewestFirst: responses.map(NightscoutDeviceStatus.init(from:))))
        XCTAssertEqual(composed.id, "new")
        XCTAssertEqual(composed.createdAt, date("2024-11-23T10:25:00Z"))
        XCTAssertEqual(composed.uploaderBatteryPercent, 50)
        XCTAssertEqual(composed.uploaderIsCharging, false)
        XCTAssertEqual(composed.iob, 2.1)
        XCTAssertEqual(composed.pumpReservoir, 123)
        XCTAssertEqual(composed.lastLoopDate, date("2024-11-23T10:20:02Z"))
        XCTAssertNil(NightscoutDeviceStatus.composingDisplayValues(fromNewestFirst: []))
    }

    /// Re-encoding must use Nightscout's key names, so a cached response can be decoded again.
    func testResponseRoundTripKeepsNightscoutKeyNames() throws {
        for document in [loopDocument, aapsDocument] {
            let response = try decode(document)
            let encoded = try JSONEncoder().encode(response)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNotNil(json["_id"])
            XCTAssertNotNil(json["created_at"])
            XCTAssertNil(json["id"])
            XCTAssertNil(json["createdAt"])

            let original = NightscoutDeviceStatus(from: response)
            let roundTrip = NightscoutDeviceStatus(from: try JSONDecoder().decode(NightscoutDeviceStatusResponse.self, from: encoded))
            XCTAssertFalse(roundTrip.hasPersistedChanges(comparedTo: original))
            XCTAssertEqual(roundTrip.pumpClock, original.pumpClock)
            XCTAssertEqual(roundTrip.lastLoopDate, original.lastLoopDate)
        }
        let aapsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decode(aapsDocument))) as? [String: Any])
        XCTAssertNotNil(aapsJSON["openaps"])
        XCTAssertNil(aapsJSON["openAPS"])
    }

    // MARK: - AID status

    func testDecodedStatusDrivesTheSharedAIDStatus() throws {
        var status = try status(loopDocument)
        XCTAssertEqual(status.aidStatus.condition, .checking, "never checked yet")

        status.lastCheckedDate = date("2024-11-23T10:16:00Z")
        let aid = status.aidStatus
        XCTAssertEqual(aid.condition, .active)
        XCTAssertEqual(aid.style, .loop)
        XCTAssertEqual(aid.statusUpdatedAt, date("2024-11-23T10:15:30Z"))
        XCTAssertEqual(aid.lastActivityAt, date("2024-11-23T10:15:29Z"))
        XCTAssertEqual(aid.iob, 1.234)
        XCTAssertEqual(aid.cob, 12.5)
        XCTAssertTrue(aid.supportsCOB)
    }
}
