//
//  DoubleGlucoseConversionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers the glucose unit conversion and formatting helpers on `Double` at the boundaries that
/// matter clinically.
///
/// Every mmol/L label in the app (Home, reports, alerts) goes through these helpers. The factor
/// `0.0555` is not exactly representable in binary, so products such as `100 * 0.0555` land just
/// below a `.x5` boundary and decide which way a one-decimal label rounds. These tests pin the
/// labels of the consensus limits and of the edge cases so a change of factor or format string
/// cannot silently move a displayed threshold.
final class DoubleGlucoseConversionTests: XCTestCase {

    // MARK: - conversion

    /// The two factors are each other's reciprocal, so converting there and back must not drift
    /// for any plausible glucose value, otherwise stored mmol/L settings would creep over time.
    func testMgDlAndMmolConversionsAreInversesAcrossTheGlucoseRange() {
        for mgDl in stride(from: 39.0, through: 400.0, by: 0.5) {
            XCTAssertEqual(mgDl.mgDlToMmol().mmolToMgdl(), mgDl, accuracy: 1e-9, "round trip for \(mgDl) mg/dL")
            XCTAssertEqual(mgDl.mgDlToMmol(mgDl: false).mmolToMgdl(mgDl: false), mgDl, accuracy: 1e-9)
        }
    }

    /// Common mmol/L thresholds entered by users must map to the mg/dL values used internally.
    func testCommonMmolThresholdsConvertToExpectedMgDl() {
        // 1 / 0.0555 = 18.018018...
        XCTAssertEqual(3.9.mmolToMgdl(), 70.270_270, accuracy: 0.000_001)
        XCTAssertEqual(10.0.mmolToMgdl(), 180.180_180, accuracy: 0.000_001)
        XCTAssertEqual(5.5.mmolToMgdl(), 99.099_099, accuracy: 0.000_001)
        XCTAssertEqual(0.0.mmolToMgdl(), 0)
    }

    /// With `mgDl: true` the value is already in the requested unit and must be returned untouched,
    /// even when it looks like an mmol/L value. Only `false` converts.
    func testUnitFlagOnlyConvertsWhenTheUserUnitIsMmol() {
        XCTAssertEqual(5.5.mgDlToMmol(mgDl: true), 5.5)
        XCTAssertEqual(180.0.mmolToMgdl(mgDl: true), 180)
        XCTAssertEqual(180.0.mgDlToMmol(mgDl: false), 9.99, accuracy: 0.000_001)
        XCTAssertEqual(9.99.mmolToMgdl(mgDl: false), 180, accuracy: 0.000_001)
    }

    // MARK: - formatting

    /// The consensus limits (54, 70, 140, 180 and 250 mg/dL) must be labelled with the values users
    /// know from clinical guidance: 3.0, 3.9, 7.8, 10.0 and 13.9 mmol/L.
    func testClinicalLimitsFormatToTheirKnownMmolLabels() {
        XCTAssertEqual(54.0.mgDlToMmolAndToString(mgDl: false), "3.0")
        XCTAssertEqual(70.0.mgDlToMmolAndToString(mgDl: false), "3.9")
        XCTAssertEqual(140.0.mgDlToMmolAndToString(mgDl: false), "7.8")
        XCTAssertEqual(180.0.mgDlToMmolAndToString(mgDl: false), "10.0")
        XCTAssertEqual(250.0.mgDlToMmolAndToString(mgDl: false), "13.9")
    }

    /// `100 * 0.0555` is stored as 5.5499999..., so it is shown as 5.5 and not 5.6. This matches the
    /// exact conversion (100 / 18.018 = 5.4999...) and must stay that way.
    func testValuesJustBelowAHalfStepRoundDownInMmol() {
        XCTAssertEqual(100.0.mgDlToMmolAndToString(mgDl: false), "5.5")
        XCTAssertEqual(100.0.mgDlToMmol().bgValueToString(mgDl: false), "5.5")
        XCTAssertEqual(5.549.mmolToString(), "5.5")
        XCTAssertEqual(5.551.mmolToString(), "5.6")
    }

    /// mg/dL labels have no decimals; mmol/L labels always have exactly one, also for whole values.
    func testBgValueToStringUsesUnitSpecificPrecision() {
        XCTAssertEqual(99.4.bgValueToString(mgDl: true), "99")
        XCTAssertEqual(99.6.bgValueToString(mgDl: true), "100")
        XCTAssertEqual(5.0.bgValueToString(mgDl: false), "5.0")
        XCTAssertEqual(15.04.bgValueToString(mgDl: false), "15.0")
        XCTAssertEqual(15.06.bgValueToString(mgDl: false), "15.1")
    }

    /// With `mgDl: true`, `mgDlToMmolAndToString` must only format, never convert.
    func testMgDlToMmolAndToStringDoesNotConvertForMgDlUsers() {
        XCTAssertEqual(39.0.mgDlToMmolAndToString(mgDl: true), "39")
        XCTAssertEqual(400.2.mgDlToMmolAndToString(mgDl: true), "400")
        XCTAssertEqual(39.0.mgDlToMmolAndToString(mgDl: false), "2.2")
        XCTAssertEqual(400.0.mgDlToMmolAndToString(mgDl: false), "22.2")
    }

    /// Only a literal trailing `.0` is removed; values whose description has no `.0` suffix (other
    /// decimals or exponent notation) are left as they are.
    func testStringWithoutTrailingZeroesOnlyStripsAWholeNumberSuffix() {
        XCTAssertEqual(120.0.stringWithoutTrailingZeroes, "120")
        XCTAssertEqual(120.1.stringWithoutTrailingZeroes, "120.1")
        XCTAssertEqual(0.0.stringWithoutTrailingZeroes, "0")
        XCTAssertEqual(10.05.stringWithoutTrailingZeroes, "10.05")
        XCTAssertEqual(1e16.stringWithoutTrailingZeroes, "1e+16")
    }

    // MARK: - minutesToDaysAndHours

    /// The Nightscout style age switches format at one hour and at twelve hours; check each side.
    func testMinutesToDaysAndHoursSwitchesFormatAtOneHourAndTwelveHours() {
        XCTAssertEqual(59.0.minutesToDaysAndHours(), "59m")
        XCTAssertEqual(60.0.minutesToDaysAndHours(), "1h0m")
        XCTAssertEqual(90.7.minutesToDaysAndHours(), "1h30m")
        XCTAssertEqual(1439.0.minutesToDaysAndHours(), "0d23h")
        XCTAssertEqual(1440.0.minutesToDaysAndHours(), "1d0h")
        XCTAssertEqual(2879.0.minutesToDaysAndHours(), "1d23h")
        // A ten-day sensor at its last minute.
        XCTAssertEqual(14399.0.minutesToDaysAndHours(), "9d23h")
    }

    /// Regression: a negative age (a sensor or site past its end) was formatted from `floor` days
    /// and truncated hours, so -30 minutes gave "-1d0h" and -90 minutes "-1d-1h". It is now the
    /// positive format with a minus sign.
    func testNegativeMinutesGetAMinusSignAndTheSameFormat() {
        XCTAssertEqual((-30.0).minutesToDaysAndHours(), "-30m")
        XCTAssertEqual((-90.0).minutesToDaysAndHours(), "-1h30m")
        XCTAssertEqual((-1500.0).minutesToDaysAndHours(), "-1d1h")
        XCTAssertEqual((-0.4).minutesToDaysAndHours(), "0m", "less than a minute late is not shown as negative")
    }

    /// Regression: the displayed value used `%.0f` / `%.1f`, which round exact halves to even,
    /// while `bgValueRounded` (used for alerts and comparisons) rounds them away from zero. So
    /// 100.5 mg/dL was shown as "100" but compared as 101. Both now round halves away from zero.
    func testDisplayedValueRoundsLikeTheComparedValue() {
        for value in [100.5, 101.5, 39.5, 400.5, 0.5] {
            XCTAssertEqual(value.bgValueToString(mgDl: true), String(format: "%.0f", value.bgValueRounded(mgDl: true)), "\(value)")
        }
        XCTAssertEqual(100.5.bgValueToString(mgDl: true), "101")
        XCTAssertEqual(100.5.mgDlToMmolAndToString(mgDl: true), "101")
        // 5.25 and 5.75 are exact in binary, so they are true halves.
        XCTAssertEqual(5.25.bgValueToString(mgDl: false), "5.3")
        XCTAssertEqual(5.75.bgValueToString(mgDl: false), "5.8")
        XCTAssertEqual(5.25.bgValueRounded(mgDl: false), 5.3, accuracy: 1e-12)
    }

    /// Values that are not halves are unchanged by the fix.
    func testDisplayedValuesAwayFromHalvesAreUnchanged() {
        XCTAssertEqual(100.4.bgValueToString(mgDl: true), "100")
        XCTAssertEqual(100.6.bgValueToString(mgDl: true), "101")
        XCTAssertEqual(5.56.bgValueToString(mgDl: false), "5.6")
        XCTAssertEqual(100.0.mgDlToMmolAndToString(mgDl: false), "5.5")
    }

    // MARK: - rounding

    /// `round(toDecimalPlaces:)` scales, rounds half away from zero and scales back. Exact halves
    /// therefore round away from zero, while values whose binary form is just below a half do not.
    func testRoundToDecimalPlacesRoundsHalfAwayFromZero() {
        XCTAssertEqual(2.5.round(toDecimalPlaces: 0), 3)
        XCTAssertEqual((-2.5).round(toDecimalPlaces: 0), -3)
        XCTAssertEqual(0.125.round(toDecimalPlaces: 2), 0.13, accuracy: 1e-12)
        // 1.005 is stored as 1.00499999..., so it rounds down.
        XCTAssertEqual(1.005.round(toDecimalPlaces: 2), 1.0, accuracy: 1e-12)
        XCTAssertEqual(1234.5678.round(toDecimalPlaces: -2), 1200)
    }

    /// `bgValueRounded` keeps whole mg/dL values and one decimal for mmol/L.
    func testBgValueRoundedUsesUnitPrecision() {
        XCTAssertEqual(145.4.bgValueRounded(mgDl: true), 145)
        XCTAssertEqual(145.6.bgValueRounded(mgDl: true), 146)
        XCTAssertEqual(5.44.bgValueRounded(mgDl: false), 5.4, accuracy: 1e-12)
        XCTAssertEqual(5.46.bgValueRounded(mgDl: false), 5.5, accuracy: 1e-12)
    }
}
