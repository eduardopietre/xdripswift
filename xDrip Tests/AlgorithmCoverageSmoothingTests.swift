//
//  AlgorithmCoverageSmoothingTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class AlgorithmCoverageSmoothingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 600)

    // MARK: - Savitzky-Golay array utility

    func testSavitzkyGolayFivePointFilterSpreadsASpikeByItsCoefficients() {
        var values: [Double] = [0, 0, 0, 0, 0, 35, 0, 0, 0, 0, 0]
        values.smoothSavitzkyGolayQuaDratic(withFilterWidth: 2)
        assertEqual(values, [0, 0, 0, -3, 12, 17, 12, -3, 0, 0, 0])
    }

    func testSavitzkyGolaySevenPointFilterSpreadsASpikeByItsCoefficients() {
        var values: [Double] = [0, 0, 0, 0, 0, 21, 0, 0, 0, 0, 0]
        values.smoothSavitzkyGolayQuaDratic(withFilterWidth: 3)
        assertEqual(values, [0, 0, -2, 3, 6, 7, 6, 3, -2, 0, 0])
    }

    func testSavitzkyGolayPreservesLinearDataForEveryWidth() {
        let line = (0..<15).map { 100 + 2.5 * Double($0) }
        for width in [2, 3, 4, 5, 7] {
            var values = line
            values.smoothSavitzkyGolayQuaDratic(withFilterWidth: width)
            assertEqual(values, line, accuracy: 0.000_001)
        }
    }

    func testSavitzkyGolayPreservesInteriorOfQuadraticAndExtrapolatesEdgesLinearly() {
        var values = (0..<8).map { Double($0 * $0) }
        values.smoothSavitzkyGolayQuaDratic(withFilterWidth: 2)
        assertEqual(values, [-0.171_428_571, 1.171_428_571, 4, 9, 16, 25, 36.171_428_571, 48.828_571_429], accuracy: 0.000_001)
    }

    func testSavitzkyGolayLeavesShortArraysUntouchedAndInvalidWidthUsesEleven() {
        var short: [Double] = [1, 50, 3, 4]
        short.smoothSavitzkyGolayQuaDratic()
        XCTAssertEqual(short, [1, 50, 3, 4])
        var invalid: [Double] = [1, 50, 3, 4]
        invalid.smoothSavitzkyGolayQuaDratic(withFilterWidth: 9)
        XCTAssertEqual(invalid, [1, 50, 3, 4])
        var spikeDefault = Array(repeating: 0.0, count: 21)
        spikeDefault[10] = 429
        var spikeInvalid = spikeDefault
        spikeDefault.smoothSavitzkyGolayQuaDratic(withFilterWidth: 5)
        spikeInvalid.smoothSavitzkyGolayQuaDratic(withFilterWidth: 42)
        XCTAssertEqual(spikeDefault[10], 89, accuracy: 0.000_001)
        assertEqual(spikeInvalid, spikeDefault)
    }

    func testSavitzkyGolayWritesBackIntoReferenceElements() {
        final class Point: SavitzkyGolaySmoothable { var value: Double; init(_ v: Double) { value = v } }
        let points = [0.0, 0, 0, 0, 0, 35, 0, 0, 0, 0, 0].map(Point.init)
        var array = points
        array.smoothSavitzkyGolayQuaDratic(withFilterWidth: 2)
        XCTAssertEqual(points[5].value, 17, accuracy: 0.000_001)
        XCTAssertEqual(points[3].value, -3, accuracy: 0.000_001)
    }

    // MARK: - Constants

    func testLoessSpanIsOddCappedAndAtLeastThree() {
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 0, isFastCadence: false, sampleCount: 100), 5)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 0, isFastCadence: true, sampleCount: 100), 7)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 1, isFastCadence: false, sampleCount: 100), 7)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 1, isFastCadence: true, sampleCount: 100), 9)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 2, isFastCadence: false, sampleCount: 100), 9)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 2, isFastCadence: true, sampleCount: 100), 11)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 1, isFastCadence: false, sampleCount: 6), 5)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 1, isFastCadence: false, sampleCount: 5), 5)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 1, isFastCadence: false, sampleCount: 2), 3)
        XCTAssertEqual(ConstantsBgSmoothing.loessSpan(forSmoothingStrength: 1, isFastCadence: false, sampleCount: 1), 3)
        XCTAssertEqual([0, 1, 2, 9].map(ConstantsBgSmoothing.loessRobustnessIterations), [0, 1, 2, 1])
    }

    // MARK: - Plugins with a stub support

    func testEveryPluginReturnsShortInputUnchanged() {
        let values: [Double] = [100, 140, 90, 120]
        for algorithm in [BgSmoothingAlgorithm.exponential, .kalman, .loess, .hampelSavitzkyGolay] {
            XCTAssertEqual(algorithm.plugin.smoothedValues(values: values, readingDates: dates(count: 4), smoothingStrength: 1, support: support()), values, algorithm.rawValue)
        }
    }

    func testEveryPluginKeepsConstantSignalsConstant() {
        let values = Array(repeating: 123.0, count: 12)
        for algorithm in BgSmoothingAlgorithm.allCases {
            for strength in 0...2 {
                assertEqual(algorithm.plugin.smoothedValues(values: values, readingDates: dates(count: 12), smoothingStrength: strength, support: support()), values, accuracy: 0.000_1)
            }
        }
    }

    func testExponentialBidirectionalSinglePass() {
        let result = ExponentialBgSmoothing().smoothedValues(values: [0, 0, 0, 0, 10], readingDates: dates(count: 5), smoothingStrength: 0, support: support())
        assertEqual(result, [0.648, 1.08, 1.8, 3.0, 7.0], accuracy: 0.000_000_1)
    }

    func testExponentialStrongStrengthUsesTwoPasses() {
        let result = ExponentialBgSmoothing().smoothedValues(values: [0, 0, 0, 0, 10], readingDates: dates(count: 5), smoothingStrength: 2, support: support())
        assertEqual(result, [3.072, 3.3792, 3.74016, 4.144128, 4.6753024], accuracy: 0.000_000_1)
    }

    func testExponentialFastCadenceDelegatesToSparseSmoothingWithStrengthParameters() {
        var calls = [(Int, Int, Int)]()
        let stub = support(fast: true, medianGap: 1, sparse: { values, step, width, iterations in
            calls.append((step, width, iterations))
            return values.map { $0 + 1 }
        })
        let input = Array(repeating: 50.0, count: 20)
        let result = ExponentialBgSmoothing().smoothedValues(values: input, readingDates: dates(count: 20, spacing: 60), smoothingStrength: 2, support: stub)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, 5)
        XCTAssertEqual(calls.first?.1, 3)
        XCTAssertEqual(calls.first?.2, 2)
        assertEqual(result, Array(repeating: 51.0, count: 20), accuracy: 0.000_001)
    }

    func testExponentialFastCadenceStepIsRoundedAndAtLeastTwo() {
        for (gap, expected) in [(2.0, 3), (4.0, 2), (0.5, 10)] {
            var step: Int?
            let stub = support(fast: true, medianGap: gap, sparse: { values, readingsPerStep, _, _ in step = readingsPerStep; return values })
            _ = ExponentialBgSmoothing().smoothedValues(values: Array(repeating: 1.0, count: 10), readingDates: dates(count: 10), smoothingStrength: 0, support: stub)
            XCTAssertEqual(step, expected, "gap \(gap)")
        }
        var called = false
        let noGap = support(fast: true, medianGap: nil, sparse: { values, _, _, _ in called = true; return values })
        _ = ExponentialBgSmoothing().smoothedValues(values: Array(repeating: 1.0, count: 10), readingDates: dates(count: 10), smoothingStrength: 0, support: noGap)
        XCTAssertFalse(called)
    }

    func testExponentialKalmanAndLoessAlwaysApplyTheLiveEdgeClamp() {
        var clampCalls = 0
        let stub = support(clamp: { _, smoothed, strength in clampCalls += 1; XCTAssertEqual(strength, 2); return smoothed })
        _ = ExponentialBgSmoothing().smoothedValues(values: [1, 2, 3, 4, 5], readingDates: dates(count: 5), smoothingStrength: 2, support: stub)
        _ = KalmanBgSmoothing().smoothedValues(values: [1, 2, 3, 4, 5], readingDates: dates(count: 5), smoothingStrength: 2, support: stub)
        _ = LoessBgSmoothing().smoothedValues(values: [1, 2, 3, 4, 5], readingDates: dates(count: 5), smoothingStrength: 2, support: stub)
        XCTAssertEqual(clampCalls, 3)
    }

    func testKalmanForwardBackwardBlendMatchesHandComputedValues() {
        let light = KalmanBgSmoothing().smoothedValues(values: [0, 0, 0, 0, 10], readingDates: dates(count: 5), smoothingStrength: 0, support: support())
        assertEqual(light, [0.413_482_849, 0.658_587_987, 1.084_598_698, 1.960_784_314, 7.416_559_161], accuracy: 0.000_001)
        let medium = KalmanBgSmoothing().smoothedValues(values: [0, 0, 0, 0, 10], readingDates: dates(count: 5), smoothingStrength: 1, support: support())
        assertEqual(medium, [0.685_148_968, 0.950_425_603, 1.385_152_398, 2.248_875_562, 6.734_583_878], accuracy: 0.000_001)
    }

    func testKalmanIsSymmetricForMirroredInput() {
        let values: [Double] = [100, 104, 99, 120, 101, 98, 103]
        let forward = KalmanBgSmoothing().smoothedValues(values: values, readingDates: dates(count: 7), smoothingStrength: 1, support: support())
        let mirrored = KalmanBgSmoothing().smoothedValues(values: values.reversed(), readingDates: dates(count: 7), smoothingStrength: 1, support: support())
        assertEqual(forward, mirrored.reversed(), accuracy: 0.000_000_1)
        XCTAssertLessThan(forward[3], 120)
    }

    func testLoessReproducesLinearTrends() {
        let line = (0..<12).map { 90 + 3 * Double($0) }
        for strength in 0...2 {
            let result = LoessBgSmoothing().smoothedValues(values: line, readingDates: dates(count: 12), smoothingStrength: strength, support: support())
            assertEqual(result, line, accuracy: 0.000_1)
        }
    }

    func testLoessRobustnessIterationsSuppressAnOutlierMoreThanPlainRegression() {
        var values = Array(repeating: 100.0, count: 15)
        values[7] = 160
        let plain = LoessBgSmoothing().smoothedValues(values: values, readingDates: dates(count: 15), smoothingStrength: 0, support: support())
        let robust = LoessBgSmoothing().smoothedValues(values: values, readingDates: dates(count: 15), smoothingStrength: 2, support: support())
        XCTAssertLessThan(plain[7], 160)
        XCTAssertLessThan(robust[7], plain[7])
        XCTAssertEqual(robust[0], 100, accuracy: 1)
    }

    func testLoessKeepsValuesWhenAllTimestampsCoincide() {
        let values: [Double] = [100, 120, 90, 130, 110]
        let sameDate = Array(repeating: now, count: 5)
        XCTAssertEqual(LoessBgSmoothing().smoothedValues(values: values, readingDates: sameDate, smoothingStrength: 1, support: support()), values)
    }

    func testHampelReplacesOnlyTheOutlierWithTheWindowMedian() {
        var received: [Double]?
        let stub = support(savitzky: { values, _, _ in received = values; return values })
        let values: [Double] = [100, 101, 102, 103, 200, 105, 106, 107, 108]
        let result = HampelSavitzkyGolayBgSmoothing().smoothedValues(values: values, readingDates: dates(count: 9), smoothingStrength: 1, support: stub)
        XCTAssertEqual(result, [100, 101, 102, 103, 105, 105, 106, 107, 108])
        XCTAssertEqual(received, result)
    }

    func testHampelKeepsModerateDeviationsWithinThreshold() {
        let values: [Double] = [100, 102, 100, 102, 100, 102, 100]
        let result = HampelSavitzkyGolayBgSmoothing().smoothedValues(values: values, readingDates: dates(count: 7), smoothingStrength: 0, support: support())
        XCTAssertEqual(result, values)
    }

    // MARK: - Helpers

    private func dates(count: Int, spacing: TimeInterval = 300) -> [Date] {
        (0..<count).map { now.addingTimeInterval(Double($0) * spacing) }
    }

    private func support(
        fast: Bool = false,
        medianGap: Double? = 5,
        savitzky: @escaping ([Double], [Date], Int) -> [Double] = { values, _, _ in values },
        sparse: @escaping ([Double], Int, Int, Int) -> [Double] = { values, _, _, _ in values },
        clamp: @escaping ([Double], [Double], Int) -> [Double] = { _, smoothed, _ in smoothed }
    ) -> BgSmoothingSupport {
        BgSmoothingSupport(
            canUseFiveMinuteReadings: { _ in fast },
            medianReadingGapInMinutes: { _ in medianGap },
            savitzkyGolayStyleSmoothedValues: savitzky,
            sparseCadenceSmoothedValues: sparse,
            clampedMostRecentSmoothedValues: clamp
        )
    }

    private func assertEqual(_ actual: [Double], _ expected: [Double], accuracy: Double = 0.000_000_1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "index \(index)", file: file, line: line)
        }
    }
}
