//
//  CalendarShareEventLocationTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Tests for the location of the Calendar Share event.
///
/// Issue #269: Apple Watch faces that show the next calendar event also show its location, and
/// look bare without one. The event never had a location, so users asked for their own text there,
/// such as "Latest reading", "Blood glucose" or an emoji.
final class CalendarShareEventLocationTests: XCTestCase {

    // MARK: - custom text (#269)

    func testCustomTextIsUsedAsEventLocation() {
        XCTAssertEqual(CalendarShareEventLocation.location(customText: "Blood glucose"), "Blood glucose")
        XCTAssertEqual(CalendarShareEventLocation.location(customText: "🩸"), "🩸")
    }

    func testSurroundingWhitespaceIsRemoved() {
        XCTAssertEqual(CalendarShareEventLocation.location(customText: "  Latest reading \n"), "Latest reading")
    }

    // MARK: - no custom text

    func testEventHasNoLocationWithoutCustomText() {
        XCTAssertNil(CalendarShareEventLocation.location(customText: nil))
        XCTAssertNil(CalendarShareEventLocation.location(customText: ""))
        XCTAssertNil(CalendarShareEventLocation.location(customText: "   "))
    }
}
