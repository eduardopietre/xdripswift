//
//  LibreFRAMCrcTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Checks the CRC16 validation that `Crc.LibreCrc` runs on every 344 byte Libre FRAM image read by
/// MiaoMiao and Bubble before it is parsed into glucose values.
///
/// The FRAM has three sections (header 0..<24, body 24..<320, footer 320..<344), each starting with
/// the CRC of the rest of the section. A wrong section boundary, byte order or header offset would
/// either reject every reading of a working sensor or let corrupted Bluetooth data through as
/// glucose values. The expected CRCs come from an independent bitwise CRC-16/MCRF4XX
/// implementation (checked against the published check value and a real sensor header), not from
/// the table driven code under test.
final class LibreFRAMCrcTests: XCTestCase {

    // MARK: - fixtures

    /// Decrypted header section of a real Libre 2 sensor (from the MiaoMiao sample in the app); its
    /// first two bytes are the CRC stored by the sensor.
    private static let realSensorHeader: [UInt8] = [
        0x52, 0xE1, 0xD0, 0x18, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    /// Section boundaries of the Libre 1 layout (also used for decrypted Libre 2 and Libre US).
    private static let libre1Sections = [0..<24, 24..<320, 320..<344]

    /// Section boundaries of the Libre Pro H layout.
    private static let proHSections = [0..<40, 40..<72, 72..<176]

    /// Bitwise CRC-16/MCRF4XX: reflected polynomial 0x8408, initial value 0xFFFF, no final xor.
    private static func mcrf4xx(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return crc
    }

    /// Reverses the bit order of one byte.
    private static func reversedBits(_ byte: UInt8) -> UInt8 {
        var result: UInt8 = 0
        for bit in 0..<8 where byte & (1 << bit) != 0 {
            result |= 1 << (7 - bit)
        }
        return result
    }

    /// Writes the CRC of `range` (minus its first two bytes) into those two bytes, the way the
    /// sensor stores it: each CRC byte bit reversed, the high byte first.
    private static func stamp(_ bytes: inout [UInt8], _ range: Range<Int>) {
        let crc = mcrf4xx(Array(bytes[(range.lowerBound + 2)..<range.upperBound]))
        bytes[range.lowerBound] = reversedBits(UInt8(crc >> 8))
        bytes[range.lowerBound + 1] = reversedBits(UInt8(crc & 0xFF))
    }

    /// A FRAM image with pseudo random content and three valid section CRCs.
    private static func validFRAM(seed: UInt64 = 1, sections: [Range<Int>] = libre1Sections) -> [UInt8] {
        var generator = SplitMix64(seed: seed)
        var bytes = (0..<344).map { _ in UInt8.random(in: 0...255, using: &generator) }
        sections.forEach { stamp(&bytes, $0) }
        return bytes
    }

    private static func isValid(_ bytes: [UInt8], headerOffset: Int = 0, type: LibreSensorType? = .libre1) -> Bool {
        var data = Data(bytes)
        return Crc.LibreCrc(data: &data, headerOffset: headerOffset, libreSensorType: type)
    }

    // MARK: - tests

    func testReferenceCrcMatchesPublishedCheckValueAndRealSensorHeader() {
        // The test oracle itself must be right before it can judge the app.
        XCTAssertEqual(Self.mcrf4xx(Array("123456789".utf8)), 0x6F91)

        var header = Self.realSensorHeader
        Self.stamp(&header, 0..<24)
        XCTAssertEqual(header, Self.realSensorHeader, "the oracle reproduces the CRC the sensor stored")

        // A FRAM with the real header and stamped body and footer is accepted by the app.
        var fram = Self.validFRAM()
        fram.replaceSubrange(0..<24, with: Self.realSensorHeader)
        XCTAssertTrue(Self.isValid(fram))
    }

    func testEverySingleBitFlipInTheFRAMIsDetected() {
        let fram = Self.validFRAM(seed: 7)
        XCTAssertTrue(Self.isValid(fram))

        // Exhaustive: a flipped bit anywhere, including the stored CRCs and the first and last
        // byte of each section, must be caught. A section boundary off by one would miss some.
        var undetected = [Int]()
        for bitIndex in 0..<(344 * 8) {
            var corrupted = fram
            corrupted[bitIndex / 8] ^= 1 << (bitIndex % 8)
            if Self.isValid(corrupted) { undetected.append(bitIndex) }
        }
        XCTAssertEqual(undetected, [], "bit flips that passed the CRC check")
    }

    func testBurstErrorsOfUpTo16BitsAreDetected() {
        // CRC16 detects every burst error that is at most 16 bits long. Bluetooth corruption
        // typically hits a few consecutive bits.
        let fram = Self.validFRAM(seed: 11)
        var generator = SplitMix64(seed: 99)
        for length in 2...16 {
            for _ in 0..<40 {
                let start = Int.random(in: 0...(344 * 8 - length), using: &generator)
                // first and last bit of the burst are always flipped, the ones between at random
                var corrupted = fram
                for offset in 0..<length {
                    let flip = offset == 0 || offset == length - 1 || Bool.random(using: &generator)
                    if flip {
                        let bitIndex = start + offset
                        corrupted[bitIndex / 8] ^= 1 << (bitIndex % 8)
                    }
                }
                XCTAssertFalse(Self.isValid(corrupted), "burst of \(length) bits at bit \(start)")
            }
        }
    }

    func testSwappedTrendRecordsAreDetected() {
        // The trend ring buffer holds 6 byte records from byte 28. Records delivered in the wrong
        // order would assign glucose values to the wrong minutes.
        var fram = Self.validFRAM(seed: 3)
        fram[28] = 0x10
        fram[34] = 0x20
        Self.stamp(&fram, 24..<320)
        XCTAssertTrue(Self.isValid(fram))

        var swapped = fram
        swapped.replaceSubrange(28..<34, with: fram[34..<40])
        swapped.replaceSubrange(34..<40, with: fram[28..<34])
        XCTAssertNotEqual(swapped, fram)
        XCTAssertFalse(Self.isValid(swapped))
    }

    func testEachSectionNeedsItsOwnValidCrc() {
        let fram = Self.validFRAM(seed: 5)
        XCTAssertTrue(Self.isValid(fram))

        for (index, section) in Self.libre1Sections.enumerated() {
            var broken = fram
            // change the content but keep the old CRC: only this section is now inconsistent
            broken[section.upperBound - 1] &+= 1
            XCTAssertFalse(Self.isValid(broken), "section \(index) with a stale CRC")

            // re-stamping the section repairs the image
            Self.stamp(&broken, section)
            XCTAssertTrue(Self.isValid(broken), "section \(index) after re-stamping")
        }
    }

    func testCrcStoredInTheWrongByteOrderIsRejected() {
        var fram = Self.validFRAM(seed: 13)
        // pick content whose stored body CRC has two different bytes
        var seed: UInt64 = 13
        while fram[24] == fram[25] {
            seed += 1
            fram = Self.validFRAM(seed: seed)
        }
        fram.swapAt(24, 25)
        XCTAssertFalse(Self.isValid(fram))
    }

    func testBlankFRAMIsRejected() {
        // A transmitter that reads nothing delivers zeros or 0xFF; that must never be parsed.
        XCTAssertFalse(Self.isValid([UInt8](repeating: 0x00, count: 344)))
        XCTAssertFalse(Self.isValid([UInt8](repeating: 0xFF, count: 344)))
    }

    func testMiaoMiaoPacketValidatesOnlyTheEmbeddedFRAM() {
        // MiaoMiao packet: 0x28, length (2), unused (2), sensor UID (8), battery, firmware (2),
        // hardware (2), then the FRAM, then 0x29 and 6 bytes of patch info.
        let fram = Self.validFRAM(seed: 17)
        let header: [UInt8] = [0x28, 0x01, 0x6B, 0x00, 0x00] + [0x3F, 0x38, 0xA5, 0x00, 0x00, 0xA4, 0x07, 0xE0] + [0x64, 0x00, 0x39, 0x00, 0x01]
        XCTAssertEqual(header.count, 18)
        let trailer: [UInt8] = [0x29, 0x9D, 0x08, 0x30, 0x01, 0xFB, 0x30]
        let packet = header + fram + trailer

        XCTAssertTrue(Self.isValid(packet, headerOffset: 18))

        // whatever the header and trailer contain does not matter
        var otherEnvelope = packet
        for index in Array(0..<18) + Array(362..<packet.count) {
            otherEnvelope[index] ^= 0xA5
        }
        XCTAssertTrue(Self.isValid(otherEnvelope, headerOffset: 18))

        // but the FRAM must be found at the right offset
        XCTAssertFalse(Self.isValid(packet, headerOffset: 0))
        XCTAssertFalse(Self.isValid(packet, headerOffset: 17))
        XCTAssertFalse(Self.isValid(packet, headerOffset: 19))
    }

    func testBubbleHeaderOfEightBytesIsSkipped() {
        // Bubble keeps the 8 byte sensor UID in front of the FRAM.
        let fram = Self.validFRAM(seed: 19)
        let packet: [UInt8] = [0xE3, 0xA1, 0x8E, 0x01, 0x00, 0xA4, 0x07, 0xE0] + fram
        XCTAssertTrue(Self.isValid(packet, headerOffset: 8, type: .libre2))
        XCTAssertFalse(Self.isValid(packet, headerOffset: 0, type: .libre2))
    }

    /// Regression: the length check required 344 bytes whatever the header offset, so a packet with
    /// an 18 byte header and 344 to 361 bytes in total passed the check and then crashed reading
    /// past its end. A truncated packet must be rejected instead.
    func testTruncatedPacketWithAHeaderIsRejectedInsteadOfCrashing() {
        let packet = [UInt8](repeating: 0, count: 18) + Self.validFRAM(seed: 23)
        for length in 344..<packet.count {
            XCTAssertFalse(Self.isValid(Array(packet.prefix(length)), headerOffset: 18), "length \(length)")
        }
        XCTAssertTrue(Self.isValid(packet, headerOffset: 18))
    }

    /// Regression: `subdata(in:)` takes indices of the `Data` itself, so a slice of a larger buffer
    /// was checked at the wrong bytes (or crashed). A slice must validate like a copy.
    func testSliceOfALargerBufferIsValidatedLikeACopy() {
        let fram = Self.validFRAM(seed: 29)
        var slice = (Data([0xAA, 0xBB, 0xCC]) + Data(fram)).dropFirst(3)
        XCTAssertEqual(slice.startIndex, 3)

        XCTAssertTrue(Crc.LibreCrc(data: &slice, headerOffset: 0, libreSensorType: .libre1))
    }

    func testNegativeHeaderOffsetIsRejected() {
        XCTAssertFalse(Self.isValid(Self.validFRAM(seed: 31), headerOffset: -1))
    }

    func testUnknownSensorTypeUsesTheLibre1Sections() {
        // Older MiaoMiao and Bubble firmware does not report patch info, so the type is nil.
        let libre1Stamped = Self.validFRAM(seed: 23)
        let proHStamped = Self.validFRAM(seed: 23, sections: Self.proHSections)

        for type: LibreSensorType? in [nil, .libre1, .libre2, .libreUS] {
            XCTAssertTrue(Self.isValid(libre1Stamped, type: type), String(describing: type))
            XCTAssertFalse(Self.isValid(proHStamped, type: type), String(describing: type))
        }
        XCTAssertTrue(Self.isValid(proHStamped, type: .libreProH))
    }

}

/// Small deterministic random number generator, so failures can be reproduced.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
