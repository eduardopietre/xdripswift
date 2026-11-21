//
//  AppCoverageSpeechAndCalendarTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class AppCoverageSpeechAndCalendarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        appCoverageIsolateDefaults()
        let defaults = UserDefaults.standard
        defaults.bloodGlucoseUnitIsMgDl = true
        defaults.speakIntroduction = false
        defaults.speakTrend = false
        defaults.speakDelta = false
        defaults.displayVisualIndicatorInCalendarEvent = false
        defaults.displayTrendInCalendarEvent = false
        defaults.displayDeltaInCalendarEvent = false
        defaults.displayUnitInCalendarEvent = false
        defaults.set(55.0, forKey: UserDefaults.Key.urgentLowMarkValue.rawValue)
        defaults.set(70.0, forKey: UserDefaults.Key.lowMarkValue.rawValue)
        defaults.set(180.0, forKey: UserDefaults.Key.highMarkValue.rawValue)
        defaults.set(250.0, forKey: UserDefaults.Key.urgentHighMarkValue.rawValue)
        Texts_SpeakReading.setLanguageCode(code: "en")
        addTeardownBlock { Texts_SpeakReading.setLanguageCode(code: UserDefaults.standard.speakReadingLanguageCode) }
    }

    // MARK: - Speech text

    func testSpeechTextWithOnlyGlucose() {
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "120", trend: "Flat", delta: "+2"), "120. ")
    }

    func testSpeechTextAddsIntroduction() {
        UserDefaults.standard.speakIntroduction = true
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "120", trend: "Flat", delta: "+2"), Texts_SpeakReading.currentGlucose + " ,, 120. ")
    }

    func testMmolValuesAlwaysHaveAFractionalDigit() {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "6", trend: "", delta: ""), "6.0. ")
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "6.5", trend: "", delta: ""), "6.5. ")
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "HIGH", trend: "", delta: ""), ". " + Texts_SpeakReading.high + ". ")
    }

    func testHighAndLowAreSpokenAsWords() {
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "HIGH", trend: "", delta: ""), ". " + Texts_SpeakReading.high + ". ")
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "LOW", trend: "", delta: ""), ". " + Texts_SpeakReading.low + ". ")
    }

    func testTrendNamesAreTranslated() {
        UserDefaults.standard.speakTrend = true
        let expected: [String: String] = [
            "NONE": Texts_SpeakReading.trendnoncomputable,
            "NON COMPUTABLE": Texts_SpeakReading.trendnoncomputable,
            "DoubleDown": Texts_SpeakReading.trenddoubledown,
            "SingleDown": Texts_SpeakReading.trendsingledown,
            "FortyFiveDown": Texts_SpeakReading.trendfortyfivedown,
            "Flat": Texts_SpeakReading.trendflat,
            "FortyFiveUp": Texts_SpeakReading.trendfortyfiveup,
            "SingleUp": Texts_SpeakReading.trendsingleup,
            "DoubleUp": Texts_SpeakReading.trenddoubleup,
            "Sideways": "Sideways"
        ]
        for (trend, word) in expected {
            XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "100", trend: trend, delta: ""), "100. " + Texts_SpeakReading.currentTrend + " " + word + ". ", trend)
        }
    }

    func testDeltaNormalisesZeroAndErrors() {
        UserDefaults.standard.speakDelta = true
        let prefix = "100. " + Texts_SpeakReading.currentDelta + " "
        XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "100", trend: "", delta: "+3"), prefix + "+3.")
        for zero in ["0.0", "+0", "-0"] {
            XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "100", trend: "", delta: zero), prefix + "0.")
        }
        for error in ["ERR", "???"] {
            XCTAssertEqual(BGReadingSpeaker.speechText(glucose: "100", trend: "", delta: error), prefix + Texts_SpeakReading.deltanoncomputable + ".")
        }
    }

    func testPreviewUsesSampleWithoutRecentReading() {
        XCTAssertEqual(BGReadingSpeaker.previewText(coreDataManager: nil), "100. ")
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        XCTAssertEqual(BGReadingSpeaker.previewText(coreDataManager: nil), "5.6. ")
        let core = AppCoverageFactory.coreData()
        AppCoverageFactory.reading(150, at: Date().addingTimeInterval(-12 * 60), in: core)
        XCTAssertEqual(BGReadingSpeaker.previewText(coreDataManager: core), "5.6. ", "Readings older than 11 minutes are not previewed")
    }

    func testPreviewUsesLatestRecentReading() {
        let core = AppCoverageFactory.coreData()
        AppCoverageFactory.reading(130, at: Date().addingTimeInterval(-60), in: core)
        XCTAssertEqual(BGReadingSpeaker.previewText(coreDataManager: core), "130. ")
    }

    func testLanguageCodeFallsBackToBaseLanguageOrEnglish() {
        Texts_SpeakReading.setLanguageCode(code: "nl")
        XCTAssertEqual(Texts_SpeakReading.languageCode, "nl")
        Texts_SpeakReading.setLanguageCode(code: "xx-YY")
        XCTAssertEqual(Texts_SpeakReading.languageCode, "xx")
        Texts_SpeakReading.setLanguageCode(code: nil)
        XCTAssertEqual(Texts_SpeakReading.languageCode, Texts_SpeakReading.defaultLanguageCode)
    }

    func testSpeakLanguagesSplitIntoNamesAndCodes() {
        let all = ConstantsSpeakReadingLanguages.allLanguageNamesAndCodes
        XCTAssertEqual(all.names.count, ConstantsSpeakReadingLanguages.allCases.count)
        XCTAssertEqual(all.codes.count, all.names.count)
        XCTAssertTrue(all.codes.contains("en"))
        XCTAssertEqual(ConstantsSpeakReadingLanguages.languageName(forLanguageCode: "pt-BR"), "Portuguese (Brazil)")
        XCTAssertEqual(ConstantsSpeakReadingLanguages.languageName(forLanguageCode: "nl"), "Dutch")
    }

    // MARK: - Calendar share payload

    func testPayloadRoundTripsThroughCalendarNotes() throws {
        let core = AppCoverageFactory.coreData()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = AppCoverageFactory.reading(140, at: now, in: core)
        let older = AppCoverageFactory.reading(130, at: now.addingTimeInterval(-300), in: core)
        let oldest = AppCoverageFactory.reading(120, at: now.addingTimeInterval(-600), in: core)
        let zero = AppCoverageFactory.reading(0, at: now.addingTimeInterval(-900), in: core)
        let payload = CalendarSharePayload(reading: current, historyReadings: [current, older, oldest, zero], sourceAlias: "Phone")
        XCTAssertEqual(payload.history?.count, 2, "Current and zero readings are excluded from history")
        let notes = try XCTUnwrap(payload.encodedNotes())
        XCTAssertTrue(notes.hasPrefix(ConstantsCalendar.calendarSharePayloadPrefix))
        let decoded = try XCTUnwrap(CalendarSharePayload.decode(from: "Visible text\n" + notes + "\n"))
        XCTAssertEqual(decoded.sourceAlias, "Phone")
        XCTAssertEqual(decoded.bgMgDl, 140)
        XCTAssertEqual(decoded.timestampMillis, 1_800_000_000_000)
        XCTAssertEqual(decoded.followerBgReading.timeStamp, now)
        XCTAssertEqual(decoded.followerBgReadings.map(\.sgv), [140, 130, 120])
        XCTAssertEqual(decoded.historicalFollowerBgReadings.map(\.sgv), [130, 120])
    }

    func testFollowerReadingsAreSortedAndDeduplicated() throws {
        let json = #"{"version":1,"timestampMillis":2000,"bgMgDl":100,"sourceAlias":"A","history":[{"timestampMillis":1000,"bgMgDl":90},{"timestampMillis":2000,"bgMgDl":95},{"timestampMillis":3000,"bgMgDl":110}]}"#
        let notes = ConstantsCalendar.calendarSharePayloadPrefix + Data(json.utf8).base64EncodedString()
        let payload = try XCTUnwrap(CalendarSharePayload.decode(from: notes))
        XCTAssertEqual(payload.followerBgReadings.map(\.timeStamp.timeIntervalSince1970), [3, 2, 1])
        XCTAssertNil(payload.appVersion)
    }

    func testDecodeRejectsInvalidNotes() {
        let prefix = ConstantsCalendar.calendarSharePayloadPrefix
        func notes(_ json: String) -> String { prefix + Data(json.utf8).base64EncodedString() }
        XCTAssertNil(CalendarSharePayload.decode(from: nil))
        XCTAssertNil(CalendarSharePayload.decode(from: "no payload here"))
        XCTAssertNil(CalendarSharePayload.decode(from: prefix + "not base64!"))
        XCTAssertNil(CalendarSharePayload.decode(from: notes(#"{"version":2,"timestampMillis":1,"bgMgDl":100,"sourceAlias":"A"}"#)))
        XCTAssertNil(CalendarSharePayload.decode(from: notes(#"{"version":1,"timestampMillis":1,"bgMgDl":0,"sourceAlias":"A"}"#)))
        XCTAssertNil(CalendarSharePayload.decode(from: notes(#"{"version":1,"timestampMillis":1,"bgMgDl":100,"sourceAlias":"A","history":[{"timestampMillis":0,"bgMgDl":0}]}"#)))
        XCTAssertNotNil(CalendarSharePayload.decode(from: notes(#"{"version":1,"timestampMillis":1,"bgMgDl":100,"sourceAlias":"A"}"#)))
    }

    // MARK: - Calendar title

    func testTitleWithoutOptionsIsJustTheValue() {
        let core = AppCoverageFactory.coreData()
        let reading = AppCoverageFactory.reading(123, at: Date(), in: core)
        XCTAssertEqual(CalendarShareEventTitleFormatter.title(reading: reading, previousReading: nil), "123")
    }

    func testTitleAddsIndicatorTrendDeltaAndUnit() {
        let core = AppCoverageFactory.coreData()
        let previous = AppCoverageFactory.reading(115, at: Date().addingTimeInterval(-300), in: core)
        let reading = AppCoverageFactory.reading(123, at: Date(), in: core, slope: 0.00003)
        let defaults = UserDefaults.standard
        defaults.displayVisualIndicatorInCalendarEvent = true
        XCTAssertEqual(CalendarShareEventTitleFormatter.title(reading: reading, previousReading: nil), ConstantsCalendar.visualIndicatorInRange + " 123")
        defaults.displayVisualIndicatorInCalendarEvent = false
        defaults.displayTrendInCalendarEvent = true
        XCTAssertEqual(CalendarShareEventTitleFormatter.title(reading: reading, previousReading: nil), "123 " + reading.slopeArrow())
        defaults.displayTrendInCalendarEvent = false
        defaults.displayUnitInCalendarEvent = true
        XCTAssertEqual(CalendarShareEventTitleFormatter.title(reading: reading, previousReading: nil), "123 " + Texts_Common.mgdl)
        defaults.displayDeltaInCalendarEvent = true
        let delta = reading.unitizedDeltaString(previousBgReading: previous, showUnit: true, highGranularity: true, mgDl: true)
        XCTAssertEqual(CalendarShareEventTitleFormatter.title(reading: reading, previousReading: previous), "123 " + delta)
    }

    func testTitleIndicatorFollowsRange() {
        let core = AppCoverageFactory.coreData()
        UserDefaults.standard.displayVisualIndicatorInCalendarEvent = true
        let high = AppCoverageFactory.reading(200, at: Date(), in: core)
        let urgent = AppCoverageFactory.reading(40, at: Date(), in: core)
        XCTAssertTrue(CalendarShareEventTitleFormatter.title(reading: high, previousReading: nil).hasPrefix(ConstantsCalendar.visualIndicatorNotUrgent))
        XCTAssertTrue(CalendarShareEventTitleFormatter.title(reading: urgent, previousReading: nil).hasPrefix(ConstantsCalendar.visualIndicatorUrgent))
    }

    func testTitleHidesTrendWhenSlopeIsHidden() {
        let core = AppCoverageFactory.coreData()
        UserDefaults.standard.displayTrendInCalendarEvent = true
        let reading = AppCoverageFactory.reading(123, at: Date(), in: core, hideSlope: true)
        XCTAssertEqual(CalendarShareEventTitleFormatter.title(reading: reading, previousReading: nil), "123")
    }

    func testPreviewTitleUsesFixedSample() {
        let defaults = UserDefaults.standard
        XCTAssertEqual(CalendarShareEventTitleFormatter.previewTitle(), "123")
        defaults.displayVisualIndicatorInCalendarEvent = true
        defaults.displayTrendInCalendarEvent = true
        defaults.displayDeltaInCalendarEvent = true
        XCTAssertEqual(CalendarShareEventTitleFormatter.previewTitle(), ConstantsCalendar.visualIndicatorInRange + " 123 ↗ +2")
        defaults.displayUnitInCalendarEvent = true
        XCTAssertEqual(CalendarShareEventTitleFormatter.previewTitle(), ConstantsCalendar.visualIndicatorInRange + " 123 ↗ +2 " + Texts_Common.mgdl)
        defaults.displayDeltaInCalendarEvent = false
        XCTAssertEqual(CalendarShareEventTitleFormatter.previewTitle(), ConstantsCalendar.visualIndicatorInRange + " 123 ↗ " + Texts_Common.mgdl)
    }

    func testPreviewIndicatorFollowsConfiguredLimits() {
        UserDefaults.standard.displayVisualIndicatorInCalendarEvent = true
        UserDefaults.standard.set(120.0, forKey: UserDefaults.Key.highMarkValue.rawValue)
        XCTAssertTrue(CalendarShareEventTitleFormatter.previewTitle().hasPrefix(ConstantsCalendar.visualIndicatorNotUrgent))
        UserDefaults.standard.set(123.0, forKey: UserDefaults.Key.urgentHighMarkValue.rawValue)
        XCTAssertTrue(CalendarShareEventTitleFormatter.previewTitle().hasPrefix(ConstantsCalendar.visualIndicatorUrgent))
    }

    func testPreviewTitleInMmol() {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl = false
        UserDefaults.standard.displayDeltaInCalendarEvent = true
        let title = CalendarShareEventTitleFormatter.previewTitle()
        XCTAssertTrue(title.hasPrefix("6.8 +"), title)
    }
}
