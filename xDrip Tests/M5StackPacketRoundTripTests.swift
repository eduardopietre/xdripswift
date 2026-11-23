//
//  M5StackPacketRoundTripTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Checks the M5Stack text framing in both directions: `M5StackUtilities.splitTextInBLEPackets`
/// cuts a text (slope name, password) into BLE packets of opcode, packet number, packet count and
/// payload, and `M5StackPacket` puts the packets the M5Stack sends back together.
///
/// BLE packets hold 20 bytes, so most texts span several packets and multi-byte UTF-8 characters
/// are cut in the middle; a lost, repeated or late packet must never produce a wrong password.
final class M5StackPacketRoundTripTests: XCTestCase {

    // MARK: - fixtures

    /// Texts with one to four byte UTF-8 characters, so packet boundaries fall inside characters.
    private static let texts = [
        "a", "password", "exactly-17-bytes!", "this text needs more than one ble packet to be sent",
        "Glicose está subindo rápido", "Blutzucker fällt ↘︎", "🩸 high 🩸 high 🩸", String(repeating: "é", count: 40),
    ]

    private static func assemble(_ packets: [Data]) -> String? {
        let assembler = M5StackPacket()
        packets.forEach { assembler.addNewPacket(value: $0) }
        return assembler.getText()
    }

    // MARK: - tests

    func testSplitPacketsRespectTheSizeAndNumbering() throws {
        for text in Self.texts {
            for maxSize in [4, 5, 8, 20] {
                let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: text, maxBytesInOneBLEPacket: maxSize, opCode: 0x13))
                let payloadSize = maxSize - 3
                let byteCount = text.utf8.count
                let expectedCount = (byteCount + payloadSize - 1) / payloadSize

                XCTAssertEqual(packets.count, expectedCount, "\(text), max \(maxSize)")
                for (index, packet) in packets.enumerated() {
                    XCTAssertLessThanOrEqual(packet.count, maxSize, "\(text), max \(maxSize)")
                    XCTAssertGreaterThan(packet.count, 3, "no packet without payload")
                    XCTAssertEqual(packet[0], 0x13)
                    XCTAssertEqual(Int(packet[1]), index + 1)
                    XCTAssertEqual(Int(packet[2]), expectedCount)
                    if index < packets.count - 1 {
                        XCTAssertEqual(packet.count, maxSize, "only the last packet may be short")
                    }
                }
                XCTAssertEqual(Data(packets.flatMap { $0.dropFirst(3) }), Data(text.utf8))
            }
        }
    }

    func testTextsWithMultiByteCharactersRoundTripInAnyOrder() throws {
        var generator = SystemRandomNumberGenerator()
        for text in Self.texts {
            let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: text, maxBytesInOneBLEPacket: 20, opCode: 0x0E))
            XCTAssertEqual(Self.assemble(packets), text)
            XCTAssertEqual(Self.assemble(packets.reversed()), text)
            XCTAssertEqual(Self.assemble(packets.shuffled(using: &generator)), text)
        }
    }

    func testTextIsOnlyAvailableOnceEveryPacketArrived() throws {
        let text = "this text needs more than one ble packet to be sent"
        let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: text, maxBytesInOneBLEPacket: 20, opCode: 0x0E))
        XCTAssertEqual(packets.count, 3)

        for missing in packets.indices {
            let assembler = M5StackPacket()
            for (index, packet) in packets.enumerated() where index != missing {
                assembler.addNewPacket(value: packet)
                XCTAssertNil(assembler.getText(), "packet \(missing + 1) is still missing")
            }
            assembler.addNewPacket(value: packets[missing])
            XCTAssertEqual(assembler.getText(), text)
        }
    }

    func testRepeatedPacketDoesNotChangeTheText() throws {
        let text = "Glicose está subindo rápido"
        let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: text, maxBytesInOneBLEPacket: 20, opCode: 0x0E))
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(Self.assemble([packets[0], packets[0], packets[1], packets[1]]), text)
    }

    func testLatePacketStartsANewMessage() throws {
        // Packets more than ConstantsM5Stack.maximumTimeBetweenTwoPacketsInMs apart do not belong
        // together: the stale first half is dropped instead of being glued to a later packet.
        let text = "this text needs more than one ble packet to be sent"
        let packets = try XCTUnwrap(M5StackUtilities.splitTextInBLEPackets(text: text, maxBytesInOneBLEPacket: 20, opCode: 0x0E))
        let assembler = M5StackPacket()
        assembler.addNewPacket(value: packets[0])
        assembler.addNewPacket(value: packets[1])

        Thread.sleep(forTimeInterval: Double(ConstantsM5Stack.maximumTimeBetweenTwoPacketsInMs) / 1000 + 0.1)
        assembler.addNewPacket(value: packets[2])
        XCTAssertNil(assembler.getText(), "packets 1 and 2 timed out")

        // a fresh, timely transmission completes again
        assembler.addNewPacket(value: packets[0])
        assembler.addNewPacket(value: packets[1])
        XCTAssertEqual(assembler.getText(), text)
    }

}
