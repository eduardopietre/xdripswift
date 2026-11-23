//
//  DataExtensionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the byte helpers in `Data.swift` that every transmitter parser depends on.
///
/// Dexcom, Libre and bridge parsers read little-endian fields with `to(_:)`, `toInt()` and
/// `uint16/32/64(position:)`, frequently on slices such as `data[10..<12]`. A regression in how
/// these helpers treat slices, short input or byte order would silently corrupt every glucose
/// value, so these tests pin the behaviour the parsers rely on rather than individual constants.
final class DataExtensionTests: XCTestCase {

    // MARK: - hexadecimal string conversion

    /// Every byte value must survive encode/decode so logged packets can be replayed in tests.
    func testHexEncodingRoundTripsEveryByteValue() {
        let allBytes = Data((0...255).map { UInt8($0) })
        let hex = allBytes.hexEncodedString()

        XCTAssertEqual(hex.count, 512)
        XCTAssertTrue(hex.hasPrefix("000102"))
        XCTAssertTrue(hex.hasSuffix("fdfeff"))
        XCTAssertEqual(Data(hexadecimalString: hex), allBytes)
    }

    /// Hex encoding is always lower case, while decoding accepts both cases (logs and
    /// documentation use either), including mixed case within one byte.
    func testHexDecodingIsCaseInsensitiveButEncodingIsLowerCase() {
        XCTAssertEqual(Data(hexadecimalString: "ABCDEF"), Data([0xAB, 0xCD, 0xEF]))
        XCTAssertEqual(Data(hexadecimalString: "aBcDeF"), Data([0xAB, 0xCD, 0xEF]))
        XCTAssertEqual(Data([0xAB, 0xCD, 0xEF]).hexEncodedString(), "abcdef")
    }

    /// The characters directly next to the accepted ranges in ASCII must be rejected, so the
    /// range checks are exactly `0-9`, `A-F` and `a-f`.
    func testHexDecodingRejectsCharactersAdjacentToValidRanges() {
        for invalid in ["/0", "0:", "@0", "0G", "`0", "0g"] {
            XCTAssertNil(Data(hexadecimalString: invalid), invalid)
        }
        XCTAssertEqual(Data(hexadecimalString: "09"), Data([0x09]))
        XCTAssertEqual(Data(hexadecimalString: "Af"), Data([0xAF]))
    }

    /// Separators such as spaces are not skipped: a pasted spaced dump must be cleaned first.
    func testHexDecodingRejectsSeparatorsAndOddLength() {
        XCTAssertNil(Data(hexadecimalString: "01 02"))
        XCTAssertNil(Data(hexadecimalString: "01:02"))
        XCTAssertNil(Data(hexadecimalString: "010"))
    }

    // MARK: - integer extraction

    /// Parsers call `to(_:)` on slices like `data[10..<12]` whose indices do not start at zero.
    /// The value must come from the slice's own bytes, not from the start of the parent buffer.
    func testToReadsFromTheStartOfASlice() {
        let packet = Data([0xAA, 0xBB, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12])

        XCTAssertEqual(packet[2..<4].to(UInt16.self), 0x1234)
        XCTAssertEqual(packet[4..<8].to(UInt32.self), 0x1234_5678)
        let viaToInt: UInt16 = packet[2..<4].toInt()
        XCTAssertEqual(viaToInt, 0x1234)
    }

    /// When fewer bytes than the type's width are available, only those bytes are copied and the
    /// upper bytes stay zero. This is what makes a one-byte suffix compare sensibly in CRC checks.
    func testToWithFewerBytesThanTheTypeZeroFillsTheUpperBytes() {
        XCTAssertEqual(Data([0x01]).to(UInt32.self), 1)
        XCTAssertEqual(Data([0x01, 0x02]).to(UInt64.self), 0x0201)
        XCTAssertEqual(Data().to(UInt16.self), 0)
    }

    /// Extra bytes beyond the type's width are ignored rather than overflowing into memory.
    func testToWithMoreBytesThanTheTypeUsesOnlyTheLeadingBytes() {
        XCTAssertEqual(Data([0x01, 0x02, 0x03, 0x04]).to(UInt16.self), 0x0201)
        XCTAssertEqual(Data([0xFF, 0x00, 0x99]).to(UInt8.self), 0xFF)
    }

    /// Signed reads use two's complement, which the Dexcom parsers rely on for relative times.
    func testToDecodesSignedValuesAsTwosComplement() {
        XCTAssertEqual(Data([0x00, 0x80]).to(Int16.self), Int16.min)
        XCTAssertEqual(Data([0xFE, 0xFF, 0xFF, 0xFF]).to(Int32.self), -2)
        XCTAssertEqual(Data([0xFF, 0xFF, 0xFF, 0x7F]).to(Int32.self), Int32.max)
    }

    /// `uintN(position:)` read little-endian values at an arbitrary offset of a full buffer.
    func testPositionalReadersUseLittleEndianAtTheGivenOffset() {
        let data = Data([0x00, 0xEF, 0xBE, 0xAD, 0xDE, 0x0D, 0xF0, 0xFE, 0xCA, 0x99])

        XCTAssertEqual(data.uint8(position: 1), 0xEF)
        XCTAssertEqual(data.uint16(position: 1), 0xBEEF)
        XCTAssertEqual(data.uint32(position: 1), 0xDEAD_BEEF)
        XCTAssertEqual(data.uint64(position: 1), 0xCAFE_F00D_DEAD_BEEF)
        XCTAssertEqual(data.getByteAt(position: 9), 0x99)
    }

    /// Unsigned readers must not sign-extend: a high bit set must give a large positive value.
    func testPositionalReadersDoNotSignExtend() {
        let data = Data(repeating: 0xFF, count: 8)

        XCTAssertEqual(data.uint16(position: 0), UInt16.max)
        XCTAssertEqual(data.uint32(position: 4), UInt32.max)
        XCTAssertEqual(data.uint64(position: 0), UInt64.max)
        XCTAssertEqual(data.getByteAt(position: 0), 255)
    }

    // MARK: - integer appending

    /// Values written with `append(_:)` must read back unchanged with `to(_:)`, because Tx
    /// messages are built with one and Rx messages parsed with the other.
    func testAppendThenToRoundTripsForSeveralWidths() {
        var data = Data()
        data.append(UInt16(0xBEEF))
        data.append(Int32(-123_456))
        data.append(UInt64(0x0102_0304_0506_0708))

        XCTAssertEqual(data.count, 14)
        XCTAssertEqual(data[0..<2].to(UInt16.self), 0xBEEF)
        XCTAssertEqual(data[2..<6].to(Int32.self), -123_456)
        XCTAssertEqual(data[6..<14].to(UInt64.self), 0x0102_0304_0506_0708)
        XCTAssertEqual(data.first, 0xEF, "the least significant byte is written first")
    }

    // MARK: - diagnostic formatting

    /// Exactly eight bytes fill one row: no padding is added and no trailing newline remains.
    func testHexDumpOfExactlyOneRowHasNoPaddingOrTrailingNewline() {
        let dump = Data(Array("ABCDEFGH".utf8)).hexDump()

        XCTAssertEqual(dump, "41 42 43 44 45 46 47 48  ABCDEFGH")
        XCTAssertFalse(dump.hasSuffix("\n"))
    }

    /// The address column advances by eight per row and is formatted as four hex digits.
    func testHexDumpAddressAdvancesPerRow() {
        let rows = Data(repeating: 0x41, count: 16).hexDump(address: 0x0FF8).components(separatedBy: "\n")

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].hasPrefix("0FF8  41 "))
        XCTAssertTrue(rows[1].hasPrefix("1000  41 "))
    }

    /// Space is printable, while DEL and bytes above ASCII are shown as dots.
    func testHexDumpShowsOnlyPrintableCharacters() {
        let dump = Data([0x20, 0x7E, 0x7F, 0x80, 0xFF, 0x41, 0x0A, 0x00]).hexDump()

        // Hex column, one separating space, then the character column starting with the space.
        XCTAssertEqual(dump, "20 7E 7F 80 FF 41 0A 00 " + " " + " ~...A..")
    }

    /// Bluetooth addresses use upper-case hex separated by colons, without a trailing colon.
    func testHexAddressFormatsSingleAndMultipleBytes() {
        XCTAssertEqual(Data([0x0A]).hexAddress, "0A")
        XCTAssertEqual(Data([0xC0, 0xFF, 0xEE, 0x00, 0x01, 0x02]).hexAddress, "C0:FF:EE:00:01:02")
    }
}
