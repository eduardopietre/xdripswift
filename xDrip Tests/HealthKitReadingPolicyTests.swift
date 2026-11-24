//
//  HealthKitReadingPolicyTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the readings written to Apple Health.
///
/// Issue #283: sensor errors ("ERR") ended up in Apple Health as real, very low glucose values.
/// The calibrator stores an error reading as `bgReadingErrorValue` (38 mg/dL, 2.1 mmol/L), and
/// HealthKitManager only skipped readings without a calculated value, so every error was saved
/// as a hypo that other apps and the user's health record then treat as real.
final class HealthKitReadingPolicyTests: XCTestCase {

    func testSensorErrorReadingsAreNotWrittenToAppleHealth() {
        XCTAssertFalse(HealthKitReadingPolicy.shouldStore(calculatedValue: ConstantsCalibrationAlgorithms.bgReadingErrorValue))
        XCTAssertFalse(HealthKitReadingPolicy.shouldStore(calculatedValue: 4.7), "an unclamped error value such as 0.26 mmol/L")
    }

    func testReadingsWithoutCalculatedValueAreNotWrittenToAppleHealth() {
        XCTAssertFalse(HealthKitReadingPolicy.shouldStore(calculatedValue: 0))
    }

    /// Post processing replaces the recent readings in Apple Health, on every cycle when smoothing is
    /// on. That path must skip sensor errors too, not only the one that stores new readings.
    func testReplacementsDoNotWriteSensorErrorReadingsToAppleHealth() {
        let values = [120, ConstantsCalibrationAlgorithms.bgReadingErrorValue, 0, ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue]
        XCTAssertEqual(HealthKitReadingPolicy.storableReadings(values, calculatedValue: { $0 }),
                       [120, ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue])
    }

    func testValidReadingsAreWrittenToAppleHealth() {
        XCTAssertTrue(HealthKitReadingPolicy.shouldStore(calculatedValue: ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue))
        XCTAssertTrue(HealthKitReadingPolicy.shouldStore(calculatedValue: 120))
        XCTAssertTrue(HealthKitReadingPolicy.shouldStore(calculatedValue: ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValue))
    }
}
