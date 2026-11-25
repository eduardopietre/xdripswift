//
//  DexcomBackfillStream.swift
//  xDrip
//
//  Created by Ivan Skoryk on 02.11.2020.
//  Copyright © 2020 Faifly. All rights reserved.
//

import Foundation

final class DexcomBackfillStream {
    struct BackFill {
        let glucose: Int
        let trend: Int
        let dexTime: Int
    }
    
    var data = Data()
    private var lastSequence = 0
    private var idx = 4
    
    
    /// Adds the data bytes of a packet (all but its sequence number and the unused second byte) if
    /// it is the next packet in sequence. Short packets and slices of a larger buffer are fine: a
    /// one byte packet used to build the range 2..<1 and crash.
    func push(_ packet: Data) {
        let bytes = [UInt8](packet)
        guard let thisSequence = bytes.first else { return }

        if Int(thisSequence) == lastSequence + 1 {
            lastSequence += 1
            for byte in bytes.dropFirst(2) {
                guard data.count < 1000 else {
                    return
                }
                data.append(byte)
            }
        }
    }

    /// Returns the records completed since the last call and drops their bytes from `data`.
    ///
    /// The first 4 bytes of the stream are a header. Each record is 8 bytes: little-endian time
    /// (4), glucose (2), algorithm state (1) and trend (1). Records are read as whole blocks from
    /// `idx`, which always points at the start of a record, so skipped records and a record that is
    /// still incomplete keep the alignment of what follows. Previously a skipped record moved the
    /// read position without dropping its bytes, and an incomplete record then reset the position
    /// to 0 with the header still in the buffer, so the next call read the header as a record.
    func decode() -> [BackFill] {
        let recordSize = 8
        var backfills: [BackFill] = []
        let bytes = [UInt8](data)

        while idx + recordSize <= bytes.count {
            let dexTime = UInt32(bytes[idx]) | UInt32(bytes[idx + 1]) << 8 | UInt32(bytes[idx + 2]) << 16 | UInt32(bytes[idx + 3]) << 24
            let glucose = UInt16(bytes[idx + 4]) | UInt16(bytes[idx + 5]) << 8
            let type = bytes[idx + 6]
            let trend = bytes[idx + 7]
            idx += recordSize

            switch DexcomAlgorithmState(rawValue: type) {
            case .okay, .needsCalibration:
                if dexTime != 0 {
                    backfills.append(BackFill(glucose: Int(glucose), trend: Int(trend), dexTime: Int(dexTime)))
                }
            default:
                // Unknown states and states without a usable value are skipped.
                break
            }
        }

        // The header has not fully arrived yet: keep everything and the position after it.
        guard idx <= bytes.count else { return backfills }

        // Keep only the incomplete record, if any; the next record starts at its beginning.
        data = Data(bytes[idx...])
        idx = 0
        return backfills
    }
}
