//
//  LibreCoverageSensorTypeTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class LibreCoverageSensorTypeTests: XCTestCase {
    private let allTypes: [LibreSensorType] = [.libre1, .libre1A2, .libre2, .libre2C5, .libre2C6, .libre27F, .libre27FNonPlus, .libreUS, .libreUSE6, .libreProH]

    // MARK: - LibreSensorType.type(patchInfo:)

    func testMissingPatchInfoDefaultsToLibre1() {
        XCTAssertEqual(LibreSensorType.type(patchInfo: nil), .libre1)
    }

    func testPatchInfoFirstByteSelectsSensorType() {
        let expectations: [(String, LibreSensorType)] = [
            ("DF0000080000", .libre1), ("A20800000000", .libre1A2), ("9D083001FB30", .libre2),
            ("C50900000000", .libre2C5), ("C60931000000", .libre2C6), ("E50003000000", .libreUS),
            ("E60003000000", .libreUSE6), ("700000000000", .libreProH),
        ]
        for (patchInfo, type) in expectations {
            XCTAssertEqual(LibreSensorType.type(patchInfo: patchInfo), type, patchInfo)
        }
    }

    func testPatchInfoIsCaseInsensitive() {
        XCTAssertEqual(LibreSensorType.type(patchInfo: "9d083001fb30"), .libre2)
        XCTAssertEqual(LibreSensorType.type(patchInfo: "df"), .libre1)
    }

    func test7FSensorsAreDistinguishedByLowNibbleOfThirdByte() {
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7F0E3001"), .libre27FNonPlus)
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7F0E3101"), .libre27F)
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7F0E4001"), .libre27FNonPlus)
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7F0E3F01"), .libre27F)
    }

    func testIncomplete7FPatchInfoKeepsPlusClassification() {
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7F"), .libre27F)
        XCTAssertEqual(LibreSensorType.type(patchInfo: "7F0E"), .libre27F)
    }

    func testUnknownOrMalformedPatchInfoReturnsNil() {
        XCTAssertNil(LibreSensorType.type(patchInfo: "AB0000"))
        XCTAssertNil(LibreSensorType.type(patchInfo: "00"))
        XCTAssertNil(LibreSensorType.type(patchInfo: ""))
        XCTAssertNil(LibreSensorType.type(patchInfo: "ZZ"))
        XCTAssertNil(LibreSensorType.type(patchInfo: "9D0"))
    }

    // MARK: - LibreSensorType properties

    func testRawValuesMatchPatchInfoPrefixes() {
        XCTAssertEqual(allTypes.map(\.rawValue), ["DF", "A2", "9D", "C5", "C6", "7F", "7F30", "E5", "E6", "70"])
        XCTAssertEqual(LibreSensorType(rawValue: "C6"), .libre2C6)
        XCTAssertNil(LibreSensorType(rawValue: "XX"))
    }

    func testDescriptionsAreUniqueAndHumanReadable() {
        XCTAssertEqual(allTypes.map(\.description), [
            "Libre 1", "Libre 1 A2", "Libre 2 EU", "Libre 2 EU C5", "Libre 2 Plus EU C6", "Libre 2 Plus EU 7F",
            "Libre 2 EU 7F", "Libre US", "Libre US E6", "Libre PRO H",
        ])
        XCTAssertEqual(Set(allTypes.map(\.description)).count, allTypes.count)
    }

    func testOnlyLibre2AndUSFamiliesRequireDecryption() {
        let encrypted = allTypes.filter(\.requiresLibre2Decryption)
        XCTAssertEqual(encrypted, [.libre2, .libre2C5, .libre2C6, .libre27F, .libre27FNonPlus, .libreUS, .libreUSE6])
    }

    func testOnly7FSensorsUseMacAddressAsBluetoothName() {
        XCTAssertEqual(allTypes.filter(\.usesMacAddressAsBluetoothName), [.libre27F, .libre27FNonPlus])
    }

    func testMaxSensorAgeDependsOnFamily() {
        XCTAssertEqual(LibreSensorType.libre1.maxSensorAgeInDays(), 14.5)
        XCTAssertEqual(LibreSensorType.libre1A2.maxSensorAgeInDays(), 14.5)
        XCTAssertEqual(LibreSensorType.libre2.maxSensorAgeInDays(), 14.5)
        XCTAssertEqual(LibreSensorType.libre2C5.maxSensorAgeInDays(), 14.5)
        XCTAssertEqual(LibreSensorType.libre27FNonPlus.maxSensorAgeInDays(), 14.5)
        XCTAssertEqual(LibreSensorType.libre2C6.maxSensorAgeInDays(), 15.5)
        XCTAssertEqual(LibreSensorType.libre27F.maxSensorAgeInDays(), 15.5)
        XCTAssertNil(LibreSensorType.libreUS.maxSensorAgeInDays())
        XCTAssertNil(LibreSensorType.libreUSE6.maxSensorAgeInDays())
        XCTAssertEqual(LibreSensorType.libreProH.maxSensorAgeInDays(), 14)
    }

    // MARK: - decryptIfPossibleAndNeeded

    func testLibre1IsNeverDecrypted() {
        var buffer = LibreCoverageFRAM().data()
        let original = buffer
        XCTAssertFalse(LibreSensorType.libre1.decryptIfPossibleAndNeeded(rxBuffer: &buffer, headerLength: 0, log: nil, patchInfo: "DF", uid: [UInt8](repeating: 0, count: 8)))
        XCTAssertEqual(buffer, original)
    }

    func testDecryptionRejectsBufferShorterThanHeaderPlusFRAM() {
        var buffer = Data(repeating: 1, count: 18 + 343)
        XCTAssertFalse(LibreSensorType.libre2.decryptIfPossibleAndNeeded(rxBuffer: &buffer, headerLength: 18, log: nil, patchInfo: LibreCoverageSamples.miaoMiaoPatchInfo, uid: [UInt8](repeating: 0, count: 8)))
        XCTAssertEqual(buffer, Data(repeating: 1, count: 361))
    }

    func testDecryptionNeedsPatchInfo() {
        var buffer = LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoEncryptedFRAM)
        let original = buffer
        let uid = Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID))
        XCTAssertFalse(LibreSensorType.libre2.decryptIfPossibleAndNeeded(rxBuffer: &buffer, headerLength: 0, log: nil, patchInfo: nil, uid: uid))
        XCTAssertFalse(LibreSensorType.libre2.decryptIfPossibleAndNeeded(rxBuffer: &buffer, headerLength: 0, log: nil, patchInfo: "", uid: uid))
        XCTAssertEqual(buffer, original)
    }

    func testLibre2DecryptionReplacesOnlyTheFRAMAfterTheHeader() {
        let header = Data([0x28, 1, 2, 3, 4] + Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID)) + [5, 6, 7, 8, 9])
        let trailer = Data([0x20, 0xAA])
        let encrypted = LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoEncryptedFRAM)
        var buffer = header + encrypted + trailer
        let uid = Array(buffer[5..<13])

        XCTAssertTrue(LibreSensorType.libre2.decryptIfPossibleAndNeeded(rxBuffer: &buffer, headerLength: 18, log: nil, patchInfo: LibreCoverageSamples.miaoMiaoPatchInfo, uid: uid))

        let expected = PreLibre2.decryptFRAM(uid, Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo)), Array(encrypted))
        XCTAssertEqual(buffer.count, 18 + 344 + 2)
        XCTAssertEqual(buffer.prefix(18), header)
        XCTAssertEqual(Array(buffer[18..<362]), expected)
        XCTAssertEqual(buffer.suffix(2), trailer)
        XCTAssertTrue(LibreSensorType.libre2.crcIsOk(rxBuffer: &buffer, headerLength: 18, log: nil))
    }

    // MARK: - CRC

    func testCrcIsOkAcceptsConsistentFRAM() {
        var buffer = LibreCoverageFRAM().data()
        XCTAssertTrue(LibreSensorType.libre1.crcIsOk(rxBuffer: &buffer, headerLength: 0, log: nil))
        XCTAssertTrue(Crc.LibreCrc(data: &buffer, headerOffset: 0, libreSensorType: nil))
    }

    func testCrcDetectsCorruptionInEachOfTheThreeSections() {
        for index in [5, 100, 330] {
            var buffer = LibreCoverageFRAM().data()
            buffer[index] ^= 0x01
            XCTAssertFalse(LibreSensorType.libre1.crcIsOk(rxBuffer: &buffer, headerLength: 0, log: nil), "byte \(index)")
        }
    }

    func testCrcDetectsCorruptedStoredChecksum() {
        var buffer = LibreCoverageFRAM().data()
        buffer[0] ^= 0xFF
        XCTAssertFalse(Crc.LibreCrc(data: &buffer, headerOffset: 0, libreSensorType: .libre1))
    }

    func testCrcRejectsDataShorterThanOneFRAM() {
        var buffer = Data(LibreCoverageFRAM().bytes().prefix(343))
        XCTAssertFalse(Crc.LibreCrc(data: &buffer, headerOffset: 0, libreSensorType: .libre1))
    }

    func testCrcHonoursHeaderOffset() {
        var buffer = Data(repeating: 0xEE, count: 8) + LibreCoverageFRAM().data()
        XCTAssertTrue(Crc.LibreCrc(data: &buffer, headerOffset: 8, libreSensorType: .libre2))
        XCTAssertFalse(Crc.LibreCrc(data: &buffer, headerOffset: 0, libreSensorType: .libre2))
    }

    func testCrcUsesProHSectionBoundaries() {
        var bytes = [UInt8](repeating: 0x5A, count: 344)
        LibreCoverageBytes.applyCRC(&bytes, range: 0..<40)
        LibreCoverageBytes.applyCRC(&bytes, range: 40..<72)
        LibreCoverageBytes.applyCRC(&bytes, range: 72..<176)
        var buffer = Data(bytes)
        XCTAssertTrue(LibreSensorType.libreProH.crcIsOk(rxBuffer: &buffer, headerLength: 0, log: nil))
        XCTAssertFalse(LibreSensorType.libre1.crcIsOk(rxBuffer: &buffer, headerLength: 0, log: nil))
        buffer[200] ^= 0xFF
        XCTAssertTrue(LibreSensorType.libreProH.crcIsOk(rxBuffer: &buffer, headerLength: 0, log: nil), "bytes after the ProH footer are not covered")
        buffer[100] ^= 0xFF
        XCTAssertFalse(LibreSensorType.libreProH.crcIsOk(rxBuffer: &buffer, headerLength: 0, log: nil))
    }

    func testCrcMatchesKnownVector() {
        // CRC of the decrypted real Libre 2 header section, as stored in its first two bytes.
        let decrypted = LibreCoverageBytes.data(hex: "52e1d0180300000000000000000000000000000000000000")
        XCTAssertEqual(LibreCoverageBytes.crc16(Array(decrypted.dropFirst(2))), 0x52E1)
    }

    // MARK: - LibreSensorState

    func testSensorStateDecodesEveryStateByte() {
        let expected: [UInt8: LibreSensorState] = [1: .notYetStarted, 2: .starting, 3: .ready, 4: .expired, 5: .shutdown, 6: .failure]
        for (byte, state) in expected {
            XCTAssertEqual(LibreSensorState(stateByte: byte), state)
        }
        for byte: UInt8 in [0, 7, 0x10, 0xFF] {
            XCTAssertEqual(LibreSensorState(stateByte: byte), .unknown)
        }
        XCTAssertEqual(LibreSensorState(), .unknown)
    }

    func testSensorStateDescriptions() {
        XCTAssertEqual(LibreSensorState.notYetStarted.description, "Sensor not yet startet")
        XCTAssertEqual(LibreSensorState.starting.description, "Sensor in starting phase")
        XCTAssertEqual(LibreSensorState.ready.description, "Sensor is ready")
        XCTAssertEqual(LibreSensorState.expired.description, "Sensor is expired")
        XCTAssertEqual(LibreSensorState.shutdown.description, "Sensor is shut down")
        XCTAssertEqual(LibreSensorState.failure.description, "Sensor has failure")
        XCTAssertEqual(LibreSensorState.unknown.description, "Unknown sensor state")
    }

    func testSensorStateTranslatedDescriptionsUseLibreStateTexts() {
        XCTAssertEqual(LibreSensorState.notYetStarted.translatedDescription, TextsLibreStates.notYetStarted)
        XCTAssertEqual(LibreSensorState.starting.translatedDescription, TextsLibreStates.starting)
        XCTAssertEqual(LibreSensorState.ready.translatedDescription, TextsLibreStates.ready)
        XCTAssertEqual(LibreSensorState.expired.translatedDescription, TextsLibreStates.expired)
        XCTAssertEqual(LibreSensorState.shutdown.translatedDescription, TextsLibreStates.shutdown)
        XCTAssertEqual(LibreSensorState.failure.translatedDescription, TextsLibreStates.failure)
        XCTAssertEqual(LibreSensorState.unknown.translatedDescription, TextsLibreStates.unknown)
    }

    func testOnlyMappedSensorStatesProduceHealthEvents() {
        XCTAssertEqual(LibreSensorState.ready.sensorHealthEvent, .recovered(source: .libre))
        XCTAssertEqual(LibreSensorState.expired.sensorHealthEvent, .recovered(source: .libre))
        XCTAssertEqual(LibreSensorState.failure.sensorHealthEvent, .terminal(source: .libre, reason: .libreSensorFailure))
        for state: LibreSensorState in [.notYetStarted, .starting, .shutdown, .unknown] {
            XCTAssertNil(state.sensorHealthEvent)
        }
    }

    // MARK: - LibreSensorSerialNumber

    func testSerialNumberRequiresEightByteUID() {
        XCTAssertNil(LibreSensorSerialNumber(withUID: Data([1, 2, 3]), with: .libre1))
        XCTAssertNil(LibreSensorSerialNumber(withUID: Data(repeating: 0, count: 9), with: .libre1))
        XCTAssertNotNil(LibreSensorSerialNumber(withUID: Data(repeating: 0, count: 8), with: nil))
    }

    func testSerialNumberMatchesDocumentedExample() {
        let serial = LibreSensorSerialNumber(withUID: Data([0x5E, 0x90, 0x25, 0x00, 0x00, 0xA0, 0x07, 0xE0]), with: .libre1)
        XCTAssertEqual(serial?.serialNumber, "0M00009DHCR")
    }

    func testSerialNumberPrefixDependsOnSensorFamily() {
        let uid = Data([0x5E, 0x90, 0x25, 0x00, 0x00, 0xA0, 0x07, 0xE0])
        let suffix = "M00009DHCR"
        let expectations: [(LibreSensorType?, String)] = [
            (nil, "0"), (.libre1, "0"), (.libre1A2, "0"), (.libreUS, "0"), (.libreUSE6, "0"), (.libreProH, "1"),
            (.libre2, "3"), (.libre2C5, "3"), (.libre2C6, "3"), (.libre27F, "3"), (.libre27FNonPlus, "3"),
        ]
        for (type, prefix) in expectations {
            XCTAssertEqual(LibreSensorSerialNumber(withUID: uid, with: type)?.serialNumber, prefix + suffix, String(describing: type))
        }
    }

    func testSerialNumberOfRealLibre2Sensors() {
        let miaoMiao = LibreSensorSerialNumber(withUID: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID), with: .libre2)
        XCTAssertEqual(miaoMiao?.serialNumber, "3MH00199R7W")
        let direct = LibreSensorSerialNumber(withUID: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID), with: .libre2)
        XCTAssertEqual(direct?.serialNumber, "3MH0033N1WD")
    }

    func testSerialNumberStringRepresentations() throws {
        let serial = try XCTUnwrap(LibreSensorSerialNumber(withUID: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID), with: .libre2))
        XCTAssertEqual(serial.uidString, "3f38a50000a407e0")
        XCTAssertEqual(serial.prettyUidString, "3F:38:A5:00:00:A4:07:E0")
        XCTAssertEqual(serial.description, "Uid is 3F:38:A5:00:00:A4:07:E0 and derived serial number is 3MH00199R7W")
    }

    func testSerialNumberUsesOnlyTheReducedAlphabet() {
        let serial = LibreSensorSerialNumber(withUID: Data(repeating: 0xFF, count: 8), with: nil)!.serialNumber
        XCTAssertEqual(serial.count, 11)
        XCTAssertEqual(serial, "0ZZZZZZZZZW")
        for forbidden in ["B", "I", "O", "S"] {
            XCTAssertFalse(serial.contains(forbidden))
        }
    }

    // MARK: - Errors and enums

    func testLibreErrorsAreHighPriorityWithLocalizedDescriptions() {
        XCTAssertEqual(LibreError.sensorNotReady.priority, .HIGH)
        XCTAssertEqual(LibreError.sensorNotReady.errorDescription, TextsLibreErrors.libreSensorNotReady)
        XCTAssertEqual(LibreOOPWebError.libreUSNotSupported.priority, .HIGH)
        XCTAssertEqual(LibreOOPWebError.libreUSNotSupported.errorDescription, TextsLibreErrors.oOPWebServerError + " " + TextsLibreErrors.libreUSNotSupported)
    }

    func testMiaoMiaoResponseTypesMapWireBytes() {
        XCTAssertEqual(MiaoMiaoResponseType(rawValue: 0x28), .dataPacket)
        XCTAssertEqual(MiaoMiaoResponseType(rawValue: 0x32), .newSensor)
        XCTAssertEqual(MiaoMiaoResponseType(rawValue: 0x34), .noSensor)
        XCTAssertEqual(MiaoMiaoResponseType(rawValue: 0xD1), .frequencyChangedResponse)
        XCTAssertNil(MiaoMiaoResponseType(rawValue: 0x00))
        XCTAssertEqual(MiaoMiaoResponseType.dataPacket.description, "Data packet received")
        XCTAssertEqual(MiaoMiaoResponseType.newSensor.description, "New sensor detected")
        XCTAssertEqual(MiaoMiaoResponseType.noSensor.description, "No sensor detected")
        XCTAssertEqual(MiaoMiaoResponseType.frequencyChangedResponse.description, "Reading interval changed")
    }
}
