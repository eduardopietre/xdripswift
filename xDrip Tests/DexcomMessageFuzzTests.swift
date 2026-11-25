//
//  DexcomMessageFuzzTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Feeds every Dexcom G5/G6/G7 message parser truncated, corrupted and random notifications.
///
/// The parsers run on every BLE notification of the transmitter. A crash there stops readings and
/// alarms, so a malformed or unexpected notification must be rejected (nil) or decoded, never trap.
/// Most messages carry a CRC, so random bodies are also sent with a valid CRC appended: that gets
/// them past the CRC check into the field decoding. The only assertion is that each call returns.
///
/// The inputs are fresh buffers, not slices: the message parsers read `data[1]`, `data[2]`, … and
/// every caller passes the characteristic's `value` as received. A caller that passes
/// `value.dropFirst()` or similar would need the parsers to read relative to `startIndex` first.
final class DexcomMessageFuzzTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// For every opcode, random bodies of several lengths, plain and with a valid CRC; plus the
    /// generic noise and mutations of `ByteFuzz`.
    private lazy var inputs: [Data] = {
        var generator = ByteFuzzRandom(seed: 0xD3C0)
        var seeds = [Data]()
        for opcode in 0...255 {
            for length in [1, 2, 3, 5, 8, 10, 13, 16, 17, 19, 20, 24] {
                let body = Data([UInt8(opcode)] + (0..<(length - 1)).map { _ in UInt8.random(in: 0...255, using: &generator) })
                seeds.append(body)
                seeds.append(body.appendingCRC())
            }
        }
        // Session start/stop answers only decode with a known response code in byte 2.
        for opcode: UInt8 in [0x27, 0x29] {
            for response in 0...15 {
                let body = [opcode, UInt8.random(in: 0...1, using: &generator), UInt8(response)] + (0..<12).map { _ in UInt8.random(in: 0...255, using: &generator) }
                seeds.append(Data(body))
                seeds.append(Data(body).appendingCRC())
            }
        }
        return ByteFuzz.inputs(maxLength: 40, includeSlices: false) + seeds
    }()

    /// Runs `parse` on every input; a trap fails the whole run, so returning is the test.
    private func fuzz(_ name: String, _ parse: (Data) -> Any?) {
        var decoded = 0
        for input in inputs where parse(input) != nil {
            decoded += 1
        }
        // Not an assertion: shows in the log how many inputs each parser accepted.
        print("\(name): \(inputs.count) inputs, \(decoded) decoded")
    }

    func testG5AndG6MessagesNeverCrash() {
        fuzz("AuthChallengeRxMessage") { AuthChallengeRxMessage(data: $0) }
        fuzz("AuthRequestRxMessage") { AuthRequestRxMessage(data: $0) }
        fuzz("BatteryStatusRxMessage") { BatteryStatusRxMessage(data: $0) }
        fuzz("DexcomCalibrationRxMessage") { DexcomCalibrationRxMessage(data: $0) }
        fuzz("DexcomG6GlucoseDataRxMessage") { DexcomG6GlucoseDataRxMessage(data: $0, transmitterStartDate: start) }
        fuzz("DexcomSessionStartRxMessage") { DexcomSessionStartRxMessage(data: $0) }
        fuzz("DexcomSessionStopRxMessage") { DexcomSessionStopRxMessage(data: $0) }
        fuzz("DexcomTransmitterTimeRxMessage") { DexcomTransmitterTimeRxMessage(data: $0, receivedAt: start) }
        fuzz("GlucoseBackfillRxMessage") { GlucoseBackfillRxMessage(data: $0, transmitterStartDate: start) }
        fuzz("GlucoseDataRxMessage") { GlucoseDataRxMessage(data: $0) }
        fuzz("ResetRxMessage") { ResetRxMessage(data: $0) }
        fuzz("SensorDataRxMessage") { SensorDataRxMessage(data: $0) }
        fuzz("TransmitterVersionRxMessage") { TransmitterVersionRxMessage(data: $0) }
    }

    func testG7MessagesNeverCrash() {
        fuzz("DexcomG7BackfillMessage") { DexcomG7BackfillMessage(data: $0, sensorStartDate: start) }
        fuzz("DexcomG7CalibrationCommandResponse") { DexcomG7CalibrationCommandResponse(data: $0) }
        fuzz("DexcomG7CalibrationBounds") { DexcomG7CalibrationBounds(data: $0) }
        fuzz("DexcomG7BatteryStatusMessage") { DexcomG7BatteryStatusMessage(data: $0) }
        fuzz("DexcomG7VersionMessage") { DexcomG7VersionMessage(data: $0) }
        fuzz("DexcomG7ExtendedVersionMessage") { DexcomG7ExtendedVersionMessage(data: $0) }
        fuzz("G7GlucoseMessage") { G7GlucoseMessage(data: $0, receivedAt: start) }
        fuzz("G7CoexistenceGlucoseMessage") { G7CoexistenceGlucoseMessage(data: $0) }
    }

    /// The backfill stream gets packets in any order and length; decoding must never trap, and the
    /// stream must never hold more than its 1000 byte limit.
    func testBackfillStreamNeverCrashes() {
        var generator = ByteFuzzRandom(seed: 0xBAC4)
        for _ in 0..<300 {
            let stream = DexcomBackfillStream()
            for _ in 0..<Int.random(in: 1...30, using: &generator) {
                let packet = inputs[Int.random(in: 0..<inputs.count, using: &generator)]
                stream.push(packet)
                if Bool.random(using: &generator) { _ = stream.decode() }
            }
            _ = stream.decode()
            XCTAssertLessThanOrEqual(stream.data.count, 1000)
        }
    }

    /// The Watch helpers read little-endian values at offsets taken from the message.
    func testWatchProtocolReadsNeverCrash() {
        for input in inputs.prefix(5000) {
            for offset in [-1, 0, 1, 3, input.count - 4, input.count - 1, input.count, input.count + 1] {
                _ = DexcomWatchProtocol.uint32(input, at: offset)
            }
        }
    }
}
