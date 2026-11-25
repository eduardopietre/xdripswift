//
//  LibreByteParserFuzzTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Feeds the Libre 1/2 entry points truncated, corrupted and random input, including slices.
///
/// NFC reads and transmitter packets (MiaoMiao, Bubble, Libre 2 direct) reach these functions
/// before anything else checks them, so they must reject bad input, never crash. The record
/// decoders that the parser only calls after the CRC and length checks (`LibreMeasurement`,
/// `LibreCalibrationInfo`) are fuzzed at their real sizes with arbitrary content, which finds
/// arithmetic traps without reporting inputs that cannot reach them.
final class LibreByteParserFuzzTests: XCTestCase {

    private lazy var inputs = ByteFuzz.inputs(seeds: [Data(count: 344), Data(count: 362)], maxLength: 400, randomMutations: 20)

    func testFRAMCrcNeverCrashes() {
        var generator = ByteFuzzRandom(seed: 0xC2C)
        for input in inputs {
            for type in [LibreSensorType.libre1, .libre2, .libreProH, nil] {
                var data = input
                _ = Crc.LibreCrc(data: &data, headerOffset: Int.random(in: -2...30, using: &generator), libreSensorType: type)
            }
        }
    }

    func testSerialNumberAndPatchInfoNeverCrash() {
        var generator = ByteFuzzRandom(seed: 0x5E1A)
        let digits = Array("0123456789ABCDEF")
        for input in inputs.prefix(1500 * ByteFuzz.scale) {
            for type in [LibreSensorType.libre1, .libre2, .libreUS, .libreProH, nil] {
                _ = LibreSensorSerialNumber(withUID: input, with: type)?.serialNumber
            }
            _ = LibreSensorType.type(patchInfo: String(input.prefix(16).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] }))
        }
        // Patch info arrives as text from the transmitter: odd lengths, non-hex characters, spaces.
        let alphabet = Array("0123456789abcdefABCDEFxyz -")
        for _ in 0..<(1000 * ByteFuzz.scale) {
            let text = String((0..<Int.random(in: 0...16, using: &generator)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
            _ = LibreSensorType.type(patchInfo: text)
        }
    }

    /// Records at their real sizes (6 byte readings, 344 byte FRAM) with any content.
    func testRecordDecodersNeverCrashOnAnyContent() {
        var generator = ByteFuzzRandom(seed: 0xFEED)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<(1000 * ByteFuzz.scale) {
            let record = Data((0..<6).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = LibreMeasurement(bytes: record, date: date)
            let fram = Data((0..<344).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = LibreCalibrationInfo(bytes: fram, libreSensorType: .libre1)
            _ = LibreCalibrationInfo(bytes: fram, libreSensorType: .libreProH)
        }
    }

    /// Libre 2 BLE fragments in any size and timing.
    func testLibre2FrameAssemblerNeverCrashes() {
        var generator = ByteFuzzRandom(seed: 0xA55E)
        let clock = ContinuousClock.now
        for _ in 0..<(500 * ByteFuzz.scale) {
            var assembler = Libre2FrameAssembler()
            var time = clock
            for _ in 0..<Int.random(in: 1...10, using: &generator) {
                time = time.advanced(by: .milliseconds(Int.random(in: 0...4000, using: &generator)))
                _ = assembler.append(inputs[Int.random(in: 0..<inputs.count, using: &generator)].prefix(60), arrival: time)
                if Int.random(in: 0..<10, using: &generator) == 0 { assembler.reset() }
            }
        }
    }
}
