//
//  Libre3RealtimeGlucoseReadingTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the decoding of the 29-byte Libre 3 realtime glucose plaintext and the quality
/// rules built on it.
///
/// A wrong offset, a lost sign bit, a mis-masked packed word or a too-permissive quality
/// rule would turn sensor errors into plausible glucose values (or drop good ones), and
/// those values feed alarms and dosing decisions. Every expectation below is derived from
/// the byte layout in `Libre3RealtimeGlucoseReading.init(plaintext:)`.
final class Libre3RealtimeGlucoseReadingTests: XCTestCase {

    // MARK: - layout and size validation

    /// The builder's defaults must reproduce a real capture byte for byte, otherwise every
    /// synthetic test below would be checking a layout the sensor never sends.
    func testBuilderDefaultsReproduceLiveCapture() {
        XCTAssertEqual(
            Libre3RealtimePlaintextBuilder().data.hex,
            "e3386200d6ff0000f023d1386c000b62006c00200a9e03113d03100000"
        )
    }

    func testRejectsEveryPlaintextSizeOtherThan29() {
        let valid = Libre3RealtimePlaintextBuilder().data
        for size in [0, 1, 14, 28, 30, 35] {
            let plaintext = size <= valid.count
                ? valid.prefix(size)
                : valid + Data(repeating: 0, count: size - valid.count)
            XCTAssertThrowsError(try Libre3RealtimeGlucoseReading(plaintext: Data(plaintext)), "size \(size)") { error in
                XCTAssertEqual(error as? Libre3RealtimeGlucoseReadingError, .wrongPlaintextSize(size))
            }
        }
    }

    /// Every field sits at its own offset and is little-endian: distinct high and low bytes
    /// per field catch both swapped offsets and big-endian reads.
    func testDecodesEachFieldFromItsOwnLittleEndianOffset() throws {
        var builder = Libre3RealtimePlaintextBuilder()
        builder.lifeCount = 0x1234
        builder.currentWord = 0x0123
        builder.rateOfChangeRaw = 0x0456
        builder.temperatureStatus = 0x0789
        builder.projectedGlucose = 0x0abc
        builder.historicalLifeCount = 0x1def
        builder.historicalWord = 0x00fe
        builder.trendAndStatusByte = 0x0c
        builder.uncappedCurrentMgDL = 0x0111
        builder.uncappedHistoricMgDL = 0x0122
        builder.temperature = 0x0b0a
        builder.fastData = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        let reading = try builder.reading()

        XCTAssertEqual(reading.lifeCount, 0x1234)
        XCTAssertEqual(reading.currentWord, 0x0123)
        XCTAssertEqual(reading.readingMgDL, 0x0123)
        XCTAssertEqual(reading.rateOfChangeRaw, 0x0456)
        XCTAssertEqual(reading.temperatureStatus, 0x0789)
        XCTAssertEqual(reading.projectedGlucose, 0x0abc)
        XCTAssertEqual(reading.historicalLifeCount, 0x1def)
        XCTAssertEqual(reading.historicalWord, 0x00fe)
        XCTAssertEqual(reading.historicalReading, 0x00fe)
        XCTAssertEqual(reading.trendAndStatusByte, 0x0c)
        XCTAssertEqual(reading.uncappedCurrentMgDL, 0x0111)
        XCTAssertEqual(reading.currentGlucoseMgDL, 0x0111)
        XCTAssertEqual(reading.uncappedHistoricMgDL, 0x0122)
        XCTAssertEqual(reading.historicalGlucoseMgDL, 0x0122)
        XCTAssertEqual(reading.temperature, 0x0b0a)
        XCTAssertEqual(reading.fastData, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        XCTAssertEqual(reading.fastDataWordsLE, [0x0201, 0x0403, 0x0605, 0x0807])
        XCTAssertEqual(reading.trailingByte, 0x08)
    }

    /// 29 bytes give 14 complete little-endian words; the odd last byte is only exposed as
    /// `trailingByte` and must not be folded into a 15th word.
    func testWordsLECoversOnlyCompleteWordsAndKeepsTrailingByteSeparate() throws {
        let plaintext = Data((0..<29).map { UInt8($0) })
        let reading = try Libre3RealtimeGlucoseReading(plaintext: plaintext)

        XCTAssertEqual(reading.wordsLE.count, 14)
        XCTAssertEqual(reading.wordsLE.first, 0x0100)
        XCTAssertEqual(reading.wordsLE.last, 0x1b1a)
        XCTAssertEqual(reading.trailingByte, 28)
    }

    /// Decrypted payloads may arrive as `Data` slices; offsets must be relative to
    /// `startIndex`, or the reading would be decoded from the wrong bytes.
    func testParsesPlaintextSliceWithNonZeroStartIndex() throws {
        let plaintext = Libre3RealtimePlaintextBuilder().data
        let slice = Libre3ProtocolFixtures.sliced(plaintext)
        XCTAssertNotEqual(slice.startIndex, 0)

        XCTAssertEqual(try Libre3RealtimeGlucoseReading(plaintext: slice), try Libre3RealtimeGlucoseReading(plaintext: plaintext))
    }

    // MARK: - rate of change

    /// The rate is a signed hundredths-of-mg/dL-per-minute value; `Int16.min` is the
    /// "not available" sentinel and must not become -327.68 mg/dL/min.
    func testRateOfChangeIsSignedHundredthsWithInt16MinAsUnavailable() throws {
        let cases: [(raw: Int16, expected: Float?)] = [
            (0, 0),
            (-1, -0.01),
            (1, 0.01),
            (-250, -2.5),
            (Int16.max, 327.67),
            (Int16.min + 1, -327.67),
            (Int16.min, nil),
        ]
        for c in cases {
            var builder = Libre3RealtimePlaintextBuilder()
            builder.rateOfChangeRaw = c.raw
            let reading = try builder.reading()

            XCTAssertEqual(reading.rateOfChangeRaw, c.raw)
            XCTAssertEqual(reading.rateOfChangeAvailable, c.expected != nil, "raw \(c.raw)")
            XCTAssertEqual(reading.qualityEvidence.rateOfChangeAvailable, c.expected != nil)
            if let expected = c.expected {
                XCTAssertEqual(try XCTUnwrap(reading.rateOfChangeMgDLPerMinute), expected, accuracy: 0.0001, "raw \(c.raw)")
            } else {
                XCTAssertNil(reading.rateOfChangeMgDLPerMinute)
            }
        }
    }

    // MARK: - packed words

    /// The current word packs a 13-bit glucose value, a 2-bit sensor condition (bits 13-14)
    /// and a DQ error flag (bit 15, the whole word is then the error code).
    func testCurrentPackedWordSplitsGlucoseConditionAndDQError() throws {
        let cases: [(word: UInt16, mgDL: UInt16, dqRaw: UInt16, dq: Libre3DataQualityError, conditionRaw: UInt8, condition: Libre3SensorCondition)] = [
            (0x0062, 98, 0, .good, 0, .ok),
            (0x1fff, 0x1fff, 0, .good, 0, .ok),
            (0x2062, 98, 0, .good, 1, .invalid),
            (0x4062, 98, 0, .good, 2, .esa),
            (0x6062, 98, 0, .good, 3, .raw(3)),
            (0x8062, 98, 0x8062, .notDisplayable(rawValue: 0x8062), 0, .ok),
            (0xa062, 98, 0xa062, .sensorTooHot(rawValue: 0xa062), 1, .invalid),
            (0xc062, 98, 0xc062, .sensorTooCold(rawValue: 0xc062), 2, .esa),
            (0xe062, 98, 0xe062, .notDisplayable(rawValue: 0xe062), 3, .raw(3)),
        ]
        for c in cases {
            var builder = Libre3RealtimePlaintextBuilder()
            builder.currentWord = c.word
            let reading = try builder.reading()

            XCTAssertEqual(reading.readingMgDL, c.mgDL, "word \(c.word)")
            XCTAssertEqual(reading.dqErrorRaw, c.dqRaw, "word \(c.word)")
            XCTAssertEqual(reading.dqError, c.dq, "word \(c.word)")
            XCTAssertEqual(reading.sensorConditionRaw, c.conditionRaw, "word \(c.word)")
            XCTAssertEqual(reading.sensorCondition, c.condition, "word \(c.word)")
            XCTAssertEqual(reading.isCurrentDQGood, c.dq == .good && c.condition == .ok, "word \(c.word)")
        }
    }

    /// The historical word uses the same packing, but bits 13-14 carry the result range
    /// status; only an in-range, error-free historical value counts as good.
    func testHistoricalPackedWordSplitsGlucoseRangeStatusAndDQError() throws {
        let cases: [(word: UInt16, mgDL: UInt16, dq: Libre3DataQualityError, rangeRaw: UInt8, range: Libre3ResultRangeStatus, good: Bool)] = [
            (0x006c, 108, .good, 0, .inRange, true),
            (0x2027, 39, .good, 1, .belowRange, false),
            (0x41f5, 501, .good, 2, .aboveRange, false),
            (0x606c, 108, .good, 3, .raw(3), false),
            (0x806c, 108, .notDisplayable(rawValue: 0x806c), 0, .inRange, false),
            (0xc06c, 108, .sensorTooCold(rawValue: 0xc06c), 2, .aboveRange, false),
        ]
        for c in cases {
            var builder = Libre3RealtimePlaintextBuilder()
            builder.historicalWord = c.word
            let reading = try builder.reading()

            XCTAssertEqual(reading.historicalReading, c.mgDL, "word \(c.word)")
            XCTAssertEqual(reading.historicalReadingDQError, c.dq, "word \(c.word)")
            XCTAssertEqual(reading.historicalReadingDQErrorRaw, c.dq.rawValue, "word \(c.word)")
            XCTAssertEqual(reading.historicResultRangeStatusRaw, c.rangeRaw, "word \(c.word)")
            XCTAssertEqual(reading.historicResultRangeStatus, c.range, "word \(c.word)")
            XCTAssertEqual(reading.isHistoricalDQGood, c.good, "word \(c.word)")
            // The historical quality never leaks into the current-reading verdict.
            XCTAssertTrue(reading.isCurrentDQGood, "word \(c.word)")
        }
    }

    /// Byte 14 packs the trend in bits 0-2, the actionable flag in bit 3 and further status
    /// bits above it (`rest` is the byte shifted right by 3, so it includes the flag).
    func testTrendByteSplitsTrendActionableFlagAndStatusBits() throws {
        let cases: [(byte: UInt8, trend: UInt8, kind: Libre3Trend, rest: UInt8, actionable: UInt8, actionability: Libre3ActionableStatus)] = [
            (0x00, 0, .notDetermined, 0x00, 0, .notActionable),
            (0x09, 1, .fallingQuickly, 0x01, 1, .actionable),
            (0x02, 2, .falling, 0x00, 0, .notActionable),
            (0x0b, 3, .stable, 0x01, 1, .actionable),
            (0x0c, 4, .rising, 0x01, 1, .actionable),
            (0x0d, 5, .risingQuickly, 0x01, 1, .actionable),
            (0x0e, 6, .raw(6), 0x01, 1, .actionable),
            (0x07, 7, .raw(7), 0x00, 0, .notActionable),
            (0xf1, 1, .fallingQuickly, 0x1e, 0, .notActionable),
            (0xff, 7, .raw(7), 0x1f, 1, .actionable),
        ]
        for c in cases {
            var builder = Libre3RealtimePlaintextBuilder()
            builder.trendAndStatusByte = c.byte
            let reading = try builder.reading()

            XCTAssertEqual(reading.trend, c.trend, "byte \(c.byte)")
            XCTAssertEqual(reading.trendRaw, c.trend, "byte \(c.byte)")
            XCTAssertEqual(reading.trendKind, c.kind, "byte \(c.byte)")
            XCTAssertEqual(reading.rest, c.rest, "byte \(c.byte)")
            XCTAssertEqual(reading.statusBits, c.rest, "byte \(c.byte)")
            XCTAssertEqual(reading.actionableStatus, c.actionable, "byte \(c.byte)")
            XCTAssertEqual(reading.actionability, c.actionability, "byte \(c.byte)")
        }
    }

    // MARK: - glucose normalisation

    /// Abbott clamps raw values: 1-38 show as 39 (LO), 502-999 as 501 (HI), 0 and 1000+
    /// are not glucose at all. Off-by-one errors here change what the user sees at the edges.
    func testGlucoseValueStatusBoundaries() {
        let cases: [(raw: UInt16, status: Libre3GlucoseValueStatus, display: UInt16?)] = [
            (0, .unavailable(raw: 0), nil),
            (1, .belowDisplayRange(raw: 1, displayMgDL: 39), 39),
            (38, .belowDisplayRange(raw: 38, displayMgDL: 39), 39),
            (39, .valid(mgDL: 39), 39),
            (501, .valid(mgDL: 501), 501),
            (502, .aboveDisplayRange(raw: 502, displayMgDL: 501), 501),
            (999, .aboveDisplayRange(raw: 999, displayMgDL: 501), 501),
            (1000, .unavailable(raw: 1000), nil),
            (UInt16.max, .unavailable(raw: UInt16.max), nil),
        ]
        for c in cases {
            let status = Libre3GlucoseValueStatus(rawSensorValue: c.raw)
            XCTAssertEqual(status, c.status, "raw \(c.raw)")
            XCTAssertEqual(status.displayMgDL, c.display, "raw \(c.raw)")
            XCTAssertEqual(status.isDisplayable, c.display != nil, "raw \(c.raw)")
        }
    }

    /// The historical value is normalised with the same clamp as the current one, and an
    /// unavailable historical value must not make the current reading unusable.
    func testHistoricalGlucoseIsNormalisedIndependentlyOfCurrent() throws {
        var builder = Libre3RealtimePlaintextBuilder()
        builder.uncappedHistoricMgDL = 20
        let low = try builder.reading()
        XCTAssertEqual(low.historicalGlucoseMgDL, 39)
        XCTAssertTrue(low.isHistoricalGlucoseValid)
        XCTAssertEqual(low.historicalGlucoseStatus, .belowDisplayRange(raw: 20, displayMgDL: 39))

        builder.uncappedHistoricMgDL = 0
        let missing = try builder.reading()
        XCTAssertNil(missing.historicalGlucoseMgDL)
        XCTAssertFalse(missing.isHistoricalGlucoseValid)
        XCTAssertEqual(missing.qualityEvidence.historicalGlucose, .unavailable(raw: 0))
        XCTAssertTrue(missing.isCurrentGlucoseUsable)
        XCTAssertTrue(missing.currentGlucoseQualityAssessment.isUsable)
    }

    /// The displayed value comes from the uncapped field (offset 15), not from the 13-bit
    /// glucose in the packed word, so the two can legitimately differ.
    func testCurrentGlucoseComesFromUncappedFieldNotPackedWord() throws {
        var builder = Libre3RealtimePlaintextBuilder()
        builder.currentWord = 120
        builder.uncappedCurrentMgDL = 700
        let reading = try builder.reading()

        XCTAssertEqual(reading.readingMgDL, 120)
        XCTAssertEqual(reading.currentGlucoseMgDL, 501)
        XCTAssertEqual(reading.currentGlucoseStatus, .aboveDisplayRange(raw: 700, displayMgDL: 501))
    }

    // MARK: - enum mappings

    func testDataQualityErrorClassifiesRawCodes() {
        let cases: [(raw: UInt16, expected: Libre3DataQualityError, notDisplayable: Bool)] = [
            (0x0000, .good, false),
            (0x1234, .raw(0x1234), false),
            (0x7fff, .raw(0x7fff), false),
            (0x8000, .notDisplayable(rawValue: 0x8000), true),
            (0x9fff, .notDisplayable(rawValue: 0x9fff), true),
            (0xa000, .sensorTooHot(rawValue: 0xa000), true),
            (0xbfff, .sensorTooHot(rawValue: 0xbfff), true),
            (0xc000, .sensorTooCold(rawValue: 0xc000), true),
            (0xdfff, .sensorTooCold(rawValue: 0xdfff), true),
            (0xe000, .notDisplayable(rawValue: 0xe000), true),
            (0xffff, .notDisplayable(rawValue: 0xffff), true),
        ]
        for c in cases {
            let error = Libre3DataQualityError(rawValue: c.raw)
            XCTAssertEqual(error, c.expected, "raw \(c.raw)")
            XCTAssertEqual(error.rawValue, c.raw, "raw value must survive the round trip")
            XCTAssertEqual(error.isGood, c.raw == 0, "raw \(c.raw)")
            XCTAssertEqual(error.isNotDisplayable, c.notDisplayable, "raw \(c.raw)")
        }
    }

    /// Unknown codes are preserved as `.raw` rather than coerced into a named case, so no
    /// byte value is lost when evidence is logged or persisted.
    func testStatusEnumsRoundTripEveryByteValue() {
        for value in UInt8.min...UInt8.max {
            XCTAssertEqual(Libre3SensorCondition(rawValue: value).rawValue, value)
            XCTAssertEqual(Libre3ResultRangeStatus(rawValue: value).rawValue, value)
            XCTAssertEqual(Libre3ActionableStatus(rawValue: value).rawValue, value)
            XCTAssertEqual(Libre3Trend(rawValue: value).rawValue, value)
            XCTAssertEqual(Libre3GlycemicAlarmStatus(rawValue: value).rawValue, value)
        }
        XCTAssertEqual(Libre3Trend(rawValue: 6), .raw(6))
        XCTAssertEqual(Libre3SensorCondition(rawValue: 3), .raw(3))
        XCTAssertEqual(Libre3ResultRangeStatus(rawValue: 3), .raw(3))
        XCTAssertEqual(Libre3ActionableStatus(rawValue: 2), .raw(2))
    }

    func testGlycemicAlarmStatusMapsAbbottCodes() {
        let expected: [Libre3GlycemicAlarmStatus] = [
            .alarmNotDetermined, .lowGlucose, .projectedLowGlucose,
            .normalGlucose, .projectedHighGlucose, .highGlucose, .raw(6),
        ]
        for (code, status) in expected.enumerated() {
            XCTAssertEqual(Libre3GlycemicAlarmStatus(rawValue: UInt8(code)), status)
        }
        XCTAssertEqual(
            (0...6).map { Libre3GlycemicAlarmStatus(rawValue: UInt8($0)).description },
            ["alarmNotDetermined", "lowGlucose", "projectedLowGlucose", "normalGlucose",
             "projectedHighGlucose", "highGlucose", "raw(6)"]
        )
    }

    /// Descriptions end up in the troubleshooting log; hex codes must be zero-padded and
    /// lower-case so log lines can be grepped against captures.
    func testDescriptionsUsedInLogs() {
        XCTAssertEqual(Libre3DataQualityError.good.description, "good")
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0xa062).description, "sensorTooHot(0xa062)")
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0xc001).description, "sensorTooCold(0xc001)")
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0x8062).description, "notDisplayable(0x8062)")
        XCTAssertEqual(Libre3DataQualityError(rawValue: 0x0042).description, "raw(0x0042)")

        XCTAssertEqual(
            (0...3).map { Libre3SensorCondition(rawValue: UInt8($0)).description },
            ["ok", "invalid", "esa", "raw(3)"]
        )
        XCTAssertEqual(
            (0...3).map { Libre3ResultRangeStatus(rawValue: UInt8($0)).description },
            ["inRange", "belowRange", "aboveRange", "raw(3)"]
        )
        XCTAssertEqual(
            (0...2).map { Libre3ActionableStatus(rawValue: UInt8($0)).description },
            ["notActionable", "actionable", "raw(2)"]
        )
        XCTAssertEqual(
            (0...6).map { Libre3Trend(rawValue: UInt8($0)).description },
            ["notDetermined", "fallingQuickly", "falling", "stable", "rising", "risingQuickly", "raw(6)"]
        )
        XCTAssertEqual(Libre3GlucoseValueStatus(rawSensorValue: 100).description, "valid(100)")
        XCTAssertEqual(
            Libre3GlucoseValueStatus(rawSensorValue: 12).description,
            "belowDisplayRange(raw: 12, displayMgDL: 39)"
        )
        XCTAssertEqual(
            Libre3GlucoseValueStatus(rawSensorValue: 600).description,
            "aboveDisplayRange(raw: 600, displayMgDL: 501)"
        )
        XCTAssertEqual(Libre3GlucoseValueStatus(rawSensorValue: 0).description, "unavailable(raw: 0)")
    }

    // MARK: - quality assessment

    func testCleanReadingWithoutLifecycleIsUsableWithNoIssues() throws {
        let reading = try Libre3RealtimePlaintextBuilder().reading()
        let assessment = reading.currentGlucoseQualityAssessment

        XCTAssertTrue(assessment.isUsable)
        XCTAssertEqual(assessment.issues, [])
        XCTAssertEqual(assessment.evidence, reading.qualityEvidence)
        XCTAssertTrue(reading.isCurrentGlucoseUsable(lifecycle: nil))
    }

    /// During warmup the sensor already sends numbers, but they must not be used; the issue
    /// carries the remaining warmup minutes so the UI can count down.
    func testWarmupLifecycleBlocksAndReportsRemainingMinutes() throws {
        let reading = try Libre3RealtimePlaintextBuilder().reading()
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 12, warmupDurationMinutes: 60, wearDurationMinutes: 21600)

        let assessment = reading.currentGlucoseQualityAssessment(lifecycle: lifecycle)

        XCTAssertFalse(assessment.isUsable)
        XCTAssertEqual(assessment.issues, [.sensorWarmup(remainingMinutes: 48)])
        XCTAssertEqual(assessment.blockingIssues, [.sensorWarmup(remainingMinutes: 48)])
        XCTAssertEqual(assessment.advisories, [])
        XCTAssertFalse(reading.isCurrentGlucoseUsable(lifecycle: lifecycle))
        // The lifecycle-free convenience ignores warmup, which is why callers must pass one.
        XCTAssertTrue(reading.isCurrentGlucoseUsable)
    }

    /// Expiry wins over warmup: a sensor whose wear ended reports only `.sensorExpired`,
    /// even with a warmup longer than its wear (e.g. corrupted patch info).
    func testExpiredLifecycleReportsExpiryInsteadOfWarmup() throws {
        let reading = try Libre3RealtimePlaintextBuilder().reading()
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 100, warmupDurationMinutes: 200, wearDurationMinutes: 100)

        let assessment = reading.currentGlucoseQualityAssessment(lifecycle: lifecycle)

        XCTAssertFalse(assessment.isUsable)
        XCTAssertEqual(assessment.issues, [.sensorExpired])
    }

    func testActiveLifecycleKeepsCleanReadingUsable() throws {
        let reading = try Libre3RealtimePlaintextBuilder().reading()
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 60, warmupDurationMinutes: 60, wearDurationMinutes: 21600)

        XCTAssertEqual(reading.currentGlucoseQualityAssessment(lifecycle: lifecycle).issues, [])
        XCTAssertTrue(reading.isCurrentGlucoseUsable(lifecycle: lifecycle))
    }

    /// All problems are reported together and in a stable order; only `.notActionable` is
    /// advisory, everything else blocks.
    func testAllIssuesAreReportedInOrderAndSplitIntoBlockingAndAdvisory() throws {
        var builder = Libre3RealtimePlaintextBuilder()
        builder.currentWord = 0xa062
        builder.uncappedCurrentMgDL = 0
        builder.trendAndStatusByte = 0x03
        let reading = try builder.reading()
        let lifecycle = Libre3SensorLifecycle(currentLifeCountMinutes: 30, warmupDurationMinutes: 60)

        let assessment = reading.currentGlucoseQualityAssessment(lifecycle: lifecycle)

        let blocking: [Libre3GlucoseQualityIssue] = [
            .sensorWarmup(remainingMinutes: 30),
            .currentGlucoseUnavailable(.unavailable(raw: 0)),
            .currentDataQuality(.sensorTooHot(rawValue: 0xa062)),
            .sensorCondition(.invalid),
        ]
        XCTAssertEqual(assessment.issues, blocking + [.notActionable(.notActionable)])
        XCTAssertEqual(assessment.blockingIssues, blocking)
        XCTAssertEqual(assessment.advisories, [.notActionable(.notActionable)])
        XCTAssertFalse(assessment.isUsable)
    }

    /// A non-actionable but otherwise clean reading stays usable: the flag is surfaced as
    /// an advisory only.
    func testNotActionableAloneIsAdvisoryAndKeepsReadingUsable() throws {
        var builder = Libre3RealtimePlaintextBuilder()
        builder.trendAndStatusByte = 0x03
        let assessment = try builder.reading().currentGlucoseQualityAssessment

        XCTAssertTrue(assessment.isUsable)
        XCTAssertEqual(assessment.blockingIssues, [])
        XCTAssertEqual(assessment.advisories, [.notActionable(.notActionable)])
    }

    /// A clamped LO/HI value is still a displayable number and must not be reported as
    /// unavailable; only a DQ flag or sensor condition blocks it.
    func testClampedValuesAreUsableButDQOrConditionBlocks() throws {
        for raw in [UInt16(1), 38, 502, 999] {
            var builder = Libre3RealtimePlaintextBuilder()
            builder.uncappedCurrentMgDL = raw
            XCTAssertTrue(try builder.reading().currentGlucoseQualityAssessment.isUsable, "raw \(raw)")
        }

        var esa = Libre3RealtimePlaintextBuilder()
        esa.currentWord = 0x4062
        XCTAssertEqual(try esa.reading().currentGlucoseQualityAssessment.issues, [.sensorCondition(.esa)])

        var cold = Libre3RealtimePlaintextBuilder()
        cold.currentWord = 0xc062
        XCTAssertEqual(
            try cold.reading().currentGlucoseQualityAssessment.issues,
            [.currentDataQuality(.sensorTooCold(rawValue: 0xc062)), .sensorCondition(.esa)]
        )
    }

    func testQualityIssueAdvisoryFlagsAndDescriptions() {
        let cases: [(issue: Libre3GlucoseQualityIssue, advisory: Bool, description: String)] = [
            (.sensorWarmup(remainingMinutes: 48), false, "sensorWarmup(remainingMinutes: 48)"),
            (.sensorExpired, false, "sensorExpired"),
            (.currentGlucoseUnavailable(.unavailable(raw: 0)), false, "currentGlucoseUnavailable(unavailable(raw: 0))"),
            (.currentDataQuality(.notDisplayable(rawValue: 0x8001)), false, "currentDataQuality(notDisplayable(0x8001))"),
            (.sensorCondition(.esa), false, "sensorCondition(esa)"),
            (.notActionable(.notActionable), true, "notActionable(notActionable)"),
        ]
        for c in cases {
            XCTAssertEqual(c.issue.isAdvisory, c.advisory, c.description)
            XCTAssertEqual(c.issue.isUsabilityBlocking, !c.advisory, c.description)
            XCTAssertEqual(c.issue.description, c.description)
        }
    }

    /// The evidence snapshot is what gets logged when a reading is rejected; it must mirror
    /// the decoded fields, not defaults.
    func testQualityEvidenceMirrorsDecodedFields() throws {
        var builder = Libre3RealtimePlaintextBuilder()
        builder.currentWord = 0x2062
        builder.historicalWord = 0x206c
        builder.temperatureStatus = 0x0201
        builder.trendAndStatusByte = 0xf4
        builder.temperature = 0x0abc
        let reading = try builder.reading()
        let evidence = reading.qualityEvidence

        XCTAssertEqual(evidence.sensorConditionRaw, 1)
        XCTAssertEqual(evidence.sensorCondition, .invalid)
        XCTAssertEqual(evidence.historicResultRangeStatusRaw, 1)
        XCTAssertEqual(evidence.historicResultRangeStatus, .belowRange)
        XCTAssertEqual(evidence.temperatureStatus, 0x0201)
        XCTAssertEqual(evidence.trend, .rising)
        XCTAssertEqual(evidence.trendBits, 4)
        XCTAssertEqual(evidence.statusBits, 0x1e)
        XCTAssertEqual(evidence.actionableStatus, 0)
        XCTAssertEqual(evidence.actionability, .notActionable)
        XCTAssertEqual(evidence.temperatureRaw, 0x0abc)
        XCTAssertEqual(evidence.currentGlucose, .valid(mgDL: 98))
        XCTAssertEqual(evidence.historicalGlucose, .valid(mgDL: 108))
        XCTAssertEqual(evidence.fastData, reading.fastData)
    }
}
