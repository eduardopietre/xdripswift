//
//  Libre2DecryptionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Checks the Libre 2 key derivation and decryption: `PreLibre2.decryptFRAM` for the 344 byte FRAM
/// read by MiaoMiao, Bubble or NFC, `Libre2BLEUtilities.decryptBLE` for the 46 byte frames a Libre 2
/// sends directly over Bluetooth, and the streaming unlock payload that enables those frames.
///
/// A key derived from the wrong UID or patch info bytes still "decrypts" to random bytes, so these
/// tests pin which inputs enter the key, which FRAM blocks use which key and how a valid frame is
/// recognised, using real captures from the app (a MiaoMiao Libre 2 sensor and a directly
/// connected Libre 2) as anchors.
///
/// Not run on Linux: PreLibre2 declares an OSLog logger, which Linux does not have.
final class Libre2DecryptionTests: XCTestCase {

    // MARK: - fixtures

    /// UID and patch info of the Libre 2 sensor in the MiaoMiao sample of the app.
    private static let miaoMiaoUID: [UInt8] = [0x3F, 0x38, 0xA5, 0x00, 0x00, 0xA4, 0x07, 0xE0]
    private static let miaoMiaoPatchInfo: [UInt8] = [0x9D, 0x08, 0x30, 0x01, 0xFB, 0x30]

    /// UID of the directly connected Libre 2 in CGMLibre2Transmitter+TestData.swift and its first
    /// captured, encrypted 46 byte BLE frame (2 byte nonce, 44 byte payload).
    private static let directUID = Data([0xE3, 0xA1, 0x8E, 0x01, 0x00, 0xA4, 0x07, 0xE0])
    private static let capturedFrames = [
        "ebb86eb952942ce055278df46b68ba1eacd3c78c7e800ea3890c61116679c2a3fcc220a95571ff760207682942f0",
        "38a5b8062dcaf18c537a7cd030cfe3e0c0c896e65131fc4ac0f51b78d496d2964f8f1971e71bca45bcd8bfcc1450",
    ].map { Data(hexadecimalString: $0)! }

    /// UserDefaults keys in which the BLE parser keeps the previous frame.
    private static let historyKeys: [UserDefaults.Key] = [.previousRawGlucoseValues, .previousRawTemperatureValues, .previousTemperatureAdjustmentValues]

    private var savedHistory: [UserDefaults.Key: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.historyKeys {
            if let value = UserDefaults.standard.object(forKey: key.rawValue) { savedHistory[key] = value }
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
    }

    override func tearDown() {
        for key in Self.historyKeys {
            if let value = savedHistory[key] {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
        super.tearDown()
    }

    /// The key stream decryptFRAM applies: decrypting zeros returns it unchanged.
    private static func framKeyStream(uid: [UInt8] = miaoMiaoUID, patchInfo: [UInt8] = miaoMiaoPatchInfo) -> [UInt8] {
        PreLibre2.decryptFRAM(uid, patchInfo, [UInt8](repeating: 0, count: 344))
    }

    /// Indexes of the 8 byte blocks in which two FRAM key streams differ.
    private static func differingBlocks(_ a: [UInt8], _ b: [UInt8]) -> [Int] {
        (0..<43).filter { a[($0 * 8)..<($0 * 8 + 8)] != b[($0 * 8)..<($0 * 8 + 8)] }
    }

    /// Bitwise CRC-16/MCRF4XX, stored like the sensor does: each byte bit reversed, high byte first.
    private static func storedCrc(_ bytes: [UInt8]) -> [UInt8] {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        func reversed(_ byte: UInt8) -> UInt8 { (0..<8).reduce(0) { $0 | (((byte >> $1) & 1) << (7 - $1)) } }
        return [reversed(UInt8(crc >> 8)), reversed(UInt8(crc & 0xFF))]
    }

    /// The BLE key stream used for a captured frame's nonce: its payload XOR the decrypted payload.
    private static func bleKeyStream(of frame: Data) throws -> [UInt8] {
        let plain = try Libre2BLEUtilities.decryptBLE(sensorUID: directUID, data: frame)
        return zip(frame.dropFirst(2), plain).map { $0 ^ $1 }
    }

    /// Encrypts a 42 byte plain payload (plus its CRC) under the nonce of `frame`.
    private static func encrypt(_ payload: [UInt8], likeFrame frame: Data) throws -> Data {
        precondition(payload.count == 42)
        let plain = payload + storedCrc(payload)
        return Data(frame.prefix(2)) + Data(zip(plain, try bleKeyStream(of: frame)).map { $0 ^ $1 })
    }

    // MARK: - FRAM decryption

    func testFRAMKeyStreamDoesNotDependOnTheData() {
        // decryptFRAM is a pure XOR with a key stream, so the same function also encrypts.
        var generator = SystemRandomNumberGenerator()
        let a = (0..<344).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let b = (0..<344).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let decryptedA = PreLibre2.decryptFRAM(Self.miaoMiaoUID, Self.miaoMiaoPatchInfo, a)
        let decryptedB = PreLibre2.decryptFRAM(Self.miaoMiaoUID, Self.miaoMiaoPatchInfo, b)
        XCTAssertEqual(zip(decryptedA, decryptedB).map { $0 ^ $1 }, zip(a, b).map { $0 ^ $1 })
        XCTAssertEqual(PreLibre2.decryptFRAM(Self.miaoMiaoUID, Self.miaoMiaoPatchInfo, decryptedA), a)
    }

    func testEveryFRAMBlockHasItsOwnKey() {
        // The block index enters the key; a repeated key would leak equal plaintext blocks.
        let keyStream = Self.framKeyStream()
        XCTAssertEqual(keyStream.count, 344)
        let blocks = (0..<43).map { Array(keyStream[($0 * 8)..<($0 * 8 + 8)]) }
        XCTAssertEqual(Set(blocks.map { Data($0) }).count, 43)
    }

    func testEULibre2VariantsShareTheKeyDerivation() {
        // Only E5 and E6 (Libre US) derive the key differently; 9D, C5, C6 and 7F sensors use the
        // same derivation, so all of them can be read by MiaoMiao and Bubble.
        let reference = Self.framKeyStream()
        for firstByte: UInt8 in [0xC5, 0xC6, 0x7F, 0xDF, 0x70] {
            var patchInfo = Self.miaoMiaoPatchInfo
            patchInfo[0] = firstByte
            XCTAssertEqual(Self.framKeyStream(patchInfo: patchInfo), reference, String(format: "%02X", firstByte))
        }
        for firstByte: UInt8 in [0xE5, 0xE6] {
            var patchInfo = Self.miaoMiaoPatchInfo
            patchInfo[0] = firstByte
            XCTAssertNotEqual(Self.framKeyStream(patchInfo: patchInfo), reference, String(format: "%02X", firstByte))
        }
    }

    func testOnlyPatchInfoBytes4And5EnterTheEUKey() {
        let reference = Self.framKeyStream()
        for index in [1, 2, 3] {
            var patchInfo = Self.miaoMiaoPatchInfo
            patchInfo[index] ^= 0xFF
            XCTAssertEqual(Self.framKeyStream(patchInfo: patchInfo), reference, "patch info byte \(index)")
        }
        for index in [4, 5] {
            var patchInfo = Self.miaoMiaoPatchInfo
            patchInfo[index] ^= 0x01
            XCTAssertEqual(Self.differingBlocks(Self.framKeyStream(patchInfo: patchInfo), reference), Array(0..<43), "patch info byte \(index) changes every block")
        }
    }

    func testLibreUSHeaderAndFooterBlocksIgnoreThePatchInfo() {
        // For Libre US, blocks 0-2 (header) and 40-42 (footer) use a fixed constant instead of
        // patch info bytes 4 and 5; only the body blocks 3-39 depend on them.
        var usPatchInfo = Self.miaoMiaoPatchInfo
        usPatchInfo[0] = 0xE5
        var otherUSPatchInfo = usPatchInfo
        otherUSPatchInfo[4] ^= 0x5A
        otherUSPatchInfo[5] ^= 0xA5
        XCTAssertEqual(Self.differingBlocks(Self.framKeyStream(patchInfo: usPatchInfo), Self.framKeyStream(patchInfo: otherUSPatchInfo)), Array(3..<40))
    }

    func testOnlySerialBytesOfTheUIDEnterTheKey() {
        // UID bytes 6 and 7 are the chip manufacturer code, the same for every sensor.
        let reference = Self.framKeyStream()
        var otherManufacturer = Self.miaoMiaoUID
        otherManufacturer[6] = 0x00
        otherManufacturer[7] = 0x00
        XCTAssertEqual(Self.framKeyStream(uid: otherManufacturer), reference)

        for index in 0..<6 {
            var otherSensor = Self.miaoMiaoUID
            otherSensor[index] ^= 0x01
            XCTAssertNotEqual(Self.framKeyStream(uid: otherSensor), reference, "UID byte \(index)")
        }
    }

    // MARK: - BLE decryption

    func testAnyPayloadWithValidCrcRoundTripsUnderTheSameNonce() throws {
        // The key stream depends on the sensor UID and the 2 byte nonce only, so a payload
        // encrypted with the stream of a captured frame decrypts to exactly that payload.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let payload = (0..<42).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let frame = try Self.encrypt(payload, likeFrame: Self.capturedFrames[0])
            XCTAssertEqual(frame.count, 46)
            let decrypted = try Libre2BLEUtilities.decryptBLE(sensorUID: Self.directUID, data: frame)
            XCTAssertEqual(Array(decrypted.prefix(42)), payload)
        }
    }

    func testKeyStreamDependsOnTheNonce() throws {
        // A payload encrypted for one nonce but sent with another fails the CRC check.
        let payload = [UInt8](repeating: 0x42, count: 42)
        let frame = try Self.encrypt(payload, likeFrame: Self.capturedFrames[0])
        XCTAssertNotEqual(try Self.bleKeyStream(of: Self.capturedFrames[0]), try Self.bleKeyStream(of: Self.capturedFrames[1]))

        let otherNonce = Data(Self.capturedFrames[1].prefix(2)) + frame.dropFirst(2)
        XCTAssertThrowsError(try Libre2BLEUtilities.decryptBLE(sensorUID: Self.directUID, data: otherNonce))
    }

    func testEncryptedFrameDecodesToTheReadingsItWasBuiltFrom() throws {
        // Full path of a Libre 2 Bluetooth frame: seven 4 byte readings (raw glucose 14 bits,
        // raw temperature 12 bits) for minutes 0, 2, 4, 6, 7, 12 and 15 ago, then the wear time.
        let raw = [1000, 980, 960, 940, 930, 880, 850]
        var payload = Data(count: 42)
        for (index, value) in raw.enumerated() {
            payload = LibreCalibrationInfo.writeBits(payload, index * 4, 0, 14, value)
            payload = LibreCalibrationInfo.writeBits(payload, index * 4, 14, 12, 1500)
        }
        payload[40] = 0x10                                  // wear time 0x0E10 = 3600 minutes
        payload[41] = 0x0E
        let frame = try Self.encrypt(Array(payload), likeFrame: Self.capturedFrames[1])

        let decrypted = Data(try Libre2BLEUtilities.decryptBLE(sensorUID: Self.directUID, data: frame))
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = Libre2BLEUtilities.parseBLEData(decrypted, libre1DerivedAlgorithmParameters: nil, newestReadingDate: newest)

        XCTAssertEqual(parsed.sensorTimeInMinutes, 3600)
        let byMinute = Dictionary(uniqueKeysWithValues: parsed.bleGlucose.map { (Int(newest.timeIntervalSince($0.timeStamp) / 60), $0.glucoseLevelRaw) })
        for (minute, value) in zip([0, 2, 4, 6, 7, 12, 15], raw) {
            XCTAssertEqual(byMinute[minute] ?? 0, Double(value) * ConstantsBloodGlucose.libreMultiplier, accuracy: 1e-6, "minute \(minute)")
        }
        // single missing minutes between two readings are interpolated, longer gaps are not
        XCTAssertEqual(byMinute[1] ?? 0, 990 * ConstantsBloodGlucose.libreMultiplier, accuracy: 1e-6)
        XCTAssertNil(byMinute[9])
    }

    // MARK: - streaming unlock

    /// Regression: `decryptBLE` had no length check. A frame shorter than 46 bytes crashed reading
    /// the CRC, and a longer one crashed reading past the end of the 64 byte key. The frame
    /// assembler always passes 46 bytes, but a truncated or merged BLE frame must be rejected.
    func testFramesOfAnyOtherLengthAreRejectedInsteadOfCrashing() {
        let frame = Self.capturedFrames[0]
        XCTAssertEqual(frame.count, 46)
        for length in [0, 1, 2, 3, 10, 44, 45, 47, 66, 67, 100] {
            let other = Data((frame + Data(repeating: 0x5A, count: 60)).prefix(length))
            XCTAssertThrowsError(try Libre2BLEUtilities.decryptBLE(sensorUID: Self.directUID, data: other), "length \(length)")
        }
    }

    /// Regression: the nonce was read as `data[0]` and `data[1]`, which are not the first bytes of a
    /// slice of a larger buffer. A slice must decrypt like a copy.
    func testSliceOfALargerBufferDecryptsLikeACopy() throws {
        let frame = Self.capturedFrames[0]
        let slice = (Data([0x01, 0x02, 0x03]) + frame).dropFirst(3)
        XCTAssertEqual(slice.startIndex, 3)

        XCTAssertEqual(try Libre2BLEUtilities.decryptBLE(sensorUID: Self.directUID, data: slice),
                       try Libre2BLEUtilities.decryptBLE(sensorUID: Self.directUID, data: frame))
    }

    /// Regression (found by Libre2DecryptionFuzzTests): a sensor UID shorter than 6 bytes crashed
    /// the key derivation. It is rejected like a frame with a bad CRC.
    func testShortSensorUIDIsRejectedInsteadOfCrashing() {
        for length in 0..<6 {
            XCTAssertThrowsError(try Libre2BLEUtilities.decryptBLE(sensorUID: Data(Self.directUID.prefix(length)), data: Self.capturedFrames[0]), "length \(length)")
        }
    }

    /// Regression (found by Libre2DecryptionFuzzTests): patch info shorter than 6 bytes, which a
    /// transmitter box can send as text, crashed the FRAM decryption. The data is now returned
    /// unchanged, so the CRC check that follows rejects it.
    func testShortPatchInfoOrUIDLeavesTheFRAMUnchanged() {
        let fram = (0..<344).map { UInt8($0 & 0xFF) }
        XCTAssertEqual(PreLibre2.decryptFRAM(Self.miaoMiaoUID, Array(Self.miaoMiaoPatchInfo.prefix(5)), fram), fram)
        XCTAssertEqual(PreLibre2.decryptFRAM(Array(Self.miaoMiaoUID.prefix(5)), Self.miaoMiaoPatchInfo, fram), fram)
        XCTAssertEqual(PreLibre2.decryptFRAM(Self.miaoMiaoUID, Self.miaoMiaoPatchInfo, Array(fram.prefix(100))), Array(fram.prefix(100)))
        XCTAssertNotEqual(PreLibre2.decryptFRAM(Self.miaoMiaoUID, Self.miaoMiaoPatchInfo, fram), fram)
    }

    func testUnlockPayloadUsesOnlyPatchInfoBytes4And5() {
        let info = Data(Self.miaoMiaoPatchInfo)
        let reference = Libre2BLEUtilities.streamingUnlockPayload(sensorUID: Self.directUID, info: info, enableTime: 1_000, unlockCount: 3)
        for index in 0..<4 {
            var other = info
            other[index] ^= 0xFF
            XCTAssertEqual(Libre2BLEUtilities.streamingUnlockPayload(sensorUID: Self.directUID, info: other, enableTime: 1_000, unlockCount: 3), reference, "patch info byte \(index)")
        }
        for index in [4, 5] {
            var other = info
            other[index] ^= 0x01
            let payload = Libre2BLEUtilities.streamingUnlockPayload(sensorUID: Self.directUID, info: other, enableTime: 1_000, unlockCount: 3)
            XCTAssertEqual(Array(payload.prefix(4)), Array(reference.prefix(4)), "the time prefix does not change")
            XCTAssertNotEqual(Array(payload.suffix(8)), Array(reference.suffix(8)), "patch info byte \(index)")
        }
    }

    func testUnlockAuthenticatorDependsOnSensorAndEnableTime() {
        let info = Data(Self.miaoMiaoPatchInfo)
        let reference = Libre2BLEUtilities.streamingUnlockPayload(sensorUID: Self.directUID, info: info, enableTime: 1_000, unlockCount: 4)

        // another sensor: same time prefix, different 8 byte authenticator
        let otherSensor = Libre2BLEUtilities.streamingUnlockPayload(sensorUID: Data(Self.miaoMiaoUID), info: info, enableTime: 1_000, unlockCount: 4)
        XCTAssertEqual(Array(otherSensor.prefix(4)), Array(reference.prefix(4)))
        XCTAssertNotEqual(Array(otherSensor.suffix(8)), Array(reference.suffix(8)))

        // the same enableTime + unlockCount sum from another enable time is a different payload:
        // the sensor checks the time it was enabled at, not only the counter
        let sameSum = Libre2BLEUtilities.streamingUnlockPayload(sensorUID: Self.directUID, info: info, enableTime: 1_003, unlockCount: 1)
        XCTAssertEqual(Array(sameSum.prefix(4)), Array(reference.prefix(4)))
        XCTAssertNotEqual(Array(sameSum.suffix(8)), Array(reference.suffix(8)))
    }

}
