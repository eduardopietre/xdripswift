//
//  SensorNoiseClassificationTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers the noise classification thresholds and the parts of the noise calculation that decide
/// which readings form a measurement: validity filtering, calibration and gap boundaries, the
/// four-hour long-term percentile and the ten-minute history cadence.
///
/// The test series are built so the expected noise can be computed by hand: a straight line has no
/// noise, and readings alternating by 10 mg/dL every five minutes have a neighbour jitter of exactly
/// 10 mg/dL (each point is 10 away from the midpoint of its neighbours), which is larger than their
/// quadratic residual (6.17 mg/dL), so the reported noise is 10. That lies between the very high
/// (sqrt(60) = 7.75) and extreme (sqrt(200) = 14.14) limits.
final class SensorNoiseClassificationTests: XCTestCase {

    // MARK: - properties

    private let calculator = SensorNoiseCalculator()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - classification thresholds

    /// The limits are the square roots of xDrip Android's error-variance limits 10, 60 and 200; a
    /// value exactly on a limit stays in the lower state.
    func testUnadjustedStateLimitsAreSquareRootsOfAndroidVarianceLimits() {
        let expectations: [(Double, SensorNoiseState)] = [
            (0, .low),
            (10.0.squareRoot(), .low),
            (10.0.squareRoot().nextUp, .elevated),
            (60.0.squareRoot(), .elevated),
            (60.0.squareRoot().nextUp, .veryHigh),
            (200.0.squareRoot(), .veryHigh),
            (200.0.squareRoot().nextUp, .extreme),
            (50, .extreme)
        ]

        for (noise, state) in expectations {
            XCTAssertEqual(ConstantsSensorNoise.state(for: noise), state, "noise \(noise)")
        }
    }

    /// The same stored noise is classified stricter when sensitive and more gently when permissive.
    /// 2.9 mg/dL becomes 4.34 (sensitive), 3.34 (normal) and 2.83 (permissive) against a 3.16 limit.
    func testSensitivityMovesTheSameStoredNoiseBetweenStates() {
        XCTAssertEqual(ConstantsSensorNoise.state(for: 2.9, sensitivity: .sensitive), .elevated)
        XCTAssertEqual(ConstantsSensorNoise.state(for: 2.9, sensitivity: .normal), .elevated)
        XCTAssertEqual(ConstantsSensorNoise.state(for: 2.9, sensitivity: .permissive), .low)

        // For any value, a stricter tolerance never gives a lower state.
        for noise in stride(from: 0.0, through: 20.0, by: 0.05) {
            let sensitive = ConstantsSensorNoise.state(for: noise, sensitivity: .sensitive).rawValue
            let normal = ConstantsSensorNoise.state(for: noise, sensitivity: .normal).rawValue
            let permissive = ConstantsSensorNoise.state(for: noise, sensitivity: .permissive).rawValue
            XCTAssertGreaterThanOrEqual(sensitive, normal, "noise \(noise)")
            XCTAssertGreaterThanOrEqual(normal, permissive, "noise \(noise)")
        }
    }

    /// The displayed state is the worse of the short and long-term values; only a flatline from the
    /// stored raw state overrides them, any other raw state is recomputed from the values.
    func testDisplayStateUsesTheWorseValueAndOnlyKeepsAFlatline() {
        XCTAssertEqual(
            ConstantsSensorNoise.displayState(rawState: .low, shortTermNoise: 2.0, longTermNoise: 8.0, sensitivity: .normal),
            .veryHigh
        )
        XCTAssertEqual(
            ConstantsSensorNoise.displayState(rawState: .extreme, shortTermNoise: 1.0, longTermNoise: nil, sensitivity: .normal),
            .low
        )
        XCTAssertEqual(
            ConstantsSensorNoise.displayState(rawState: .flatlineSuspected, shortTermNoise: 1.0, longTermNoise: 1.0, sensitivity: .permissive),
            .flatlineSuspected
        )
        XCTAssertEqual(
            ConstantsSensorNoise.displayState(rawState: .low, shortTermNoise: nil, longTermNoise: nil, sensitivity: .sensitive),
            .collecting
        )
    }

    // MARK: - short-term measurement

    /// Readings below 39 mg/dL, above 600 mg/dL or not finite are not glucose values and are ignored.
    func testInvalidReadingsAreIgnored() {
        let readings = [
            reading(minute: 0, value: 38.9),
            reading(minute: 5, value: 600.1),
            reading(minute: 10, value: .nan),
            reading(minute: 15, value: .infinity)
        ]

        let measurement = calculator.calculate(readings: readings)

        XCTAssertEqual(measurement.state, .collecting)
        XCTAssertNil(measurement.latestReadingAt)
        XCTAssertNil(measurement.shortTermNoise)
        XCTAssertEqual(measurement.shortTermCoverage, 0)
    }

    /// A perfectly straight rise is fully explained by the trend: no noise and full coverage.
    func testStraightRiseHasNoNoise() throws {
        let readings = (0 ... 6).map { reading(minute: Double($0) * 5, value: 100 + Double($0) * 5) }

        let measurement = calculator.calculate(readings: readings)

        XCTAssertEqual(try XCTUnwrap(measurement.shortTermNoise), 0, accuracy: 0.000_001)
        XCTAssertEqual(measurement.shortTermCoverage, 1, accuracy: 0.000_001)
        XCTAssertEqual(measurement.state, .low)
        XCTAssertEqual(measurement.latestReadingAt, start.addingTimeInterval(30 * 60))
    }

    /// Alternating readings give a neighbour jitter of exactly 10 mg/dL, which is very high noise.
    func testAlternatingReadingsGiveTheNeighbourJitter() throws {
        let measurement = calculator.calculate(readings: alternatingReadings(count: 7))

        XCTAssertEqual(try XCTUnwrap(measurement.shortTermNoise), 10, accuracy: 0.000_001)
        XCTAssertEqual(measurement.state, .veryHigh)
        // Thirty minutes of short-term data is not enough for the four-hour value.
        XCTAssertNil(measurement.longTermNoise)
    }

    /// A calibration splits the data: readings before it never form a segment with readings after
    /// it, so four new readings are not yet enough for a measurement.
    func testCalibrationChangeStartsANewSegment() {
        let sameCalibration = alternatingReadings(count: 7, calibrationID: { _ in "a" })
        let newCalibration = alternatingReadings(count: 7, calibrationID: { index in index < 3 ? "a" : "b" })

        XCTAssertNotNil(calculator.calculate(readings: sameCalibration).shortTermNoise)

        let measurement = calculator.calculate(readings: newCalibration)
        XCTAssertNil(measurement.shortTermNoise)
        XCTAssertEqual(measurement.state, .collecting)
        // Only the 15 minutes after the calibration count towards the 30-minute window.
        XCTAssertEqual(measurement.shortTermCoverage, 0.5, accuracy: 0.000_001)
    }

    /// A gap longer than twelve minutes also ends the segment; twelve minutes exactly does not.
    func testGapLongerThanTwelveMinutesStartsANewSegment() {
        let minutesWithShortGap: [Double] = [0, 4, 8, 20, 24, 28, 30]
        let minutesWithLongGap: [Double] = [0, 4, 8, 21, 25, 29, 30]

        let shortGap = minutesWithShortGap.enumerated().map { reading(minute: $1, value: $0.isMultiple(of: 2) ? 100 : 110) }
        let longGap = minutesWithLongGap.enumerated().map { reading(minute: $1, value: $0.isMultiple(of: 2) ? 100 : 110) }

        XCTAssertNotNil(calculator.calculate(readings: shortGap).shortTermNoise)
        XCTAssertNil(calculator.calculate(readings: longGap).shortTermNoise)
    }

    // MARK: - long-term measurement

    /// With four and a half hours of uniform jitter every rolling estimate is 10 mg/dL, so the
    /// 75th percentile (the long-term value) is 10 as well, with full coverage.
    func testLongTermNoiseIsTheRollingPercentileOverFourHours() throws {
        let measurement = calculator.calculate(readings: alternatingReadings(count: 55))

        XCTAssertEqual(try XCTUnwrap(measurement.longTermNoise), 10, accuracy: 0.000_001)
        XCTAssertEqual(measurement.longTermCoverage, 1, accuracy: 0.000_001)
        XCTAssertEqual(measurement.state, .veryHigh)
    }

    /// Three hours of data cover less than the 3.5-hour minimum span, so there is no long-term value.
    func testLongTermNoiseNeedsThreeAndAHalfHours() {
        let measurement = calculator.calculate(readings: alternatingReadings(count: 37))

        XCTAssertNil(measurement.longTermNoise)
        XCTAssertEqual(measurement.longTermCoverage, 0.75, accuracy: 0.000_001)
    }

    /// The twelve-hour persistence value is the median of the estimates; with an even number of
    /// estimates it is interpolated between the two middle values.
    func testPersistenceMedianInterpolatesAnEvenNumberOfEstimates() throws {
        let end = start.addingTimeInterval(.hours(12))
        let estimates = (0 ..< 24).map { index in
            (timeStamp: end.addingTimeInterval(-Double(index) * 30 * 60), noise: index < 12 ? 4.0 : 6.0)
        }.reversed()

        let assessment = calculator.calculatePersistence(estimates: Array(estimates), endingAt: end)

        // 23 gaps of 30 minutes cover 11.5 of 12 hours.
        XCTAssertEqual(assessment.coverage, 11.5 / 12, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(assessment.value), 5, accuracy: 0.000_001)
    }

    // MARK: - history

    /// History is calculated every ten minutes, and only endpoints with a measurement are kept: the
    /// first one is 30 minutes in, where the six readings and 20-minute span are first available.
    func testHistoryUsesTheTenMinuteCadenceAndSkipsEndpointsWithoutData() {
        let readings = alternatingReadings(count: 25)

        let history = calculator.calculateHistory(readings: readings)

        XCTAssertEqual(history.map { $0.timeStamp.timeIntervalSince(start) / 60 }, [30, 40, 50, 60, 70, 80, 90, 100, 110, 120])
        // Every entry is exactly what a live calculation at that moment would have stored.
        for entry in history {
            let live = calculator.calculate(readings: readings.filter { $0.timeStamp <= entry.timeStamp })
            XCTAssertEqual(entry.measurement, live)
        }
        XCTAssertTrue(calculator.calculateHistory(readings: []).isEmpty)
    }

    // MARK: - private functions

    private func reading(minute: Double, value: Double, calibrationID: String? = nil) -> SensorNoiseReading {
        SensorNoiseReading(
            timeStamp: start.addingTimeInterval(minute * 60),
            calculatedValue: value,
            rawData: value * 1000,
            calibrationID: calibrationID
        )
    }

    /// Readings every five minutes alternating between 100 and 110 mg/dL, oldest first.
    private func alternatingReadings(count: Int, calibrationID: (Int) -> String? = { _ in nil }) -> [SensorNoiseReading] {
        (0 ..< count).map { index in
            reading(minute: Double(index) * 5, value: index.isMultiple(of: 2) ? 100 : 110, calibrationID: calibrationID(index))
        }
    }
}
