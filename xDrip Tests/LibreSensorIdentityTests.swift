//
//  LibreSensorIdentityTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Checks how a Libre sensor is identified from what it sends: the serial number derived from the
/// 8 byte NFC UID and the sensor type derived from the patch info.
///
/// The serial number is what the user sees on the sensor box and what the Libre 2 transmitter
/// matches against the advertised Bluetooth name, so a wrong bit in the 5 bit packing makes xDrip
/// connect to no sensor (or the wrong one). The sensor type decides whether the FRAM is decrypted
/// and which layout is parsed. The expectations are built with an independent encoder of the
/// documented layout, not with the decoder under test.
final class LibreSensorIdentityTests: XCTestCase {

    // MARK: - fixtures

    /// The 32 characters of the serial number alphabet (0-9 and A-Z without B, I, O and S).
    private static let alphabet = Array("0123456789ACDEFGHJKLMNPQRTUVWXYZ")

    /// Builds a UID for the 10 serial characters after the family prefix, following the documented
    /// layout: the 48 bits of UID bytes 5...0 (most significant first), padded with two zero bits,
    /// split in ten groups of 5 bits. UID bytes 6 and 7 are the manufacturer code (07 E0).
    private static func uid(forSerialCharacters characters: [Character], manufacturer: (UInt8, UInt8) = (0x07, 0xE0)) -> Data {
        precondition(characters.count == 10)
        var value: UInt64 = 0
        for character in characters {
            value = value << 5 | UInt64(alphabet.firstIndex(of: character)!)
        }
        precondition(value & 0b11 == 0, "the last character only carries 3 bits")
        let fortyEightBits = value >> 2
        var uid = [UInt8](repeating: 0, count: 8)
        for byteIndex in 0..<6 {
            uid[byteIndex] = UInt8((fortyEightBits >> (8 * UInt64(byteIndex))) & 0xFF)
        }
        uid[6] = manufacturer.0
        uid[7] = manufacturer.1
        return Data(uid)
    }

    /// UID whose 48 serial bits are all zero except bit `bit` (0 = least significant, in UID byte 0).
    private static func uid(withSingleBit bit: Int) -> Data {
        var uid = [UInt8](repeating: 0, count: 8)
        uid[bit / 8] = 1 << (bit % 8)
        uid[6] = 0x07
        uid[7] = 0xE0
        return Data(uid)
    }

    private static func serial(_ uid: Data, _ type: LibreSensorType? = .libre1) -> String {
        LibreSensorSerialNumber(withUID: uid, with: type)!.serialNumber
    }

    // MARK: - serial number

    func testEncoderReproducesTheDocumentedExample() {
        // The example in LibreSensorSerialNumber: UID 5E 90 25 00 00 A0 07 E0 is "0M00009DHCR".
        XCTAssertEqual(Self.uid(forSerialCharacters: Array("M00009DHCR")), Data([0x5E, 0x90, 0x25, 0x00, 0x00, 0xA0, 0x07, 0xE0]))
    }

    func testEachUIDBitLandsInExactlyOneSerialCharacter() {
        // Exhaustive over the 48 serial bits: every shift and cross-byte combination in the
        // decoder is exercised once.
        for bit in 0..<48 {
            let serial = Array(Self.serial(Self.uid(withSingleBit: bit)))
            XCTAssertEqual(serial.count, 11, "bit \(bit)")

            // bit b of the 48 bit number is bit b + 2 of the padded 50 bit number
            let paddedBit = bit + 2
            let characterIndex = 1 + (9 - paddedBit / 5)
            let expectedCharacter = Self.alphabet[1 << (paddedBit % 5)]

            for (index, character) in serial.enumerated() {
                let expected: Character = index == characterIndex ? expectedCharacter : "0"
                XCTAssertEqual(character, expected, "bit \(bit), character \(index) of \(String(serial))")
            }
        }
    }

    func testRandomSerialNumbersRoundTripThroughTheUID() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var characters = (0..<9).map { _ in Self.alphabet.randomElement(using: &generator)! }
            // the last character only carries 3 bits, its two lowest bits are always zero
            characters.append(Self.alphabet[4 * Int.random(in: 0..<8, using: &generator)])

            let uid = Self.uid(forSerialCharacters: characters)
            XCTAssertEqual(Self.serial(uid, .libre2), "3" + String(characters), uid.hexEncodedString())
            XCTAssertEqual(Self.serial(uid, .libreProH), "1" + String(characters), uid.hexEncodedString())
        }
    }

    func testLastCharacterIsOneOfEightValues() {
        // Only the three lowest bits of UID byte 0 reach the last character, so it can only be
        // 0, 4, 8, D, H, M, R or W; the upper five bits of that byte form the character before.
        for byte in 0...255 {
            let uid = Data([UInt8(byte), 0, 0, 0, 0, 0, 0x07, 0xE0])
            let serial = Array(Self.serial(uid))
            XCTAssertEqual(serial[10], Self.alphabet[(byte & 0b111) << 2], "byte \(byte)")
            XCTAssertEqual(serial[9], Self.alphabet[byte >> 3], "byte \(byte)")
        }
        XCTAssertEqual(Set((0...255).map { Self.serial(Data([UInt8($0), 0, 0, 0, 0, 0, 0x07, 0xE0])).last! }), Set("048DHMRW"))
    }

    func testManufacturerBytesDoNotChangeTheSerialNumber() {
        // UID bytes 6 and 7 identify the NFC chip maker (E0 07 = Texas Instruments), not the sensor.
        let characters = Array("MH00199R7W")
        let reference = Self.serial(Self.uid(forSerialCharacters: characters), .libre2)
        XCTAssertEqual(reference, "3MH00199R7W")
        for manufacturer: (UInt8, UInt8) in [(0x00, 0x00), (0xFF, 0xFF), (0x07, 0x00), (0x12, 0xE0)] {
            XCTAssertEqual(Self.serial(Self.uid(forSerialCharacters: characters, manufacturer: manufacturer), .libre2), reference)
        }
    }

    // MARK: - sensor type from patch info

    func testOnlyNineFirstBytesIdentifyASensorType() {
        // Exhaustive over the first patch info byte: an unknown sensor must give nil (no parsing)
        // rather than be treated as some known type.
        var known = [UInt8: LibreSensorType]()
        for byte in 0...255 {
            let patchInfo = String(format: "%02X0830010000", byte)
            if let type = LibreSensorType.type(patchInfo: patchInfo) {
                known[UInt8(byte)] = type
            }
        }
        XCTAssertEqual(known, [
            0xDF: .libre1, 0xA2: .libre1A2, 0x9D: .libre2, 0xC5: .libre2C5, 0xC6: .libre2C6,
            0x7F: .libre27FNonPlus, 0xE5: .libreUS, 0xE6: .libreUSE6, 0x70: .libreProH,
        ])
        // for every type but the 7F family the raw value is the first patch info byte
        for (byte, type) in known where byte != 0x7F {
            XCTAssertEqual(type.rawValue, String(format: "%02X", byte))
        }
    }

    func test7FPlusFlagIsOnlyTheLowNibbleOfTheThirdByte() {
        // Exhaustive over the third byte of a 7F sensor: 7F 0E 30 01 is Libre 2, 7F 0E 31 01 is
        // Libre 2 Plus. The Plus sensor lasts a day longer, so mixing them up changes the expiry.
        for byte in 0...255 {
            let patchInfo = String(format: "7F0E%02X01", byte)
            let expected: LibreSensorType = byte & 0x0F == 0 ? .libre27FNonPlus : .libre27F
            XCTAssertEqual(LibreSensorType.type(patchInfo: patchInfo), expected, patchInfo)
        }
        // the second byte is not part of the decision
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7FFF3001"), .libre27FNonPlus)
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7F003101"), .libre27F)
    }

}
