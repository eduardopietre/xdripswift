//
//  NightscoutCoverageDeviceStatusModelTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI
import XCTest
@testable import xdrip

final class NightscoutCoverageDeviceStatusModelTests: XCTestCase {
    private func response(_ json: String) throws -> NightscoutDeviceStatusResponse {
        try JSONDecoder().decode(NightscoutDeviceStatusResponse.self, from: Data(json.utf8))
    }

    private func status(_ json: String) throws -> NightscoutDeviceStatus {
        NightscoutDeviceStatus(from: try response(json))
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter.withFractionalSeconds.date(from: iso) ?? ISO8601DateFormatter.withoutFractionalSeconds.date(from: iso)!
    }

    // MARK: - Decoding and parsing

    func testEmptyDocumentProducesEmptyStatus() throws {
        let status = try status("{}")
        XCTAssertEqual(status.createdAt, .distantPast)
        XCTAssertEqual(status.lastLoopDate, .distantPast)
        XCTAssertEqual(status.id, "")
        XCTAssertEqual(status.mills, 0)
        XCTAssertEqual(status.utcOffset, 0)
        XCTAssertNil(status.iob)
        XCTAssertNil(status.cob)
        XCTAssertFalse(status.hasData())
    }

    func testTopLevelFieldsAreParsedWithAndWithoutFractionalSeconds() throws {
        let withFraction = try status(#"{"_id":"abc","created_at":"2026-01-02T03:04:05.678Z","device":"loop://iPhone","mills":123,"utcOffset":60}"#)
        XCTAssertEqual(withFraction.id, "abc")
        XCTAssertEqual(withFraction.createdAt, date("2026-01-02T03:04:05.678Z"))
        XCTAssertEqual(withFraction.device, "loop://iPhone")
        XCTAssertEqual(withFraction.mills, 123)
        XCTAssertEqual(withFraction.utcOffset, 60)

        let withoutFraction = try status(#"{"created_at":"2026-01-02T03:04:05Z"}"#)
        XCTAssertEqual(withoutFraction.createdAt, date("2026-01-02T03:04:05Z"))

        let invalid = try status(#"{"created_at":"yesterday"}"#)
        XCTAssertEqual(invalid.createdAt, .distantPast)
    }

    func testUploaderBatteryPrefersNestedUploaderAndChargingPrefersTopLevel() throws {
        let nested = try status(#"{"uploader":{"battery":42,"isCharging":false},"uploaderBattery":99,"isCharging":true}"#)
        XCTAssertEqual(nested.uploaderBatteryPercent, 42)
        XCTAssertEqual(nested.uploaderIsCharging, true)

        let flat = try status(#"{"uploaderBattery":77,"uploader":{"isCharging":true}}"#)
        XCTAssertEqual(flat.uploaderBatteryPercent, 77)
        XCTAssertEqual(flat.uploaderIsCharging, true)
    }

    func testOpenAPSEnactedOnlyPopulatesAlgorithmValues() throws {
        let status = try status("""
        {"device":"openaps://phone","openaps":{"version":"3.2","enacted":{"timestamp":"2026-01-01T10:00:00Z","COB":12.5,"IOB":1.25,
        "current_target":110,"duration":30,"eventualBG":140,"ISF":45,"insulinReq":0.4,"rate":1.1,"reason":"COB: 12, Dev: 3",
        "sensitivityRatio":0.9,"TDD":32.1}}}
        """)
        XCTAssertEqual(status.appVersion, "3.2")
        XCTAssertEqual(status.currentTarget, 110)
        XCTAssertEqual(status.duration, 30)
        XCTAssertEqual(status.eventualBG, 140)
        XCTAssertEqual(status.isf, 45)
        XCTAssertEqual(status.insulinReq, 0.4)
        XCTAssertEqual(status.rate, 1.1)
        XCTAssertEqual(status.reason, "COB: 12, Dev: 3")
        XCTAssertEqual(status.sensitivityRatio, 0.9)
        XCTAssertEqual(status.tdd, 32.1)
        XCTAssertEqual(status.cob, 12.5)
        XCTAssertEqual(status.iob, 1.25)
        XCTAssertEqual(status.timestamp, date("2026-01-01T10:00:00Z"))
        XCTAssertEqual(status.lastLoopDate, date("2026-01-01T10:00:00Z"))
    }

    func testOpenAPSNewerSuggestedIsSelectedAndCountsAsLoopForAAPS() throws {
        let status = try status("""
        {"device":"openaps://phone","openaps":{
        "enacted":{"timestamp":"2026-01-01T10:00:00Z","rate":0.5,"IOB":1.0},
        "suggested":{"timestamp":"2026-01-01T10:05:00Z","rate":0.8,"IOB":2.0,"COB":5,"variable_sens":38}}}
        """)
        XCTAssertEqual(status.rate, 0.8)
        XCTAssertEqual(status.isf, 38)
        XCTAssertEqual(status.iob, 2.0)
        XCTAssertEqual(status.cob, 5)
        XCTAssertEqual(status.lastLoopDate, date("2026-01-01T10:05:00Z"))
    }

    func testOlderSuggestedDoesNotReplaceEnactedValues() throws {
        let status = try status("""
        {"device":"openaps://phone","openaps":{
        "enacted":{"timestamp":"2026-01-01T10:05:00Z","rate":0.5},
        "suggested":{"timestamp":"2026-01-01T10:00:00Z","rate":0.8}}}
        """)
        XCTAssertEqual(status.rate, 0.5)
        XCTAssertEqual(status.timestamp, date("2026-01-01T10:05:00Z"))
    }

    func testTrioSuggestedOnlyCountsAsLoopWhenReceived() throws {
        let notReceived = try status("""
        {"device":"Trio","openaps":{"enacted":{"timestamp":"2026-01-01T10:00:00Z"},
        "suggested":{"timestamp":"2026-01-01T10:05:00Z"}}}
        """)
        XCTAssertEqual(notReceived.lastLoopDate, date("2026-01-01T10:00:00Z"))

        let received = try status("""
        {"device":"Trio","openaps":{"enacted":{"timestamp":"2026-01-01T10:00:00Z"},
        "suggested":{"timestamp":"2026-01-01T10:05:00Z","received":true}}}
        """)
        XCTAssertEqual(received.lastLoopDate, date("2026-01-01T10:05:00Z"))

        let iAPSTypo = try status("""
        {"device":"iAPS","openaps":{"suggested":{"timestamp":"2026-01-01T10:07:00Z","recieved":true}}}
        """)
        XCTAssertEqual(iAPSTypo.lastLoopDate, date("2026-01-01T10:07:00Z"))
    }

    func testLoopPayloadIsParsed() throws {
        let status = try status("""
        {"device":"loop://iPhone","created_at":"2026-01-01T10:00:00Z","loop":{"version":"3.4","failureReason":"Pump error",
        "recommendedBolus":0.35,"predicted":{"values":[100,110,123]},
        "cob":{"cob":22,"timestamp":"2026-01-01T09:59:00Z"},"iob":{"iob":2.5,"timestamp":"2026-01-01T09:59:30Z"},
        "enacted":{"bolusVolume":0.2,"duration":30,"rate":1.4,"timestamp":"2026-01-01T09:58:00Z"},
        "timestamp":"2026-01-01T09:59:45Z"}}
        """)
        XCTAssertEqual(status.appVersion, "3.4")
        XCTAssertEqual(status.error, "Pump error")
        XCTAssertEqual(status.insulinReq, 0.35)
        XCTAssertEqual(status.eventualBG, 123)
        XCTAssertEqual(status.cob, 22)
        XCTAssertEqual(status.iob, 2.5)
        XCTAssertEqual(status.bolusVolume, 0.2)
        XCTAssertEqual(status.duration, 30)
        XCTAssertEqual(status.rate, 1.4)
        XCTAssertEqual(status.lastLoopDate, date("2026-01-01T09:59:45Z"))
    }

    func testLoopWithoutPredictionsKeepsMissingValues() throws {
        let status = try status(#"{"loop":{"predicted":{"values":[]}}}"#)
        XCTAssertNil(status.eventualBG)
        XCTAssertNil(status.cob)
        XCTAssertNil(status.iob)
        XCTAssertEqual(status.lastLoopDate, .distantPast)
    }

    func testOverrideFieldsAreParsed() throws {
        let status = try status("""
        {"override":{"active":true,"name":"Exercise","multiplier":0.8,"currentCorrectionRange":{"minValue":140,"maxValue":160}}}
        """)
        XCTAssertEqual(status.overrideActive, true)
        XCTAssertEqual(status.overrideName, "Exercise")
        XCTAssertEqual(status.overrideMultiplier, 0.8)
        XCTAssertEqual(status.overrideMinValue, 140)
        XCTAssertEqual(status.overrideMaxValue, 160)
    }

    func testPumpFieldsUseNestedStatusFallbacks() throws {
        let status = try status("""
        {"pump":{"manufacturer":"Acme","model":"X1","pumpID":"123","reservoir":87.5,"clock":"2026-01-01T10:00:00Z",
        "battery":{"percent":64},"status":{"bolusing":true,"suspended":false,"status":"normal","timestamp":"2026-01-01T10:01:00.500Z"},
        "extended":{"version":"3.1.0","ActiveProfile":"ignored","activeProfile":"Weekday","baseBasalRate":0.95}}}
        """)
        XCTAssertEqual(status.pumpManufacturer, "Acme")
        XCTAssertEqual(status.pumpModel, "X1")
        XCTAssertEqual(status.pumpID, "123")
        XCTAssertEqual(status.pumpReservoir, 87.5)
        XCTAssertEqual(status.pumpClock, date("2026-01-01T10:00:00Z"))
        XCTAssertEqual(status.pumpBatteryPercent, 64)
        XCTAssertEqual(status.pumpIsBolusing, true)
        XCTAssertEqual(status.pumpIsSuspended, false)
        XCTAssertEqual(status.pumpStatus, "normal")
        XCTAssertEqual(status.pumpStatusTimestamp, date("2026-01-01T10:01:00.500Z"))
        XCTAssertEqual(status.activeProfile, "Weekday")
        XCTAssertEqual(status.baseBasalRate, 0.95)
        XCTAssertEqual(status.appVersion, "3.1.0")
    }

    func testTopLevelPumpFlagsOverrideNestedStatusAndDisplayOverrideWins() throws {
        let status = try status("""
        {"pump":{"bolusing":false,"suspended":true,"reservoir_display_override":"50+U","status":{"bolusing":true,"suspended":false,"status":"normal"}}}
        """)
        XCTAssertEqual(status.pumpIsBolusing, false)
        XCTAssertEqual(status.pumpIsSuspended, true)
        XCTAssertEqual(status.pumpStatus, "50+U")
    }

    func testMalformedJSONTypeFailsDecoding() {
        XCTAssertThrowsError(try response(#"{"mills":"not a number"}"#))
        XCTAssertThrowsError(try response("[]"))
    }

    // MARK: - Device helpers

    func testSystemNameIconAndDeviceName() {
        var status = NightscoutDeviceStatus()
        XCTAssertNil(status.systemName())
        XCTAssertNil(status.systemIcon())
        XCTAssertNil(status.deviceName())

        let cases: [(String, String?)] = [("loop://iPhone", "Loop"), ("openaps://samsung", "AAPS"), ("Trio", "Trio"), ("iAPS", "iAPS"), ("unknown", nil)]
        for (device, name) in cases {
            status.device = device
            XCTAssertEqual(status.systemName(), name, device)
            XCTAssertEqual(status.systemIcon() != nil, name != nil, device)
        }

        status.device = "openaps://SAMSUNG galaxy"
        XCTAssertEqual(status.deviceName(), "Samsung galaxy")
        status.device = "Trio"
        XCTAssertNil(status.deviceName())
    }

    func testUseSuggestedAsEnactedOnlyFalseForTrioAndIAPS() {
        var status = NightscoutDeviceStatus()
        XCTAssertTrue(status.useSuggestedAsEnacted())
        for device in ["Trio", "iAPS"] {
            status.device = device
            XCTAssertFalse(status.useSuggestedAsEnacted())
        }
        status.device = "openaps://x"
        XCTAssertTrue(status.useSuggestedAsEnacted())
    }

    func testReasonValuesArrayDecodesHTMLEntitiesAndSplits() {
        var status = NightscoutDeviceStatus()
        XCTAssertNil(status.reasonValuesArray())
        status.reason = "BG &lt; 70, Dev &gt; 5, ISF &le; 40, CR &ge; 10"
        XCTAssertEqual(status.reasonValuesArray(), ["BG < 70", "Dev > 5", "ISF <= 40", "CR >= 10"])
    }

    func testBatteryImageUsesSharedBuckets() {
        let status = NightscoutDeviceStatus()
        XCTAssertNil(status.batteryImage(percent: nil))
        XCTAssertEqual(status.batteryImage(percent: 5)?.color, .red)
        XCTAssertEqual(status.batteryImage(percent: 20)?.color, .yellow)
        XCTAssertNotNil(status.batteryImage(percent: 90))
    }

    func testUploaderBatteryWarningsOnlyWhenNotCharging() {
        var status = NightscoutDeviceStatus()
        XCTAssertNil(status.uploaderBatteryImageRVCStatusView())
        XCTAssertNil(status.uploaderBatteryStatusStyle())

        status.uploaderBatteryPercent = 8
        status.uploaderIsCharging = true
        XCTAssertNil(status.uploaderBatteryImageRVCStatusView())
        XCTAssertNil(status.uploaderBatteryStatusStyle())

        status.uploaderIsCharging = false
        XCTAssertEqual(status.uploaderBatteryImageRVCStatusView()?.batteryImageColor, UIColor(.red))
        XCTAssertEqual(status.uploaderBatteryStatusStyle()?.color, ConstantsAppColors.urgent)

        status.uploaderBatteryPercent = 20
        XCTAssertEqual(status.uploaderBatteryImageRVCStatusView()?.batteryImageColor, UIColor(.yellow))
        XCTAssertEqual(status.uploaderBatteryStatusStyle()?.color, ConstantsAppColors.warning)

        status.uploaderBatteryPercent = 80
        XCTAssertNil(status.uploaderBatteryImageRVCStatusView())
        XCTAssertNil(status.uploaderBatteryStatusStyle())

        if #available(iOS 17.0, *) {
            status.uploaderBatteryPercent = 3
            XCTAssertEqual(status.uploaderBatteryStatusStyle()?.systemImage, "battery.0percent")
            status.uploaderBatteryPercent = 25
            XCTAssertEqual(status.uploaderBatteryStatusStyle()?.systemImage, "battery.25percent")
        }
    }

    func testUploaderChargingImageOnlyWhileCharging() {
        var status = NightscoutDeviceStatus()
        XCTAssertNil(status.uploaderBatteryChargingImage())
        status.uploaderIsCharging = false
        XCTAssertNil(status.uploaderBatteryChargingImage())
        status.uploaderIsCharging = true
        XCTAssertEqual(status.uploaderBatteryChargingImage()?.color, Color(.systemGreen))
    }

    func testPumpReservoirColorThresholds() {
        var status = NightscoutDeviceStatus()
        XCTAssertNil(status.pumpReservoirColor())
        XCTAssertNil(status.pumpReservoirUIColor())
        status.pumpReservoir = ConstantsHomeView.pumpReservoirUrgent - 0.1
        XCTAssertEqual(status.pumpReservoirColor(), .red)
        XCTAssertEqual(status.pumpReservoirUIColor(), .systemRed)
        status.pumpReservoir = ConstantsHomeView.pumpReservoirUrgent
        XCTAssertEqual(status.pumpReservoirColor(), .yellow)
        XCTAssertEqual(status.pumpReservoirUIColor(), .systemYellow)
        status.pumpReservoir = ConstantsHomeView.pumpReservoirWarning
        XCTAssertNil(status.pumpReservoirColor())
        XCTAssertNil(status.pumpReservoirUIColor())
    }

    func testPumpBatteryColorThresholds() {
        var status = NightscoutDeviceStatus()
        XCTAssertNil(status.pumpBatteryPercentColor())
        XCTAssertNil(status.pumpBatteryPercentUIColor())
        status.pumpBatteryPercent = ConstantsHomeView.pumpBatteryPercentUrgent - 1
        XCTAssertEqual(status.pumpBatteryPercentColor(), .red)
        XCTAssertEqual(status.pumpBatteryPercentUIColor(), .systemRed)
        status.pumpBatteryPercent = ConstantsHomeView.pumpBatteryPercentUrgent
        XCTAssertEqual(status.pumpBatteryPercentColor(), .yellow)
        XCTAssertEqual(status.pumpBatteryPercentUIColor(), .systemYellow)
        status.pumpBatteryPercent = ConstantsHomeView.pumpBatteryPercentWarning
        XCTAssertNil(status.pumpBatteryPercentColor())
        XCTAssertNil(status.pumpBatteryPercentUIColor())
    }

    // MARK: - AID status

    func testAIDStatusIsCheckingUntilFirstCheck() {
        let status = NightscoutDeviceStatus()
        let aid = status.aidStatus
        XCTAssertEqual(aid.condition, .checking)
        XCTAssertEqual(aid.style, .loop)
        XCTAssertNil(aid.statusUpdatedAt)
        XCTAssertNil(aid.lastActivityAt)
        XCTAssertEqual(aid.statusTitle, Texts_Common.checking)
        XCTAssertEqual(status.deviceStatusTitle(), aid.presentation().title)
    }

    func testAIDStatusIsActiveWithDatesAndValues() {
        let now = Date()
        var status = NightscoutDeviceStatus()
        status.lastCheckedDate = now
        status.createdAt = now.addingTimeInterval(-60)
        status.lastLoopDate = now.addingTimeInterval(-90)
        status.iob = 1.5
        status.cob = 20
        let aid = status.aidStatus
        XCTAssertEqual(aid.condition, .active)
        XCTAssertEqual(aid.statusUpdatedAt, status.createdAt)
        XCTAssertEqual(aid.lastActivityAt, status.lastLoopDate)
        XCTAssertEqual(aid.iob, 1.5)
        XCTAssertEqual(aid.cob, 20)
        XCTAssertEqual(aid.statusTitle, "Looping")
        XCTAssertEqual(aid.staleStatusTitle, "No data")
        XCTAssertEqual(status.deviceStatusColor(referenceDate: now), aid.presentation(referenceDate: now).color)
        XCTAssertEqual(status.deviceStatusUIColor(referenceDate: now), UIColor(aid.presentation(referenceDate: now).color))
        XCTAssertEqual(status.deviceStatusBannerBackgroundColor(referenceDate: now), aid.presentation(referenceDate: now).color.opacity(ConstantsHomeView.AIDStatusBannerBackgroundOpacity))
        XCTAssertEqual(status.deviceStatusIconImage().symbol, aid.presentation().symbol ?? .loopUnavailable)
    }

    // MARK: - Merging, sanitizing and change detection

    func testFillMissingDisplayValuesOnlyFillsNilFields() {
        var newest = NightscoutDeviceStatus()
        newest.rate = 0.4
        newest.iob = nil
        var fallback = NightscoutDeviceStatus()
        fallback.device = "loop://x"
        fallback.appVersion = "1"
        fallback.activeProfile = "P"
        fallback.baseBasalRate = 1
        fallback.bolusVolume = 2
        fallback.cob = 3
        fallback.currentTarget = 4
        fallback.duration = 5
        fallback.eventualBG = 6
        fallback.iob = 7
        fallback.isf = 8
        fallback.insulinReq = 9
        fallback.rate = 10
        fallback.reason = "r"
        fallback.sensitivityRatio = 11
        fallback.tdd = 12
        fallback.timestamp = Date(timeIntervalSince1970: 1)
        fallback.error = "e"
        fallback.overrideActive = true
        fallback.overrideName = "o"
        fallback.overrideMaxValue = 13
        fallback.overrideMinValue = 14
        fallback.overrideMultiplier = 15
        fallback.pumpBatteryPercent = 16
        fallback.pumpClock = Date(timeIntervalSince1970: 2)
        fallback.pumpID = "id"
        fallback.pumpIsBolusing = true
        fallback.pumpIsSuspended = false
        fallback.pumpStatus = "s"
        fallback.pumpStatusTimestamp = Date(timeIntervalSince1970: 3)
        fallback.pumpManufacturer = "m"
        fallback.pumpModel = "mod"
        fallback.pumpReservoir = 17
        fallback.uploaderBatteryPercent = 18
        fallback.uploaderIsCharging = true
        fallback.lastLoopDate = Date(timeIntervalSince1970: 4)

        newest.fillMissingDisplayValues(from: fallback)
        XCTAssertEqual(newest.rate, 0.4)
        XCTAssertEqual(newest.iob, 7)
        XCTAssertEqual(newest.device, "loop://x")
        XCTAssertEqual(newest.appVersion, "1")
        XCTAssertEqual(newest.activeProfile, "P")
        XCTAssertEqual(newest.baseBasalRate, 1)
        XCTAssertEqual(newest.bolusVolume, 2)
        XCTAssertEqual(newest.cob, 3)
        XCTAssertEqual(newest.currentTarget, 4)
        XCTAssertEqual(newest.duration, 5)
        XCTAssertEqual(newest.eventualBG, 6)
        XCTAssertEqual(newest.isf, 8)
        XCTAssertEqual(newest.insulinReq, 9)
        XCTAssertEqual(newest.reason, "r")
        XCTAssertEqual(newest.sensitivityRatio, 11)
        XCTAssertEqual(newest.tdd, 12)
        XCTAssertEqual(newest.timestamp, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(newest.error, "e")
        XCTAssertEqual(newest.overrideActive, true)
        XCTAssertEqual(newest.overrideName, "o")
        XCTAssertEqual(newest.overrideMaxValue, 13)
        XCTAssertEqual(newest.overrideMinValue, 14)
        XCTAssertEqual(newest.overrideMultiplier, 15)
        XCTAssertEqual(newest.pumpBatteryPercent, 16)
        XCTAssertEqual(newest.pumpClock, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(newest.pumpID, "id")
        XCTAssertEqual(newest.pumpIsBolusing, true)
        XCTAssertEqual(newest.pumpIsSuspended, false)
        XCTAssertEqual(newest.pumpStatus, "s")
        XCTAssertEqual(newest.pumpStatusTimestamp, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(newest.pumpManufacturer, "m")
        XCTAssertEqual(newest.pumpModel, "mod")
        XCTAssertEqual(newest.pumpReservoir, 17)
        XCTAssertEqual(newest.uploaderBatteryPercent, 18)
        XCTAssertEqual(newest.uploaderIsCharging, true)
        XCTAssertEqual(newest.lastLoopDate, Date(timeIntervalSince1970: 4))
    }

    func testFillMissingKeepsExistingLastLoopDate() {
        var newest = NightscoutDeviceStatus()
        newest.lastLoopDate = Date(timeIntervalSince1970: 100)
        var fallback = NightscoutDeviceStatus()
        fallback.lastLoopDate = Date(timeIntervalSince1970: 200)
        newest.fillMissingDisplayValues(from: fallback)
        XCTAssertEqual(newest.lastLoopDate, Date(timeIntervalSince1970: 100))
    }

    func testComposingDisplayValuesUsesNewestFirstPrecedence() throws {
        XCTAssertNil(NightscoutDeviceStatus.composingDisplayValues(fromNewestFirst: []))
        var newest = NightscoutDeviceStatus()
        newest.id = "newest"
        newest.rate = 1
        var middle = NightscoutDeviceStatus()
        middle.pumpReservoir = 50
        middle.iob = 2
        var oldest = NightscoutDeviceStatus()
        oldest.pumpReservoir = 80
        oldest.pumpBatteryPercent = 40
        let composed = try XCTUnwrap(NightscoutDeviceStatus.composingDisplayValues(fromNewestFirst: [newest, middle, oldest]))
        XCTAssertEqual(composed.id, "newest")
        XCTAssertEqual(composed.rate, 1)
        XCTAssertEqual(composed.pumpReservoir, 50)
        XCTAssertEqual(composed.iob, 2)
        XCTAssertEqual(composed.pumpBatteryPercent, 40)
    }

    func testSanitizingFutureDatesClearsOnlyDatesBeyondTolerance() {
        let reference = Date(timeIntervalSince1970: 1_000_000)
        var status = NightscoutDeviceStatus()
        status.createdAt = reference.addingTimeInterval(21)
        status.updatedDate = reference.addingTimeInterval(20)
        status.lastCheckedDate = reference.addingTimeInterval(3600)
        status.lastLoopDate = reference.addingTimeInterval(-60)
        status.timestamp = reference.addingTimeInterval(100)
        status.sanitizingFutureDates(referenceDate: reference)
        XCTAssertEqual(status.createdAt, .distantPast)
        XCTAssertEqual(status.updatedDate, reference.addingTimeInterval(20))
        XCTAssertEqual(status.lastCheckedDate, .distantPast)
        XCTAssertEqual(status.lastLoopDate, reference.addingTimeInterval(-60))
        XCTAssertNil(status.timestamp)

        var lenient = NightscoutDeviceStatus()
        lenient.lastLoopDate = reference.addingTimeInterval(50)
        lenient.sanitizingFutureDates(referenceDate: reference, futureTolerance: 60)
        XCTAssertEqual(lenient.lastLoopDate, reference.addingTimeInterval(50))
    }

    func testHasPersistedChangesIgnoresPollAndRawFields() {
        var base = NightscoutDeviceStatus()
        base.id = "a"
        base.iob = 1
        var other = base
        other.updatedDate = Date()
        other.lastCheckedDate = Date()
        other.mills = 99
        other.pumpClock = Date()
        other.pumpID = "x"
        other.baseBasalRate = 3
        other.utcOffset = 120
        XCTAssertFalse(base.hasPersistedChanges(comparedTo: other))

        var changedIOB = base
        changedIOB.iob = 1.05
        XCTAssertTrue(base.hasPersistedChanges(comparedTo: changedIOB))

        var changedPump = base
        changedPump.pumpReservoir = 10
        XCTAssertTrue(base.hasPersistedChanges(comparedTo: changedPump))

        var changedUploader = base
        changedUploader.uploaderIsCharging = false
        XCTAssertTrue(base.hasPersistedChanges(comparedTo: changedUploader))
    }

    func testDeviceStatusRoundTripsThroughCodable() throws {
        var status = NightscoutDeviceStatus()
        status.id = "abc"
        status.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        status.iob = 2.5
        status.pumpIsSuspended = true
        status.reason = "x"
        let decoded = try JSONDecoder().decode(NightscoutDeviceStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertEqual(decoded.createdAt, status.createdAt)
        XCTAssertEqual(decoded.iob, 2.5)
        XCTAssertEqual(decoded.pumpIsSuspended, true)
        XCTAssertFalse(decoded.hasPersistedChanges(comparedTo: status))
    }

    func testISO8601FormattersUseUTC() {
        let date = Date(timeIntervalSince1970: 0.25)
        XCTAssertEqual(ISO8601DateFormatter.withFractionalSeconds.string(from: date), "1970-01-01T00:00:00.250Z")
        XCTAssertEqual(ISO8601DateFormatter.withoutFractionalSeconds.string(from: date), "1970-01-01T00:00:00Z")
    }
}
