//
//  Libre3ProtocolTestFixtures.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
@testable import xdrip

/// Builders for synthetic Libre 3 data-plane plaintexts.
///
/// The decoders under test read fixed little-endian offsets, so the tests build every
/// frame field by field instead of copying opaque hex strings: that way each test states
/// exactly which byte it changes and why the decoded value must follow.
enum Libre3ProtocolFixtures {

    // MARK: - hex

    /// Decodes a hex string ("00a5ff") into bytes, failing loudly on malformed input so a
    /// typo in a fixture cannot silently produce a shorter frame.
    static func data(hex: String) -> Data {
        precondition(hex.count % 2 == 0, "odd hex length in fixture")
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                preconditionFailure("invalid hex in fixture: \(hex[index..<next])")
            }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Returns `data` as a slice of a larger buffer, so its `startIndex` is not 0.
    ///
    /// Decoders that index with absolute offsets instead of `startIndex + offset` read the
    /// wrong bytes (or trap) on such slices; parsers fed with `Data` slices must cope.
    static func sliced(_ data: Data, paddingCount: Int = 3) -> Data {
        let padded = Data(repeating: 0xee, count: paddingCount) + data + Data([0xee])
        return padded[(padded.startIndex + paddingCount)..<(padded.startIndex + paddingCount + data.count)]
    }
}

/// Field-by-field builder for the 29-byte realtime glucose plaintext (glucoseData channel).
///
/// Defaults reproduce the first live capture used in `Libre3DataPlaneTests`
/// (`e3386200d6ff0000f023d1386c000b62006c00200a9e03113d03100000`): a clean, actionable,
/// stable 98 mg/dL reading.
struct Libre3RealtimePlaintextBuilder {
    var lifeCount: UInt16 = 14563
    var currentWord: UInt16 = 98
    var rateOfChangeRaw: Int16 = -42
    var temperatureStatus: UInt16 = 0
    var projectedGlucose: UInt16 = 9200
    var historicalLifeCount: UInt16 = 14545
    var historicalWord: UInt16 = 108
    var trendAndStatusByte: UInt8 = 0x0b
    var uncappedCurrentMgDL: UInt16 = 98
    var uncappedHistoricMgDL: UInt16 = 108
    var temperature: UInt16 = 2592
    var fastData: [UInt8] = [0x9e, 0x03, 0x11, 0x3d, 0x03, 0x10, 0x00, 0x00]

    /// The encoded plaintext, in the wire layout read by `Libre3RealtimeGlucoseReading`.
    var data: Data {
        var out = Data()
        Self.append(lifeCount, to: &out)
        Self.append(currentWord, to: &out)
        Self.append(UInt16(bitPattern: rateOfChangeRaw), to: &out)
        Self.append(temperatureStatus, to: &out)
        Self.append(projectedGlucose, to: &out)
        Self.append(historicalLifeCount, to: &out)
        Self.append(historicalWord, to: &out)
        out.append(trendAndStatusByte)
        Self.append(uncappedCurrentMgDL, to: &out)
        Self.append(uncappedHistoricMgDL, to: &out)
        Self.append(temperature, to: &out)
        out.append(contentsOf: fastData)
        return out
    }

    /// Parses the built plaintext; a convenience so tests read as "build, then decode".
    func reading() throws -> Libre3RealtimeGlucoseReading {
        try Libre3RealtimeGlucoseReading(plaintext: data)
    }

    static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }
}

/// Field-by-field builder for the 12-byte patch status plaintext (patchStatus channel).
///
/// Defaults describe a healthy, active sensor 14564 minutes into its wear.
struct Libre3PatchStatusPlaintextBuilder {
    var lifeCount: Int16 = 10397
    var errorData: Int16 = 0
    var eventDataRaw: Int16 = 224
    var index: UInt8 = 7
    var patchState: UInt8 = 4
    var currentLifeCount: Int16 = 14564
    var stackDisconnectReason: UInt8 = 0
    var appDisconnectReason: UInt8 = 0

    /// The encoded plaintext, in the wire layout read by `Libre3PatchStatus`.
    var data: Data {
        var out = Data()
        Libre3RealtimePlaintextBuilder.append(UInt16(bitPattern: lifeCount), to: &out)
        Libre3RealtimePlaintextBuilder.append(UInt16(bitPattern: errorData), to: &out)
        Libre3RealtimePlaintextBuilder.append(UInt16(bitPattern: eventDataRaw), to: &out)
        out.append(index)
        out.append(patchState)
        Libre3RealtimePlaintextBuilder.append(UInt16(bitPattern: currentLifeCount), to: &out)
        out.append(stackDisconnectReason)
        out.append(appDisconnectReason)
        return out
    }

    /// Parses the built plaintext.
    func status() throws -> Libre3PatchStatus {
        try Libre3PatchStatus(plaintext: data)
    }
}
