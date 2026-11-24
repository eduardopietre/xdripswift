//
//  GlucoseChartPlotValueTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the height at which glucose readings are plotted.
///
/// Issue #560: in mmol/L, readings shown with the same value (4.1) were drawn at different heights.
/// The chart plotted the exact mg/dL value under a mmol/L axis, so 73 and 74 mg/dL, both shown as
/// 4.1 mmol/L, sat at visibly different distances from the x-axis, which made the chart look
/// inconsistent with the numbers the user reads.
final class GlucoseChartPlotValueTests: XCTestCase {

    // MARK: - mmol/L (#560)

    func testReadingsShownWithTheSameMmolValueArePlottedAtTheSameHeight() {
        XCTAssertEqual(73.0.mgDlToMmolAndToString(mgDl: false), 74.0.mgDlToMmolAndToString(mgDl: false), "precondition: both are shown as the same mmol/L value")

        XCTAssertEqual(
            GlucoseChartPlotValue.plotted(73, isMgDl: false),
            GlucoseChartPlotValue.plotted(74, isMgDl: false),
            accuracy: 0.000_001
        )
    }

    func testMmolReadingIsPlottedAtTheValueItIsShownAs() throws {
        let shown = try XCTUnwrap(Double(73.0.mgDlToMmolAndToString(mgDl: false)))

        XCTAssertEqual(GlucoseChartPlotValue.plotted(73, isMgDl: false).mgDlToMmol(), shown, accuracy: 0.000_001)
    }

    func testDifferentShownMmolValuesKeepTheirOrder() {
        XCTAssertLessThan(GlucoseChartPlotValue.plotted(74, isMgDl: false), GlucoseChartPlotValue.plotted(76, isMgDl: false))
    }

    // MARK: - mg/dL

    func testMgDlReadingsArePlottedUnchanged() {
        XCTAssertEqual(GlucoseChartPlotValue.plotted(73, isMgDl: true), 73)
        XCTAssertEqual(GlucoseChartPlotValue.plotted(74.4, isMgDl: true), 74.4)
    }
}
