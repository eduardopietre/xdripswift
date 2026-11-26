//
//  CalibrationReadinessEvaluatorTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers every threshold of the calibration readiness evaluator at and just past its boundary.
///
/// Calibrating while glucose moves fast, from a stale reading, or with a value outside 80-170 mg/dL
/// skews the calibration curve for days. The readiness card warns the user before they submit, so a
/// threshold that is off by one comparison (`<` instead of `<=`) silently lets a bad calibration
/// through or blocks a good one. Slopes are built from linear series whose regression and endpoint
/// slopes are exact, so the boundary values are hit exactly.
final class CalibrationReadinessEvaluatorTests: XCTestCase {

    // MARK: - properties

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - calibration value

    /// 70 and 180 mg/dL are the edges of the acceptable band, 80 and 170 the edges of the good band.
    func testCalibrationValueLevelsAtEveryBoundary() {
        let expectations: [(Double, CalibrationReadinessLevel)] = [
            (69.9, .bad), (70, .caution), (79.9, .caution), (80, .good),
            (170, .good), (170.1, .caution), (180, .caution), (180.1, .bad)
        ]

        for (value, level) in expectations {
            XCTAssertEqual(CalibrationReadinessEvaluator.calibrationValueReadiness(valueInMgDl: value).level, level, "value \(value)")
        }
    }

    /// The detail explains in which direction the value is off.
    func testCalibrationValueDetailNamesTheDirection() {
        XCTAssertEqual(CalibrationReadinessEvaluator.calibrationValueReadiness(valueInMgDl: 60).detail, Texts_Common.lowStatistics)
        XCTAssertEqual(CalibrationReadinessEvaluator.calibrationValueReadiness(valueInMgDl: 75).detail, Texts_HomeView.sensorManagementCalibrationSlightlyLow)
        XCTAssertEqual(CalibrationReadinessEvaluator.calibrationValueReadiness(valueInMgDl: 120).detail, Texts_HomeView.sensorManagementCalibrationGood)
        XCTAssertEqual(CalibrationReadinessEvaluator.calibrationValueReadiness(valueInMgDl: 175).detail, Texts_HomeView.sensorManagementCalibrationSlightlyHigh)
        XCTAssertEqual(CalibrationReadinessEvaluator.calibrationValueReadiness(valueInMgDl: 250).detail, Texts_Common.highStatistics)
    }

    // MARK: - sensor and data availability

    /// Without an active sensor nothing can be judged, so both checks are caution, even when the
    /// readings and noise look perfect.
    func testNoActiveSensorMakesBothChecksCaution() {
        let readiness = evaluator().evaluate(hasActiveSensor: false, recentReadings: linearReadings(slope: 0), noiseState: .low)

        XCTAssertEqual(readiness.stableTrend.level, .caution)
        XCTAssertEqual(readiness.sensorNoise.level, .caution)
        XCTAssertEqual(readiness.stableTrend.detail, Texts_HomeView.sensorManagementNoSensor)
    }

    /// No readings is caution, not bad: the trend is unknown rather than known to be unstable.
    func testNoReadingsIsCaution() {
        let readiness = evaluator().evaluate(hasActiveSensor: true, recentReadings: [], noiseState: .low)

        XCTAssertEqual(readiness.stableTrend.level, .caution)
        XCTAssertEqual(readiness.stableTrend.detail, Texts_HomeView.sensorManagementCalibrationNoTrend)
    }

    /// A latest reading exactly 15 minutes old is still usable; one second older is stale (bad).
    func testLatestReadingAgeBoundaryIsFifteenMinutes() {
        let readings = linearReadings(slope: 0)

        let atLimit = evaluator(now: now.addingTimeInterval(15 * 60)).evaluate(hasActiveSensor: true, recentReadings: readings, noiseState: .low)
        let pastLimit = evaluator(now: now.addingTimeInterval(15 * 60 + 1)).evaluate(hasActiveSensor: true, recentReadings: readings, noiseState: .low)

        XCTAssertEqual(atLimit.stableTrend.level, .good)
        XCTAssertEqual(pastLimit.stableTrend.level, .bad)
        XCTAssertEqual(pastLimit.stableTrend.detail, Texts_HomeView.sensorManagementCalibrationStale)
    }

    /// Five readings are needed: four readings over 20 minutes are still collecting.
    func testAtLeastFiveReadingsAreNeeded() {
        let four = linearReadings(slope: 0, minutes: [0, 5, 15, 20])
        let five = linearReadings(slope: 0, minutes: [0, 5, 10, 15, 20])

        XCTAssertEqual(trend(four).level, .caution)
        XCTAssertEqual(trend(four).detail, Texts_HomeView.sensorManagementNoiseCollecting)
        XCTAssertEqual(trend(five).level, .good)
    }

    /// The readings must span at least 20 minutes; 19 minutes is still collecting.
    func testTrendSpanMustBeAtLeastTwentyMinutes() {
        let short = linearReadings(slope: 0, minutes: [0, 4, 8, 12, 16, 19])
        let exact = linearReadings(slope: 0, minutes: [0, 4, 8, 12, 16, 20])

        XCTAssertEqual(trend(short).level, .caution)
        XCTAssertEqual(trend(exact).level, .good)
    }

    /// Only readings within 30 minutes of the latest reading count: older ones neither add to the
    /// minimum count nor stretch the span. A reading exactly 30 minutes older still counts.
    func testReadingsOlderThanThirtyMinutesBeforeTheLatestAreIgnored() {
        let tooOld = linearReadings(slope: 0, minutes: [0, 10, 21, 26, 31])
        let exactlyThirty = linearReadings(slope: 0, minutes: [0, 10, 20, 25, 30])

        // Relative to the latest reading at minute 31, the one at minute 0 is 31 minutes older.
        XCTAssertEqual(trend(tooOld).level, .caution)
        XCTAssertEqual(trend(exactlyThirty).level, .good)
    }

    // MARK: - slope thresholds

    /// Up to 1 mg/dL per minute is stable, up to 2 is caution, above 2 is bad, in both directions.
    func testSlopeThresholdsInBothDirections() {
        let expectations: [(Double, CalibrationReadinessLevel, String)] = [
            (0, .good, Texts_HomeView.sensorManagementCalibrationStable),
            (1, .good, Texts_HomeView.sensorManagementCalibrationStable),
            (-1, .good, Texts_HomeView.sensorManagementCalibrationStable),
            (1.5, .caution, Texts_HomeView.sensorManagementCalibrationRising),
            (-1.5, .caution, Texts_HomeView.sensorManagementCalibrationFalling),
            (2, .caution, Texts_HomeView.sensorManagementCalibrationRising),
            (-2, .caution, Texts_HomeView.sensorManagementCalibrationFalling),
            (2.5, .bad, Texts_HomeView.sensorManagementCalibrationRisingFast),
            (-2.5, .bad, Texts_HomeView.sensorManagementCalibrationFallingFast)
        ]

        for (slope, level, detail) in expectations {
            let check = trend(linearReadings(slope: slope))
            XCTAssertEqual(check.level, level, "slope \(slope)")
            XCTAssertEqual(check.detail, detail, "slope \(slope)")
        }
    }

    /// A jump at the end of the window barely moves the regression slope (0.86 mg/dL/min) but the
    /// endpoint slope is 1.2 mg/dL/min; the larger one decides, so this is not reported as stable.
    func testEndpointSlopeIsUsedWhenItIsSteeperThanTheRegression() {
        let readings = values([100, 100, 100, 100, 100, 130])

        let check = trend(readings)

        XCTAssertEqual(check.level, .caution)
        XCTAssertEqual(check.detail, Texts_HomeView.sensorManagementCalibrationRising)
    }

    /// The first and last values are equal (endpoint slope 0), but the series rose in between with
    /// a regression slope of 1.14 mg/dL/min; the flat endpoints must not hide that movement.
    func testRegressionSlopeIsUsedWhenItIsSteeperThanTheEndpoints() {
        let readings = values([100, 100, 100, 150, 150, 100])

        XCTAssertEqual(trend(readings).level, .caution)
    }

    /// Readings may arrive in any order; they are sorted by time before the slope is calculated,
    /// as long as the newest reading is first (it decides staleness and the lookback window).
    func testOlderReadingsMayArriveInAnyOrder() {
        var readings = linearReadings(slope: -2.5)
        let newest = readings.removeFirst()
        // a fixed, scrambled order rather than a random shuffle, so a failure reproduces
        let scrambled = [readings[2], readings[0], readings[4], readings[1], readings[3]]

        let check = trend([newest] + scrambled)

        XCTAssertEqual(check.level, .bad)
        XCTAssertEqual(check.detail, Texts_HomeView.sensorManagementCalibrationFallingFast)
    }

    // MARK: - sensor noise

    /// Low noise is good, collecting and elevated are caution, and very high, extreme and a
    /// suspected flatline block a calibration.
    func testSensorNoiseStatesMapToReadinessLevels() {
        let expectations: [(SensorNoiseState, CalibrationReadinessLevel, String)] = [
            (.low, .good, Texts_HomeView.sensorManagementNoiseLow),
            (.collecting, .caution, Texts_HomeView.sensorManagementNoiseCollecting),
            (.elevated, .caution, Texts_HomeView.sensorManagementNoiseElevated),
            (.veryHigh, .bad, Texts_HomeView.sensorManagementNoiseVeryHigh),
            (.extreme, .bad, Texts_HomeView.sensorManagementNoiseExtreme),
            (.flatlineSuspected, .bad, Texts_HomeView.sensorManagementCalibrationFlatline)
        ]

        for (state, level, detail) in expectations {
            let readiness = evaluator().evaluate(hasActiveSensor: true, recentReadings: linearReadings(slope: 0), noiseState: state)
            XCTAssertEqual(readiness.sensorNoise.level, level, "state \(state)")
            XCTAssertEqual(readiness.sensorNoise.detail, detail, "state \(state)")
        }
    }

    // MARK: - combined evaluation

    /// The overall level is the worst of the three checks, and the trace and troubleshooting
    /// snapshot carry each individual level.
    func testOverallLevelIsTheWorstCheck() {
        let readiness = evaluator().evaluate(hasActiveSensor: true, recentReadings: linearReadings(slope: 1.5), noiseState: .low)

        let good = readiness.evaluating(calibrationValueInMgDl: 120)
        let bad = readiness.evaluating(calibrationValueInMgDl: 60)
        let allGood = evaluator().evaluate(hasActiveSensor: true, recentReadings: linearReadings(slope: 0), noiseState: .low)
            .evaluating(calibrationValueInMgDl: 120)

        XCTAssertEqual(good.level, .caution)
        XCTAssertEqual(good.summary, Texts_HomeView.sensorManagementCalibrationReadinessCaution)
        XCTAssertEqual(bad.level, .bad)
        XCTAssertEqual(allGood.level, .good)
        XCTAssertEqual(
            bad.traceDescription,
            "overall = bad, calibration value = bad (\(Texts_Common.lowStatistics)), stable trend = caution (\(Texts_HomeView.sensorManagementCalibrationRising)), sensor noise = good (\(Texts_HomeView.sensorManagementNoiseLow))"
        )

        let snapshot = TroubleshootingCalibrationReadiness(bad)
        XCTAssertEqual(snapshot.calibrationValue, .bad)
        XCTAssertEqual(snapshot.stableTrend, .caution)
        XCTAssertEqual(snapshot.sensorNoise, .good)
        XCTAssertEqual(snapshot.overall, .bad)
    }

    // MARK: - private functions

    private func evaluator(now: Date? = nil) -> CalibrationReadinessEvaluator {
        CalibrationReadinessEvaluator(now: now ?? self.now)
    }

    private func trend(_ readings: [CalibrationReadinessReading]) -> CalibrationReadinessCheck {
        evaluator().evaluate(hasActiveSensor: true, recentReadings: readings, noiseState: .low).stableTrend
    }

    /// Newest-first readings, the newest at `now`, following `100 + slope x minute` exactly.
    private func linearReadings(slope: Double, minutes: [Double] = [0, 5, 10, 15, 20, 25]) -> [CalibrationReadinessReading] {
        let latest = minutes.max() ?? 0
        return minutes.reversed().map { minute in
            CalibrationReadinessReading(
                timeStamp: now.addingTimeInterval((minute - latest) * 60),
                valueInMgDl: 100 + slope * minute
            )
        }
    }

    /// Newest-first readings five minutes apart, from the oldest value to the newest at `now`.
    private func values(_ oldestFirst: [Double]) -> [CalibrationReadinessReading] {
        let count = oldestFirst.count
        return oldestFirst.enumerated().reversed().map { index, value in
            CalibrationReadinessReading(
                timeStamp: now.addingTimeInterval(Double(index - count + 1) * 5 * 60),
                valueInMgDl: value
            )
        }
    }
}
