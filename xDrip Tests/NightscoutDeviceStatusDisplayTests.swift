//
//  NightscoutDeviceStatusDisplayTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the AID values shown from Nightscout device status documents.
///
/// - an error of an older Loop run stayed on the newest, successful status
/// - openAPS COB and IOB came from suggested even when enacted was newer
/// - Trio and iAPS showed the rate of a suggestion they did not receive as the running temp basal
/// - suggested and enacted timestamps were compared as text, which gives the wrong order for different formats
final class NightscoutDeviceStatusDisplayTests: XCTestCase {

    private func status(_ json: String) throws -> NightscoutDeviceStatus {
        NightscoutDeviceStatus(from: try JSONDecoder().decode(NightscoutDeviceStatusResponse.self, from: Data(json.utf8)))
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter.withFractionalSeconds.date(from: iso) ?? ISO8601DateFormatter.withoutFractionalSeconds.date(from: iso)!
    }

    /// Loop leaves failureReason out when a run succeeds. The error of an older run used to be copied
    /// onto the newest, successful status, so a resolved "Pump error" kept showing.
    func testFillMissingDoesNotTakeTheErrorOfAnotherLoopRun() {
        var newest = NightscoutDeviceStatus()
        newest.lastLoopDate = Date(timeIntervalSince1970: 200)
        var olderRun = NightscoutDeviceStatus()
        olderRun.lastLoopDate = Date(timeIntervalSince1970: 100)
        olderRun.error = "Pump error"
        olderRun.reason = "old reason"
        olderRun.iob = 1.5

        newest.fillMissingDisplayValues(from: olderRun)
        XCTAssertNil(newest.error)
        XCTAssertNil(newest.reason)
        XCTAssertEqual(newest.iob, 1.5, "other missing values are still filled")

        var sameRun = NightscoutDeviceStatus()
        sameRun.lastLoopDate = Date(timeIntervalSince1970: 200)
        sameRun.error = "Pump error"
        newest.fillMissingDisplayValues(from: sameRun)
        XCTAssertEqual(newest.error, "Pump error")
    }

    /// A document without a loop run of its own (heartbeat-like) still takes the error of the fallback.
    func testFillMissingTakesTheErrorWhenThereIsNoLoopRun() {
        var heartbeat = NightscoutDeviceStatus()
        var fallback = NightscoutDeviceStatus()
        fallback.lastLoopDate = Date(timeIntervalSince1970: 100)
        fallback.error = "Pump error"
        heartbeat.fillMissingDisplayValues(from: fallback)
        XCTAssertEqual(heartbeat.error, "Pump error")
    }

    /// COB and IOB come from the newer of enacted and suggested. An older suggestion used to win,
    /// so a stale COB and IOB were shown next to a newer enacted temp basal.
    func testCOBAndIOBComeFromTheNewerOfEnactedAndSuggested() throws {
        let olderSuggestion = try status("""
        {"device":"Trio","openaps":{"enacted":{"timestamp":"2026-01-01T10:10:00Z","COB":1,"IOB":1},
        "suggested":{"timestamp":"2026-01-01T10:00:00Z","COB":9,"IOB":3}}}
        """)
        XCTAssertEqual(olderSuggestion.cob, 1)
        XCTAssertEqual(olderSuggestion.iob, 1)

        let newerSuggestion = try status("""
        {"device":"Trio","openaps":{"enacted":{"timestamp":"2026-01-01T10:00:00Z","COB":1,"IOB":1},
        "suggested":{"timestamp":"2026-01-01T10:10:00Z","COB":9,"IOB":3}}}
        """)
        XCTAssertEqual(newerSuggestion.cob, 9, "valid also when the suggested temp basal was not received")
        XCTAssertEqual(newerSuggestion.iob, 3)
    }

    /// The timestamps are compared as dates: as text, "10:05:00Z" sorts after "10:05:00.500Z".
    func testSuggestedAndEnactedWithDifferentTimestampFormatsAreComparedAsDates() throws {
        let status = try status("""
        {"device":"openaps://phone","openaps":{
        "enacted":{"timestamp":"2026-01-01T10:05:00.500Z","rate":0.5},
        "suggested":{"timestamp":"2026-01-01T10:05:00Z","rate":0.8}}}
        """)
        XCTAssertEqual(status.rate, 0.5)
    }

    /// Trio does not enact a suggestion it did not receive, so the enacted temp basal is still running.
    func testTrioUnreceivedSuggestionShowsTheEnactedTempBasal() throws {
        let status = try status("""
        {"device":"Trio","openaps":{
          "enacted":{"timestamp":"2024-11-23T09:55:00Z","received":true,"rate":0.4},
          "suggested":{"timestamp":"2024-11-23T10:00:00Z","received":false,"rate":0.6}}}
        """)
        XCTAssertEqual(status.systemName(), "Trio")
        XCTAssertEqual(status.rate, 0.4, "a suggestion Trio did not receive is not running; the enacted temp basal is")
        XCTAssertEqual(status.lastLoopDate, date("2024-11-23T09:55:00Z"))
    }
}
