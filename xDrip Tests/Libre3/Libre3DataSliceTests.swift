//
//  Libre3DataSliceTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression: the clinical record and historical page decoders read `plaintext[0]`,
/// `plaintext[1]`, … as if every `Data` started at index 0. A slice of a larger buffer (for
/// example `frame.dropFirst(2)`) keeps the indices of the buffer, so those reads went out of the
/// slice's bounds and crashed the app. Decryption returns a fresh buffer today, but any caller that
/// passes a slice would crash; the decoders must give the same result for a slice and a copy.
final class Libre3DataSliceTests: XCTestCase {

    /// The same bytes as a slice whose `startIndex` is not 0.
    private func slice(_ bytes: Data, prefix: Int = 3) -> Data {
        let buffer = Data(repeating: 0xEE, count: prefix) + bytes + Data([0xEE])
        let slice = buffer.dropFirst(prefix).dropLast()
        precondition(slice.startIndex == prefix && slice.count == bytes.count)
        return slice
    }

    private func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map { offset -> UInt8 in
            let start = text.index(text.startIndex, offsetBy: offset)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    func testHistoricalPageDecodesASlice() throws {
        let bytes = hex("8e0369006b006d006b0069006e00")

        let fromSlice = try Libre3HistoricalReadingPage(plaintext: slice(bytes))

        XCTAssertEqual(fromSlice, try Libre3HistoricalReadingPage(plaintext: bytes))
        XCTAssertEqual(fromSlice.startLifeCount, 0x038E)
        XCTAssertEqual(fromSlice.values, [0x69, 0x6B, 0x6D, 0x6B, 0x69, 0x6E])
    }

    func testClinicalRecordDecodesASlice() throws {
        let bytes = hex("6400" + "0100" + "0200" + "0300" + "0000" + "7800" + "7300")

        let record = try Libre3ClinicalReadingRecord(plaintext: slice(bytes))

        XCTAssertEqual(record.lifeCount, 100)
        XCTAssertEqual(record.rawSensorWord1, 1)
        XCTAssertEqual(record.rawSensorWord3, 3)
        XCTAssertEqual(record.currentGlucoseRaw, 0x78)
        XCTAssertEqual(record.historicGlucoseRaw, 0x73)
    }

    func testSlicesOfTheWrongSizeAreStillRejected() {
        let bytes = Data(count: 13)

        XCTAssertThrowsError(try Libre3HistoricalReadingPage(plaintext: slice(bytes)))
        XCTAssertThrowsError(try Libre3ClinicalReadingRecord(plaintext: slice(bytes)))
    }
}
