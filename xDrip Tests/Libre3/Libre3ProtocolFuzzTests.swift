//
//  Libre3ProtocolFuzzTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Feeds the Libre 3 BLE and NFC decoders truncated, corrupted and random input, including slices.
///
/// Every Libre 3 notification and NFC answer goes through these decoders. A malformed one must be
/// rejected with an error, never crash the app. The data plane is also fuzzed behind its
/// encryption: random plaintexts are encrypted with a test key, so they pass AES-CCM and reach the
/// payload decoding of every channel. The only assertion is that each call returns.
final class Libre3ProtocolFuzzTests: XCTestCase {

    private lazy var inputs = ByteFuzz.inputs(seeds: [
        ByteFuzz.hex("8e0369006b006d006b0069006e00"),            // historical page
        ByteFuzz.hex("64000100020003000000780073 00"),           // clinical record
        Data(count: Libre3RealtimeGlucoseReading.plaintextSize),
        Data(count: Libre3PatchStatus.plaintextSize),
    ], maxLength: 80)

    func testPlaintextDecodersNeverCrash() {
        for input in inputs {
            _ = try? Libre3RealtimeGlucoseReading(plaintext: input)
            _ = try? Libre3PatchStatus(plaintext: input)
            _ = try? Libre3HistoricalReadingPage(plaintext: input)
            _ = try? Libre3ClinicalReadingRecord(plaintext: input)
        }
    }

    func testFramingAndPairingDecodersNeverCrash() {
        for input in inputs {
            _ = try? Libre3DataFrame.parse(input)
            _ = try? Libre3Phase5Challenge.decode(input)
            _ = try? Libre3Phase6Response.decode(input)
            _ = try? Libre3NFCPatchInfo(raw: input)
            _ = try? Libre3NFCActivationResponse(raw: input)
            _ = Libre3NFCActivationCommand.abbottCRC16(input)
        }
    }

    /// Write and notify fragments arrive in any order and size.
    func testReassemblersNeverCrash() {
        var generator = ByteFuzzRandom(seed: 0x1BE3)
        for _ in 0..<500 {
            let fragments = (0..<Int.random(in: 0...8, using: &generator)).map { _ in inputs[Int.random(in: 0..<inputs.count, using: &generator)] }
            _ = try? Libre3BleFraming.reassembleWrite(fragments)

            let notify = Libre3BleFraming.NotifyReassembler()
            let assembler = Libre3DataPlaneNotificationAssembler()
            let channel = Libre3DataPlaneChannel.allCases[Int.random(in: 0..<Libre3DataPlaneChannel.allCases.count, using: &generator)]
            for fragment in fragments {
                _ = try? notify.feed(fragment)
                _ = try? notify.take(Int.random(in: -1...40, using: &generator))
                _ = assembler.feed(fragment: fragment, channel: channel)
            }
        }
    }

    /// Valid encryption around random plaintexts of every size, for every channel and packet kind,
    /// so the per-channel payload decoding sees hostile content; plus tampered frames.
    func testDataPlaneDecoderNeverCrashes() throws {
        let crypto = try Libre3DataPlaneCrypto(kEnc: Data(repeating: 0x42, count: 16), ivEnc: Data(repeating: 0x24, count: 8))
        let decoder = Libre3DataPlaneDecoder(crypto: crypto)
        var generator = ByteFuzzRandom(seed: 0xDA7A)

        for kind in Libre3DataPlanePacketKind.allCases {
            for length in [0, 1, 2, 5, 8, 12, 13, 14, 20, 26, 35] {
                let plaintext = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
                let frame = try crypto.encrypt(plaintext: plaintext, sequence: UInt16.random(in: 0...UInt16.max, using: &generator), kind: kind)
                for channel in Libre3DataPlaneChannel.allCases {
                    _ = try? decoder.decrypt(frame: frame, channel: channel)
                }
                // The same frame with one byte changed must fail authentication, not crash.
                if !frame.raw.isEmpty, let tampered = try? Libre3DataFrame.parse(Self.flipping(frame.raw, at: Int.random(in: 0..<frame.raw.count, using: &generator))) {
                    _ = try? decoder.decrypt(frame: tampered, channel: .glucoseData)
                }
            }
        }
        for input in inputs.prefix(300) {
            if let frame = try? Libre3DataFrame.parse(input) {
                _ = try? decoder.decrypt(frame: frame, channel: .glucoseData)
            }
        }
    }

    private static func flipping(_ data: Data, at index: Int) -> Data {
        var bytes = [UInt8](data)
        bytes[index] ^= 0x01
        return Data(bytes)
    }
}
