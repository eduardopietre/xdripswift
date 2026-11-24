//
//  BgReadingAlertBodyTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Tests for the text of the alerts about a glucose value.
///
/// Issue #337: when a fast rise or fast drop alert fires, users who cannot look at the phone want
/// to know how fast the glucose is changing. The alert only gave the glucose value and arrow, not
/// the delta that triggered it, so the alert read aloud (Announce Notifications on AirPods or
/// CarPlay) or glanced at on a watch did not say how big the change was.
final class BgReadingAlertBodyTests: XCTestCase {

    // MARK: - delta (#337)

    func testDeltaIsAddedAfterValueAndArrow() {
        XCTAssertEqual(BgReadingAlertBody.text(value: "9.2", slopeArrow: "↑", delta: "+0.7 mmol/L"), " 9.2 ↑ +0.7 mmol/L")
    }

    func testDeltaIsAddedWhenTheArrowIsHidden() {
        XCTAssertEqual(BgReadingAlertBody.text(value: "164", slopeArrow: nil, delta: "+13 mg/dL"), " 164 +13 mg/dL")
    }

    func testUnknownDeltaIsLeftOut() {
        XCTAssertEqual(BgReadingAlertBody.text(value: "164", slopeArrow: "↑", delta: "???"), " 164 ↑")
        XCTAssertEqual(BgReadingAlertBody.text(value: "164", slopeArrow: "↑", delta: ""), " 164 ↑")
    }

    func testErroneousDeltaIsLeftOut() {
        // "ERR" stands for a change of more than 100 mg/dL, which real glucose does not make
        XCTAssertEqual(BgReadingAlertBody.text(value: "164", slopeArrow: "↑", delta: "ERR"), " 164 ↑")
    }

    // MARK: - existing text

    func testAlertsWithoutDeltaKeepTheirText() {
        XCTAssertEqual(BgReadingAlertBody.text(value: "3.4", slopeArrow: "↓", delta: nil), " 3.4 ↓")
        XCTAssertEqual(BgReadingAlertBody.text(value: "61", slopeArrow: nil, delta: nil), " 61")
    }
}
