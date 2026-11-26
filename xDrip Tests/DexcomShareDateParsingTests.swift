//
//  DexcomShareDateParsingTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for reading the dates of Dexcom Share readings.
///
/// ST and WT carry only the UTC milliseconds. DT, the fallback when ST cannot be read, also carries the
/// offset of the uploader's local time, which is "+" east of UTC. That "+0100" was glued onto the
/// milliseconds, which gave a date many thousands of years ahead.
final class DexcomShareDateParsingTests: XCTestCase {

    private func parse(_ text: String) -> Date? {
        DexcomShareFollowManager.parseDexcomDate(dexcomDateString: text)
    }

    func testDateWithoutOffset() {
        XCTAssertEqual(parse("Date(1800000000000)"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(parse("/Date(1800000000000)/"), Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testOffsetWestOfUTCIsIgnored() {
        XCTAssertEqual(parse("/Date(1800000000000-0700)/"), Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testOffsetEastOfUTCIsIgnored() {
        XCTAssertEqual(parse("Date(1800000000000+0100)"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(parse("/Date(1800000000000+0530)/"), Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testTextWithoutANumberIsNotADate() {
        XCTAssertNil(parse("nope"))
        XCTAssertNil(parse(""))
    }
}
