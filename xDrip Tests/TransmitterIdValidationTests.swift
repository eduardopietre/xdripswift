//
//  TransmitterIdValidationTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the characters allowed in a Dexcom transmitter ID.
///
/// The pattern "[a-zA-Z0-9]" only asked for one letter or digit somewhere in the text, so an ID
/// with spaces or symbols, such as "8G 123", was accepted and the transmitter was never found.
final class TransmitterIdValidationTests: XCTestCase {

    func testDexcomIdsWithANonAlphanumericCharacterAreRejected() {
        XCTAssertEqual(BluetoothPeripheralType.DexcomType.validateTransmitterId(transmitterId: "8G12!@"), Texts_ErrorMessages.DexcomTransmitterIDInvalidCharacters)
        XCTAssertEqual(BluetoothPeripheralType.DexcomType.validateTransmitterId(transmitterId: "8G 123"), Texts_ErrorMessages.DexcomTransmitterIDInvalidCharacters)
        XCTAssertEqual(BluetoothPeripheralType.DexcomG7Type.validateTransmitterId(transmitterId: "DX1-3"), Texts_ErrorMessages.DexcomTransmitterIDInvalidCharacters)
    }

    /// "$" also matches before a final line break, so a pasted ID ending in one would pass a
    /// pattern anchored with it.
    func testDexcomIdsEndingInALineBreakAreRejected() {
        XCTAssertEqual(BluetoothPeripheralType.DexcomType.validateTransmitterId(transmitterId: "8G123\n"), Texts_ErrorMessages.DexcomTransmitterIDInvalidCharacters)
        XCTAssertEqual(BluetoothPeripheralType.DexcomG7Type.validateTransmitterId(transmitterId: "DX1\n"), Texts_ErrorMessages.DexcomTransmitterIDInvalidCharacters)
    }

    func testAlphanumericDexcomIdsAreAccepted() {
        XCTAssertNil(BluetoothPeripheralType.DexcomType.validateTransmitterId(transmitterId: "8G1234"))
        XCTAssertNil(BluetoothPeripheralType.DexcomType.validateTransmitterId(transmitterId: "8g12ab"))
        XCTAssertNil(BluetoothPeripheralType.DexcomG7Type.validateTransmitterId(transmitterId: "DX1a"))
        XCTAssertNil(BluetoothPeripheralType.DexcomG7Type.validateTransmitterId(transmitterId: ""), "an empty G7 ID scans for any G7")
    }
}
