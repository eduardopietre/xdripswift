//
//  TreatmentScaleTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Tests for the treatment marker scales of the glucose chart.
///
/// Issue #781: young children often get boluses below 0.5U and only a few grams of carbs. With the
/// Small Doses scale every bolus up to 0.1U and every carb amount up to 1g gets the same smallest
/// marker, so these treatments cannot be told apart. An Extra Small Doses scale is needed that
/// starts sizing below 0.1U and 1g, with larger markers that are easy to read.
final class TreatmentScaleTests: XCTestCase {

    // MARK: - Extra Small Doses (#781)

    func testExtraSmallDosesScaleIsAvailableAfterSmallDoses() throws {
        let extraSmall = try XCTUnwrap(GlucoseChartTreatmentScale(rawValue: 2), "Extra Small Doses scale")
        XCTAssertEqual(GlucoseChartTreatmentScale.allCases.count, 3)
        XCTAssertEqual(GlucoseChartTreatmentScale.resolve(useSmallDoses: true, useExtraSmallDoses: true), extraSmall)
        XCTAssertEqual(GlucoseChartTreatmentScale.resolve(useSmallDoses: false, useExtraSmallDoses: true), extraSmall)
    }

    func testExtraSmallDosesDistinguishesBolusesBelowOneTenthUnit() throws {
        let sizing = try XCTUnwrap(GlucoseChartTreatmentScale(rawValue: 2)).bolusSymbolSizing
        XCTAssertLessThan(sizing.size(for: 0.05), sizing.size(for: 0.09))
        XCTAssertLessThan(sizing.size(for: 0.09), sizing.size(for: 0.3))
    }

    func testExtraSmallDosesDistinguishesCarbsBelowOneGram() throws {
        let sizing = try XCTUnwrap(GlucoseChartTreatmentScale(rawValue: 2)).carbsSymbolSizing
        XCTAssertLessThan(sizing.size(for: 0.5), sizing.size(for: 0.9))
        XCTAssertLessThan(sizing.size(for: 0.9), sizing.size(for: 5))
    }

    func testExtraSmallDosesUsesLargerMarkersThanSmallDoses() throws {
        let extraSmall = try XCTUnwrap(GlucoseChartTreatmentScale(rawValue: 2))
        XCTAssertGreaterThan(extraSmall.bolusSymbolSizing.minimumSize, GlucoseChartTreatmentScale.smallDoses.bolusSymbolSizing.minimumSize)
        XCTAssertGreaterThan(extraSmall.carbsSymbolSizing.minimumSize, GlucoseChartTreatmentScale.smallDoses.carbsSymbolSizing.minimumSize)
    }

    // MARK: - existing scales

    func testExistingSettingsKeepTheirScale() {
        XCTAssertEqual(GlucoseChartTreatmentScale.resolve(useSmallDoses: false, useExtraSmallDoses: false), .standard)
        XCTAssertEqual(GlucoseChartTreatmentScale.resolve(useSmallDoses: true, useExtraSmallDoses: false), .smallDoses)
        XCTAssertEqual(GlucoseChartTreatmentScale.standard.bolusSymbolSizing.minimumValue, 0.5)
        XCTAssertEqual(GlucoseChartTreatmentScale.smallDoses.bolusSymbolSizing.minimumValue, 0.1)
        XCTAssertEqual(GlucoseChartTreatmentScale.smallDoses.carbsSymbolSizing.minimumValue, 1)
    }
}
