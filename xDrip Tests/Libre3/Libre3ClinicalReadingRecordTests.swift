//
//  Libre3ClinicalReadingRecordTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the decoding of the 14-byte Libre 3 clinical record (one per minute, replayed
/// after a disconnect) and the life-count estimate for its embedded historical value.
///
/// The clinical stream is the only source of minute-resolution gap fill; a swapped word
/// would store a raw sensor channel as glucose, and a wrong estimate would key the
/// 5-minute historical value at the wrong time.
final class Libre3ClinicalReadingRecordTests: XCTestCase {

    // MARK: - helpers

    /// Builds a record plaintext from its seven little-endian words.
    private func plaintext(_ words: [UInt16]) -> Data {
        var out = Data()
        for word in words {
            Libre3RealtimePlaintextBuilder.append(word, to: &out)
        }
        return out
    }

    // MARK: - tests

    func testRejectsEveryPlaintextSizeOtherThan14() {
        for size in [0, 2, 12, 13, 15, 16, 29] {
            XCTAssertThrowsError(try Libre3ClinicalReadingRecord(plaintext: Data(count: size)), "size \(size)") { error in
                XCTAssertEqual(error as? Libre3ClinicalReadingRecordError, .wrongPlaintextSize(size))
            }
        }
    }

    /// Words 0-6 map to life count, three raw channels, a reserved word, current glucose
    /// and committed historical glucose, each little-endian.
    func testDecodesSevenLittleEndianWordsInOrder() throws {
        let record = try Libre3ClinicalReadingRecord(
            plaintext: plaintext([0x3901, 0x1234, 0x5678, 0x0e9a, 0xbeef, 0x0062, 0x006c])
        )

        XCTAssertEqual(record.lifeCount, 0x3901)
        XCTAssertEqual(record.rawSensorWord1, 0x1234)
        XCTAssertEqual(record.rawSensorWord2, 0x5678)
        XCTAssertEqual(record.rawSensorWord3, 0x0e9a)
        XCTAssertEqual(record.reservedWord, 0xbeef)
        XCTAssertEqual(record.currentGlucoseRaw, 98)
        XCTAssertEqual(record.historicGlucoseRaw, 108)
        XCTAssertEqual(record.currentGlucoseMgDL, 98)
        XCTAssertEqual(record.historicGlucoseMgDL, 108)
    }

    /// Clinical values use the same LO/HI clamp as the realtime stream, so gap-filled
    /// values match what the realtime stream would have shown.
    func testGlucoseValuesUseRealtimeNormalisation() throws {
        let cases: [(raw: UInt16, status: Libre3GlucoseValueStatus, mgDL: UInt16?)] = [
            (0, .unavailable(raw: 0), nil),
            (38, .belowDisplayRange(raw: 38, displayMgDL: 39), 39),
            (250, .valid(mgDL: 250), 250),
            (600, .aboveDisplayRange(raw: 600, displayMgDL: 501), 501),
            (1000, .unavailable(raw: 1000), nil),
        ]
        for c in cases {
            let record = try Libre3ClinicalReadingRecord(plaintext: plaintext([100, 0, 0, 0, 0, c.raw, c.raw]))
            XCTAssertEqual(record.currentGlucose, c.status, "raw \(c.raw)")
            XCTAssertEqual(record.currentGlucoseMgDL, c.mgDL, "raw \(c.raw)")
            XCTAssertEqual(record.historicGlucose, c.status, "raw \(c.raw)")
            XCTAssertEqual(record.historicGlucoseMgDL, c.mgDL, "raw \(c.raw)")
        }
    }

    /// The historical value belongs to `lifeCount - 17` snapped down to a multiple of 5,
    /// and has no life count at all during the first 17 minutes (no underflow).
    func testHistoricLifeCountEstimateLagsSeventeenAndSnapsToFive() throws {
        let cases: [(lifeCount: UInt16, expected: UInt16?)] = [
            (0, nil),
            (16, nil),
            (17, 0),
            (21, 0),
            (22, 5),
            (100, 80),
            (102, 85),
            (14563, 14545),
            (UInt16.max, 65515),
        ]
        for c in cases {
            let record = try Libre3ClinicalReadingRecord(plaintext: plaintext([c.lifeCount, 0, 0, 0, 0, 0, 0]))
            XCTAssertEqual(record.historicLifeCountEstimate, c.expected, "lifeCount \(c.lifeCount)")
        }
    }

    /// The estimate must agree with the realtime frame for the same minute: the live
    /// capture at life count 14563 carries its historical value at 14545.
    func testHistoricEstimateMatchesRealtimeHistoricalLifeCount() throws {
        let realtime = try Libre3RealtimePlaintextBuilder().reading()
        let record = try Libre3ClinicalReadingRecord(
            plaintext: plaintext([realtime.lifeCount, 0, 0, 0, 0, realtime.uncappedCurrentMgDL, realtime.uncappedHistoricMgDL])
        )

        XCTAssertEqual(record.historicLifeCountEstimate, realtime.historicalLifeCount)
        XCTAssertEqual(record.currentGlucoseMgDL, realtime.currentGlucoseMgDL)
        XCTAssertEqual(record.historicGlucoseMgDL, realtime.historicalGlucoseMgDL)
    }
}
