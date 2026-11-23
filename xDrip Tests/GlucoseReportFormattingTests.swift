//
//  GlucoseReportFormattingTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers the report value formatting with pinned locales.
///
/// The report is generated in a language chosen in the report screen, which can differ from the
/// device locale. GMI must be converted to IFCC before it is rounded, decimal separators must follow
/// the passed locale, and the per-day durations of the range buckets must be printed from the
/// jointly allocated minutes so the three of them add up to 24 hours.
final class GlucoseReportFormattingTests: XCTestCase {

    /// GMI is converted from the unrounded percentage and then rounded to whole mmol/mol: 6.99368%
    /// is 52.99 mmol/mol (53) and 6.94% is 52.34 mmol/mol (52). Percentages keep one decimal and the
    /// decimal separator of the passed locale.
    func testGMIFormattingConvertsBeforeRoundingWithPinnedLocale() {
        let enUS = Locale(identifier: "en_US")
        let deDE = Locale(identifier: "de_DE")

        XCTAssertEqual(GlucoseReportFormatting.gmi(6.993_68, usesIFCC: false, locale: enUS), "7.0%")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.993_68, usesIFCC: false, locale: deDE), "7,0%")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.993_68, usesIFCC: true, locale: enUS), "53 mmol/mol")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.94, usesIFCC: true, locale: enUS), "52 mmol/mol")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.94, usesIFCC: true, compactUnit: true, locale: enUS), "52 mmol")
    }

    /// No data (zero or a negative percentage) prints a dash instead of a misleading value.
    func testGMIFormattingShowsADashWithoutData() {
        XCTAssertEqual(GlucoseReportFormatting.gmi(0, usesIFCC: false), "-")
        XCTAssertEqual(GlucoseReportFormatting.gmi(-1, usesIFCC: true), "-")
    }

    /// Glucose values carry their unit; axis labels do not.
    func testGlucoseFormattingAddsTheUnitOnlyForValues() {
        XCTAssertEqual(GlucoseReportFormatting.glucose(70, usesMgDl: true), "70 mg/dL")
        XCTAssertEqual(GlucoseReportFormatting.glucose(70, usesMgDl: false), "3.9 mmol/L")
        XCTAssertEqual(GlucoseReportFormatting.axisGlucose(180, usesMgDl: false), "10.0")
    }

    /// Numbers use the requested locale and fraction length, independent of the device.
    func testNumberFormattingUsesTheRequestedLocale() {
        XCTAssertEqual(GlucoseReportFormatting.number(36.25, decimalPlaces: 1, locale: Locale(identifier: "en_US")), "36.2")
        XCTAssertEqual(GlucoseReportFormatting.number(36.26, decimalPlaces: 1, locale: Locale(identifier: "fr_FR")), "36,3")
        XCTAssertEqual(GlucoseReportFormatting.number(12.0, decimalPlaces: 0, locale: Locale(identifier: "en_US")), "12")
    }

    /// Bucket durations print hours and minutes of the allocated day; Spanish uses "día".
    func testHoursPerDayFormatsAllocatedMinutes() {
        XCTAssertEqual(GlucoseReportFormatting.hoursPerDay(minutes: 58, language: .english), "58m/day")
        XCTAssertEqual(GlucoseReportFormatting.hoursPerDay(minutes: 0, language: .english), "0m/day")
        XCTAssertEqual(GlucoseReportFormatting.hoursPerDay(minutes: 1008, language: .english), "16h 48m/day")
        XCTAssertEqual(GlucoseReportFormatting.hoursPerDay(minutes: 60, language: .spanish), "1h 0m/día")
        XCTAssertEqual(GlucoseReportFormatting.hoursPerDay(minutes: 1440, language: .german), "24h 0m/day")
    }

    /// Sensor durations use the Nightscout day/hour style.
    func testCompactDurationUsesDaysAndHours() {
        XCTAssertEqual(GlucoseReportFormatting.compactDuration(.days(10)), "10d0h")
        XCTAssertEqual(GlucoseReportFormatting.compactDuration(.hours(36)), "1d12h")
        XCTAssertEqual(GlucoseReportFormatting.compactDuration(.minutes(45)), "45m")
    }
}
