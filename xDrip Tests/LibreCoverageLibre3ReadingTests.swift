//
//  LibreCoverageLibre3ReadingTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class LibreCoverageLibre3ReadingTests: XCTestCase {
    private struct Plaintext {
        var lifeCount: UInt16 = 1500
        var currentWord: UInt16 = 120
        var rateOfChange: Int16 = 0
        var temperatureStatus: UInt16 = 0
        var projected: UInt16 = 125
        var historicalLifeCount: UInt16 = 1485
        var historicalWord: UInt16 = 118
        var trendAndRest: UInt8 = 0x0B
        var current: UInt16 = 120
        var historic: UInt16 = 118
        var temperature: UInt16 = 3300
        var fast: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

        var data: Data {
            var bytes: [UInt8] = []
            func put(_ value: UInt16) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
            put(lifeCount); put(currentWord); put(UInt16(bitPattern: rateOfChange)); put(temperatureStatus); put(projected)
            put(historicalLifeCount); put(historicalWord)
            bytes.append(trendAndRest)
            put(current); put(historic); put(temperature)
            bytes += fast
            return Data(bytes)
        }

        func reading() throws -> Libre3RealtimeGlucoseReading { try Libre3RealtimeGlucoseReading(plaintext: data) }
    }

    // MARK: - decoding

    func testRejectsPlaintextOfWrongSize() {
        for size in [0, 28, 30] {
            XCTAssertThrowsError(try Libre3RealtimeGlucoseReading(plaintext: Data(repeating: 0, count: size))) { error in
                XCTAssertEqual(error as? Libre3RealtimeGlucoseReadingError, .wrongPlaintextSize(size))
            }
        }
    }

    func testDecodesEveryFieldOfAHealthyReading() throws {
        let reading = try Plaintext(rateOfChange: -250, temperatureStatus: 0x0102).reading()
        XCTAssertEqual(reading.lifeCount, 1500)
        XCTAssertEqual(reading.readingMgDL, 120)
        XCTAssertEqual(reading.dqErrorRaw, 0)
        XCTAssertEqual(reading.dqError, .good)
        XCTAssertEqual(reading.sensorCondition, .ok)
        XCTAssertEqual(reading.currentGlucoseMgDL, 120)
        XCTAssertTrue(reading.isCurrentGlucoseValid)
        XCTAssertEqual(reading.rateOfChangeRaw, -250)
        XCTAssertEqual(reading.rateOfChangeMgDLPerMinute, -2.5)
        XCTAssertTrue(reading.rateOfChangeAvailable)
        XCTAssertEqual(reading.temperatureStatus, 0x0102)
        XCTAssertEqual(reading.projectedGlucose, 125)
        XCTAssertEqual(reading.historicalLifeCount, 1485)
        XCTAssertEqual(reading.historicalReading, 118)
        XCTAssertEqual(reading.historicalGlucoseMgDL, 118)
        XCTAssertEqual(reading.historicResultRangeStatus, .inRange)
        XCTAssertEqual(reading.trend, 3)
        XCTAssertEqual(reading.trendKind, .stable)
        XCTAssertEqual(reading.actionability, .actionable)
        XCTAssertEqual(reading.statusBits, 1)
        XCTAssertEqual(reading.temperature, 3300)
        XCTAssertEqual(reading.esaDuration, 0)
        XCTAssertEqual(reading.fastData, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(reading.fastDataWordsLE, [0x0201, 0x0403, 0x0605, 0x0807])
        XCTAssertEqual(reading.wordsLE.count, 14)
        XCTAssertEqual(reading.wordsLE.first, 1500)
        XCTAssertEqual(reading.trailingByte, 8)
        XCTAssertTrue(reading.isCurrentDQGood)
        XCTAssertTrue(reading.isHistoricalDQGood)
        XCTAssertTrue(reading.isCurrentGlucoseUsable)
    }

    func testDecodesFromSliceWithNonZeroStartIndex() throws {
        let padded = Data([0xFF, 0xFF]) + Plaintext().data
        let reading = try Libre3RealtimeGlucoseReading(plaintext: padded.dropFirst(2))
        XCTAssertEqual(reading.lifeCount, 1500)
        XCTAssertEqual(reading.fastData, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(reading.trailingByte, 8)
    }

    func testMissingRateOfChangeIsReportedAsUnavailable() throws {
        let reading = try Plaintext(rateOfChange: .min).reading()
        XCTAssertNil(reading.rateOfChangeMgDLPerMinute)
        XCTAssertFalse(reading.rateOfChangeAvailable)
        XCTAssertFalse(reading.qualityEvidence.rateOfChangeAvailable)
    }

    func testPackedWordSeparatesGlucoseConditionAndQualityFlag() throws {
        // bits 13-14 hold the condition, bit 15 marks a data quality error that keeps the whole word
        let invalid = try Plaintext(currentWord: 0x2000 | 140).reading()
        XCTAssertEqual(invalid.readingMgDL, 140)
        XCTAssertEqual(invalid.sensorCondition, .invalid)
        XCTAssertEqual(invalid.dqErrorRaw, 0)

        let esa = try Plaintext(currentWord: 0x4000 | 90).reading()
        XCTAssertEqual(esa.sensorCondition, .esa)
        XCTAssertEqual(esa.sensorConditionRaw, 2)

        let raw = try Plaintext(currentWord: 0x6000).reading()
        XCTAssertEqual(raw.sensorCondition, .raw(3))

        let tooHot = try Plaintext(currentWord: 0xA005).reading()
        XCTAssertEqual(tooHot.dqErrorRaw, 0xA005)
        XCTAssertEqual(tooHot.dqError, .sensorTooHot(rawValue: 0xA005))
        XCTAssertEqual(tooHot.readingMgDL, 5)
        XCTAssertFalse(tooHot.isCurrentDQGood)
    }

    func testHistoricalWordProvidesRangeStatusAndQuality() throws {
        let below = try Plaintext(historicalWord: 0x2000 | 50).reading()
        XCTAssertEqual(below.historicResultRangeStatus, .belowRange)
        XCTAssertFalse(below.isHistoricalDQGood)
        let above = try Plaintext(historicalWord: 0x4000 | 450).reading()
        XCTAssertEqual(above.historicResultRangeStatus, .aboveRange)
        XCTAssertEqual(above.historicResultRangeStatusRaw, 2)
        let cold = try Plaintext(historicalWord: 0xC010).reading()
        XCTAssertEqual(cold.historicalReadingDQError, .sensorTooCold(rawValue: 0xC010))
        XCTAssertEqual(cold.historicResultRangeStatus, .aboveRange)
        XCTAssertFalse(cold.isHistoricalDQGood)
    }

    func testDisplayedGlucoseIsNormalizedToTheDisplayRange() throws {
        let cases: [(UInt16, UInt16?)] = [(0, nil), (1, 39), (38, 39), (39, 39), (250, 250), (501, 501), (502, 501), (999, 501), (1000, nil), (0xFFFF, nil)]
        for (raw, expected) in cases {
            let reading = try Plaintext(current: raw, historic: raw).reading()
            XCTAssertEqual(reading.currentGlucoseMgDL, expected, "raw \(raw)")
            XCTAssertEqual(reading.historicalGlucoseMgDL, expected, "raw \(raw)")
            XCTAssertEqual(reading.isCurrentGlucoseValid, expected != nil)
            XCTAssertEqual(reading.uncappedCurrentMgDL, raw)
        }
    }

    func testTrendBitsMapToTrendKinds() throws {
        let expected: [Libre3Trend] = [.notDetermined, .fallingQuickly, .falling, .stable, .rising, .risingQuickly, .raw(6), .raw(7)]
        for (bits, trend) in expected.enumerated() {
            let reading = try Plaintext(trendAndRest: UInt8(bits)).reading()
            XCTAssertEqual(reading.trendKind, trend)
            XCTAssertEqual(reading.actionability, .notActionable)
        }
    }

    // MARK: - quality assessment

    func testHealthyReadingIsUsableWithoutIssues() throws {
        let assessment = try Plaintext().reading().currentGlucoseQualityAssessment
        XCTAssertTrue(assessment.isUsable)
        XCTAssertTrue(assessment.issues.isEmpty)
        XCTAssertTrue(assessment.blockingIssues.isEmpty)
        XCTAssertTrue(assessment.advisories.isEmpty)
    }

    func testNotActionableIsOnlyAnAdvisory() throws {
        let reading = try Plaintext(trendAndRest: 0x03).reading()
        let assessment = reading.currentGlucoseQualityAssessment
        XCTAssertTrue(assessment.isUsable)
        XCTAssertEqual(assessment.advisories, [.notActionable(.notActionable)])
        XCTAssertTrue(assessment.blockingIssues.isEmpty)
        XCTAssertTrue(reading.isCurrentGlucoseUsable(lifecycle: nil))
    }

    func testEveryBlockingIssueIsCollected() throws {
        let reading = try Plaintext(currentWord: 0xA005, trendAndRest: 0x03, current: 0).reading()
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 30, warmupDurationMinutes: 60, wearDurationMinutes: 20160)
        let assessment = reading.currentGlucoseQualityAssessment(lifecycle: lifecycle)
        XCTAssertFalse(assessment.isUsable)
        XCTAssertEqual(assessment.issues, [
            .sensorWarmup(remainingMinutes: 30),
            .currentGlucoseUnavailable(.unavailable(raw: 0)),
            .currentDataQuality(.sensorTooHot(rawValue: 0xA005)),
            .sensorCondition(.invalid),
            .notActionable(.notActionable),
        ])
        XCTAssertEqual(assessment.blockingIssues.count, 4)
        XCTAssertEqual(assessment.advisories.count, 1)
    }

    func testExpiredLifecycleBlocksOtherwiseGoodReading() throws {
        let reading = try Plaintext().reading()
        let expired = Libre3SensorLifecycle(currentLifeCountMinutes: 20160, wearDurationMinutes: 20160)
        XCTAssertEqual(reading.currentGlucoseQualityAssessment(lifecycle: expired).issues, [.sensorExpired])
        XCTAssertFalse(reading.isCurrentGlucoseUsable(lifecycle: expired))
        let active = Libre3SensorLifecycle(currentLifeCountMinutes: 1500, wearDurationMinutes: 20160)
        XCTAssertTrue(reading.isCurrentGlucoseUsable(lifecycle: active))
    }

    func testSensorConditionBlocksUsability() throws {
        let reading = try Plaintext(currentWord: 0x2000 | 120).reading()
        XCTAssertFalse(reading.isCurrentDQGood)
        XCTAssertFalse(reading.isCurrentGlucoseUsable)
        XCTAssertEqual(reading.currentGlucoseQualityAssessment.blockingIssues, [.sensorCondition(.invalid)])
    }

    func testQualityEvidenceMirrorsDecodedFields() throws {
        let reading = try Plaintext(currentWord: 0x8001, historicalWord: 0x2010, trendAndRest: 0x2C, current: 600, historic: 20).reading()
        let evidence = reading.qualityEvidence
        XCTAssertEqual(evidence.dqErrorRaw, 0x8001)
        XCTAssertEqual(evidence.dqError, .notDisplayable(rawValue: 0x8001))
        XCTAssertEqual(evidence.historicalReadingDQErrorRaw, 0)
        XCTAssertEqual(evidence.sensorCondition, .ok)
        XCTAssertEqual(evidence.historicResultRangeStatus, .belowRange)
        XCTAssertEqual(evidence.actionability, .actionable)
        XCTAssertEqual(evidence.currentGlucose, .aboveDisplayRange(raw: 600, displayMgDL: 501))
        XCTAssertEqual(evidence.historicalGlucose, .belowDisplayRange(raw: 20, displayMgDL: 39))
        XCTAssertEqual(evidence.trend, .rising)
        XCTAssertEqual(evidence.trendBits, 4)
        XCTAssertEqual(evidence.statusBits, 5)
        XCTAssertEqual(evidence.temperatureRaw, 3300)
        XCTAssertEqual(evidence.fastDataWordsLE, reading.fastDataWordsLE)
        XCTAssertEqual(reading.currentGlucoseStatus, evidence.currentGlucose)
        XCTAssertEqual(reading.historicalGlucoseStatus, evidence.historicalGlucose)
    }

    // MARK: - enums

    func testDataQualityErrorClassification() {
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0), .good)
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0xA001), .sensorTooHot(rawValue: 0xA001))
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0xBFFF), .sensorTooHot(rawValue: 0xBFFF))
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0xC000), .sensorTooCold(rawValue: 0xC000))
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0x8000), .notDisplayable(rawValue: 0x8000))
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0xE000), .notDisplayable(rawValue: 0xE000))
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0x1234), .raw(0x1234))
    }

    func testDataQualityErrorRoundTripsAndDescribesItself() {
        let errors: [Libre3DataQualityError] = [.good, .sensorTooHot(rawValue: 0xA0AB), .sensorTooCold(rawValue: 0xC001), .notDisplayable(rawValue: 0x8002), .raw(0x0010)]
        for error in errors {
            XCTAssertEqual(Libre3DataQualityError(rawValue: error.rawValue), error)
        }
        XCTAssertEqual(errors.map(\.description), ["good", "sensorTooHot(0xa0ab)", "sensorTooCold(0xc001)", "notDisplayable(0x8002)", "raw(0x0010)"])
        XCTAssertEqual(errors.map(\.isGood), [true, false, false, false, false])
        XCTAssertEqual(errors.map(\.isNotDisplayable), [false, true, true, true, false])
    }

    func testSensorConditionRawValuesAndDescriptions() {
        let values: [Libre3SensorCondition] = (0...3).map { Libre3SensorCondition(rawValue: UInt8($0)) }
        XCTAssertEqual(values, [.ok, .invalid, .esa, .raw(3)])
        XCTAssertEqual(values.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(values.map(\.description), ["ok", "invalid", "esa", "raw(3)"])
    }

    func testResultRangeStatusRawValuesAndDescriptions() {
        let values: [Libre3ResultRangeStatus] = (0...3).map { Libre3ResultRangeStatus(rawValue: UInt8($0)) }
        XCTAssertEqual(values, [.inRange, .belowRange, .aboveRange, .raw(3)])
        XCTAssertEqual(values.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(values.map(\.description), ["inRange", "belowRange", "aboveRange", "raw(3)"])
    }

    func testActionableStatusRawValuesAndDescriptions() {
        let values: [Libre3ActionableStatus] = (0...2).map { Libre3ActionableStatus(rawValue: UInt8($0)) }
        XCTAssertEqual(values, [.notActionable, .actionable, .raw(2)])
        XCTAssertEqual(values.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(values.map(\.description), ["notActionable", "actionable", "raw(2)"])
    }

    func testTrendRawValuesAndDescriptions() {
        let values: [Libre3Trend] = (0...6).map { Libre3Trend(rawValue: UInt8($0)) }
        XCTAssertEqual(values.map(\.rawValue), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(values.map(\.description), ["notDetermined", "fallingQuickly", "falling", "stable", "rising", "risingQuickly", "raw(6)"])
    }

    func testGlycemicAlarmStatusRawValuesAndDescriptions() {
        let values: [Libre3GlycemicAlarmStatus] = (0...6).map { Libre3GlycemicAlarmStatus(rawValue: UInt8($0)) }
        XCTAssertEqual(values, [.alarmNotDetermined, .lowGlucose, .projectedLowGlucose, .normalGlucose, .projectedHighGlucose, .highGlucose, .raw(6)])
        XCTAssertEqual(values.map(\.rawValue), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(values.map(\.description), ["alarmNotDetermined", "lowGlucose", "projectedLowGlucose", "normalGlucose", "projectedHighGlucose", "highGlucose", "raw(6)"])
    }

    func testGlucoseValueStatusDescriptionsAndDisplayability() {
        let statuses: [Libre3GlucoseValueStatus] = [.init(rawSensorValue: 100), .init(rawSensorValue: 10), .init(rawSensorValue: 700), .init(rawSensorValue: 0)]
        XCTAssertEqual(statuses.map(\.description), ["valid(100)", "belowDisplayRange(raw: 10, displayMgDL: 39)", "aboveDisplayRange(raw: 700, displayMgDL: 501)", "unavailable(raw: 0)"])
        XCTAssertEqual(statuses.map(\.isDisplayable), [true, true, true, false])
        XCTAssertEqual(statuses.map(\.displayMgDL), [100, 39, 501, nil])
    }

    func testQualityIssueDescriptionsAndSeverity() {
        let issues: [Libre3GlucoseQualityIssue] = [
            .sensorWarmup(remainingMinutes: 12), .sensorExpired, .currentGlucoseUnavailable(.unavailable(raw: 0)),
            .currentDataQuality(.good), .sensorCondition(.esa), .notActionable(.raw(9)),
        ]
        XCTAssertEqual(issues.map(\.description), [
            "sensorWarmup(remainingMinutes: 12)", "sensorExpired", "currentGlucoseUnavailable(unavailable(raw: 0))",
            "currentDataQuality(good)", "sensorCondition(esa)", "notActionable(raw(9))",
        ])
        XCTAssertEqual(issues.map(\.isAdvisory), [false, false, false, false, false, true])
        XCTAssertEqual(issues.map(\.isUsabilityBlocking), [true, true, true, true, true, false])
    }

    // MARK: - Libre3SensorLifecycle

    func testLifecyclePhasesAcrossTheSensorLife() {
        let warmup = Libre3SensorLifecycle(currentLifeCountMinutes: 10, wearDurationMinutes: 100)
        XCTAssertEqual(warmup.phase, .warmup)
        XCTAssertTrue(warmup.isWarmingUp)
        XCTAssertEqual(warmup.remainingWarmupMinutes, 50)
        XCTAssertEqual(warmup.remainingWearMinutes, 90)
        let active = Libre3SensorLifecycle(currentLifeCountMinutes: 60, wearDurationMinutes: 100)
        XCTAssertEqual(active.phase, .active)
        XCTAssertTrue(active.isActive)
        XCTAssertTrue(active.isWarmupComplete)
        XCTAssertEqual(active.remainingWarmupMinutes, 0)
        let expired = Libre3SensorLifecycle(currentLifeCountMinutes: 100, wearDurationMinutes: 100)
        XCTAssertEqual(expired.phase, .expired)
        XCTAssertTrue(expired.isExpired)
        XCTAssertFalse(expired.isWarmingUp)
        XCTAssertEqual(expired.remainingWearMinutes, 0)
    }

    func testLifecycleExpiredDuringWarmupIsNotWarmingUp() {
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 30, warmupDurationMinutes: 60, wearDurationMinutes: 20)
        XCTAssertTrue(lifecycle.isExpired)
        XCTAssertFalse(lifecycle.isWarmingUp)
        XCTAssertEqual(lifecycle.phase, .expired)
    }

    func testLifecycleClampsNegativeValues() {
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: -5, warmupDurationMinutes: -10, wearDurationMinutes: -1)
        XCTAssertEqual(lifecycle.elapsedMinutes, 0)
        XCTAssertEqual(lifecycle.warmupDurationMinutes, 0)
        XCTAssertEqual(lifecycle.wearDurationMinutes, 0)
        XCTAssertTrue(lifecycle.isExpired)
    }

    func testLifecycleWithoutWearDurationNeverExpires() {
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 1_000_000)
        XCTAssertFalse(lifecycle.isExpired)
        XCTAssertNil(lifecycle.remainingWearMinutes)
        XCTAssertEqual(lifecycle.warmupDurationMinutes, Libre3SensorLifecycle.defaultWarmupDurationMinutes)
        XCTAssertEqual(lifecycle.phase, .active)
        XCTAssertEqual(Libre3SensorLifecyclePhase.active.rawValue, "active")
    }
}
