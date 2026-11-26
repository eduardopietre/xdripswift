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
/// device locale. GMI must be converted to IFCC before it is rounded, GMI and numbers follow the
/// decimal separator of the passed locale (glucose values and axis labels currently always use "."),
/// and the per-day durations of the range buckets must be printed from the
/// jointly allocated minutes so the three of them add up to 24 hours.
final class GlucoseReportFormattingTests: XCTestCase {

    /// Glucose values carry their unit; axis labels do not. They use "." whatever the locale, unlike GMI
    /// and numbers: this describes the current behaviour, which mixes separators in a German report.
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
