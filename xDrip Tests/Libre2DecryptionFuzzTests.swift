//
//  Libre2DecryptionFuzzTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Feeds the Libre 2 decryption functions input of any length, including slices.
///
/// The sensor UID and the patch info come from the NFC read or from the transmitter box, which
/// sends the patch info as text, so both can be shorter or longer than a real sensor's. The BLE
/// frame comes from the frame assembler. A wrong length must give an error or data that fails the
/// CRC check afterwards, never a crash.
final class Libre2DecryptionFuzzTests: XCTestCase {

    private lazy var inputs = ByteFuzz.inputs(seeds: [Data(count: 46), Data(count: 8), Data(count: 6)], maxLength: 70, randomMutations: 50)

    func testBLEDecryptionNeverCrashes() {
        var generator = ByteFuzzRandom(seed: 0xB1E)
        for input in inputs {
            let uid = inputs[Int.random(in: 0..<inputs.count, using: &generator)].prefix(12)
            _ = try? Libre2BLEUtilities.decryptBLE(sensorUID: uid, data: input)
            _ = try? Libre2BLEUtilities.decryptBLE(sensorUID: Data(count: 8), data: input)
        }
    }

    func testFRAMDecryptionNeverCrashesOnAnyUIDOrPatchInfoLength() {
        var generator = ByteFuzzRandom(seed: 0xF7A)
        let fram = [UInt8](repeating: 0x5A, count: 344)
        for uidLength in 0...10 {
            for infoLength in 0...8 {
                let uid = (0..<uidLength).map { _ in UInt8.random(in: 0...255, using: &generator) }
                let info = (0..<infoLength).map { _ in UInt8.random(in: 0...255, using: &generator) }
                _ = PreLibre2.decryptFRAM(uid, info, fram)
                _ = PreLibre2.decryptFRAM(uid, info, Array(fram.prefix(Int.random(in: 0...344, using: &generator))))
            }
        }
    }
}
