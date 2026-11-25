//
//  ByteFuzz.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

/// Generates hostile byte inputs for the transmitter parsers.
///
/// Bluetooth and NFC data arrive truncated, merged, corrupted or from a different sensor model, so
/// a parser must reject bad input, not crash: a crash in a parser kills the app and stops alarms.
/// Several parsers read `data[i]` without checking the length, or assume a `Data` starts at index
/// 0. The fuzz tests feed every parser these inputs and only require that it returns.
///
/// The inputs are deterministic (fixed seed), so a failure is reproducible: the failing input is
/// the same on every run and machine.
///
/// Inputs, for each valid sample (`seeds`) and as plain noise:
/// - every length from 0 to `maxLength` filled with 0x00, with 0xFF and with random bytes;
/// - every truncation of each sample, and each sample with extra bytes appended;
/// - each sample with one bit flipped (all bits for short samples, a random choice otherwise) and
///   with a few random bytes replaced;
/// - and every input above once more as a slice of a larger buffer (`startIndex` not 0).
enum ByteFuzz {

    /// Multiplies the amount of random work of the fuzz tests: 1 by default, so they cost a few
    /// seconds on every run; set `XDRIP_FUZZ_SCALE` (e.g. 20) for a deep run, like a nightly job.
    static let scale = max(1, Int(ProcessInfo.processInfo.environment["XDRIP_FUZZ_SCALE"] ?? "") ?? 1)

    /// Builds the inputs described above.
    ///
    /// - Parameters:
    ///   - seeds: valid messages of the parser, so mutations reach the deeper code paths.
    ///   - maxLength: longest noise input; use a little more than the largest valid message.
    ///   - randomMutations: random multi-byte mutations per seed.
    ///   - includeSlices: also return every input as a slice of a larger buffer. Leave it on unless
    ///     every caller of the parser passes a fresh buffer (say so where it is turned off).
    static func inputs(seeds: [Data] = [], maxLength: Int = 64, randomMutations: Int = 200, includeSlices: Bool = true,
                       seed: UInt64 = 0x5EED) -> [Data] {
        var generator = SplitMix64(seed: seed)
        let randomMutations = randomMutations * scale
        var inputs = [Data]()

        for length in 0...maxLength {
            inputs.append(Data(repeating: 0x00, count: length))
            inputs.append(Data(repeating: 0xFF, count: length))
            inputs.append(Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        }

        for sample in seeds {
            for length in 0...sample.count {
                inputs.append(Data(sample.prefix(length)))
            }
            for extra in [1, 2, 7, 64] {
                inputs.append(sample + Data((0..<extra).map { _ in UInt8.random(in: 0...255, using: &generator) }))
            }
            if !sample.isEmpty {
                let bitPositions = sample.count * 8 <= 512
                    ? Array(0..<(sample.count * 8))
                    : (0..<512).map { _ in Int.random(in: 0..<(sample.count * 8), using: &generator) }
                for bit in bitPositions {
                    var flipped = [UInt8](sample)
                    flipped[bit / 8] ^= 1 << (bit % 8)
                    inputs.append(Data(flipped))
                }
                for _ in 0..<randomMutations {
                    var mutated = [UInt8](sample)
                    for _ in 0..<Int.random(in: 1...4, using: &generator) {
                        mutated[Int.random(in: 0..<mutated.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                    }
                    inputs.append(Data(mutated))
                }
            }
        }

        guard includeSlices else { return inputs }

        // The same inputs as slices whose indices do not start at 0.
        let slices = inputs.map { input -> Data in
            let buffer = Data([0xA5, 0x5A, 0xC3]) + input + Data([0x3C])
            return buffer.dropFirst(3).dropLast()
        }
        return inputs + slices
    }

    /// Bytes from a hex string, e.g. `"0a1B"`; for writing seeds.
    static func hex(_ text: String) -> Data {
        let digits = Array(text.filter { !$0.isWhitespace })
        precondition(digits.count % 2 == 0, "odd number of hex digits")
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }
}

/// A small, fast, seedable random number generator (SplitMix64), so fuzz inputs are reproducible.
struct ByteFuzzRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private typealias SplitMix64 = ByteFuzzRandom
