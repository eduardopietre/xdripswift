//
//  TransmitterVersionRxMessageTests.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Regression tests for the transmitter expiry in the Dexcom version message.
///
/// The expiry is a 16-bit little-endian value in bytes 13 and 14. The high byte was shifted as a
/// UInt8, which drops it, so 365 days read as 109 and 436 days (0x01B4) read as 180, which marks
/// the transmitter as an Anubis.
final class TransmitterVersionRxMessageTests: XCTestCase {

    private func message(expiryLowByte: UInt8, expiryHighByte: UInt8) -> TransmitterVersionRxMessage? {
        var body: [UInt8] = [0x4B, 0x00, 1, 6, 5, 25] + Array(repeating: 0, count: 11)
        body[13] = expiryLowByte
        body[14] = expiryHighByte
        return TransmitterVersionRxMessage(data: Data(body).appendingCRC())
    }

    func testExpiryKeepsItsHighByte() throws {
        let message = try XCTUnwrap(message(expiryLowByte: 0x6D, expiryHighByte: 0x01))
        XCTAssertEqual(Int(message.transmitterExpiryInDays), 365)
        XCTAssertFalse(message.isAnubis())
    }

    func testOnlyAnExpiryOfExactly180DaysIsAnAnubis() throws {
        XCTAssertTrue(try XCTUnwrap(message(expiryLowByte: 180, expiryHighByte: 0)).isAnubis())
        // 436 days has 180 as its low byte
        XCTAssertFalse(try XCTUnwrap(message(expiryLowByte: 180, expiryHighByte: 0x01)).isAnubis())
    }

    func testFirmwareVersion() throws {
        XCTAssertEqual(try XCTUnwrap(message(expiryLowByte: 90, expiryHighByte: 0)).firmwareVersionFormatted(), "1.6.5.25")
    }
}
