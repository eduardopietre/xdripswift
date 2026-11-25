//
//  DexcomTxMessageTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the encoding of commands sent to Dexcom transmitters (Tx messages), the CRC framing
/// they share with the responses, the sensor code table and the G6 backfill stream decoder.
///
/// A transmitter silently ignores a command with a wrong CRC, a field at the wrong offset or the
/// wrong sign, so such a bug shows up only as "no session started" or "no backfill" on a real
/// device. These tests decode the encoded bytes again with the documented layout and cross-check
/// the two independent CRC implementations (message framing and the Watch helper).
final class DexcomTxMessageTests: XCTestCase {

    // MARK: - properties

    /// Fixed transmitter start so relative times in the encoded commands are exact.
    private let transmitterStart = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - CRC

    /// A CRC-CCITT must detect any single-bit error. Flip every bit of a real 20-byte command.
    func testCRCDetectsEverySingleBitFlipInAFramedCommand() {
        let framed = DexcomBackfillTxMessage(startTime: transmitterStart.addingTimeInterval(3600), endTime: transmitterStart.addingTimeInterval(7200), transmitterStartDate: transmitterStart).data
        XCTAssertTrue(framed.isCRCValid)

        for byteIndex in 0..<framed.count {
            for bit in 0..<8 {
                var corrupted = framed
                corrupted[byteIndex] ^= UInt8(1 << bit)
                XCTAssertFalse(corrupted.isCRCValid, "flip of bit \(bit) in byte \(byteIndex) went unnoticed")
            }
        }
    }

    /// The CRC is position dependent: swapping two payload bytes must invalidate the frame.
    func testCRCDetectsSwappedPayloadBytes() {
        let framed = Data([0x34, 0x90, 0x01, 0x10, 0x20, 0x30, 0x40]).appendingCRC()
        var swapped = framed
        swapped.swapAt(1, 2)

        XCTAssertFalse(swapped.isCRCValid)
    }

    /// The single-byte CRC helper and the collection CRC agree for every byte, and the framed
    /// checksum is stored little-endian after the payload.
    func testSingleByteCRCMatchesCollectionCRCAndIsAppendedLittleEndian() {
        for value in 0...255 {
            let byte = UInt8(value)
            XCTAssertEqual(byte.crc16, [byte].crc16)
            let framed = Data([byte]).appendingCRC()
            XCTAssertEqual(framed[1], UInt8(byte.crc16 & 0xFF))
            XCTAssertEqual(framed[2], UInt8(byte.crc16 >> 8))
        }
    }

    /// The Watch keeps its own copy of the checksum. Both implementations must agree on payloads
    /// of many lengths and contents, and on whether a frame is valid.
    func testWatchChecksumAgreesWithMessageCRC() {
        var seed: UInt32 = 12_345
        for length in 1...40 {
            let payload = Data((0..<length).map { _ -> UInt8 in
                seed = seed &* 1_103_515_245 &+ 12_345
                return UInt8(truncatingIfNeeded: seed >> 16)
            })
            XCTAssertEqual(DexcomG6WatchProtocol.checksum(payload), payload.crc16, "length \(length)")

            var framed = payload.appendingCRC()
            XCTAssertTrue(DexcomG6WatchProtocol.hasValidCRC(framed))
            framed[0] ^= 0x80
            XCTAssertEqual(DexcomG6WatchProtocol.hasValidCRC(framed), framed.isCRCValid)
        }
    }

    // MARK: - fixed commands

    /// Every single-opcode command is its opcode plus CRC, identical to what the Watch sends.
    func testSingleOpcodeCommandsMatchWatchEncoding() {
        let commands: [(Data, DexcomTransmitterOpCode)] = [
            (BatteryStatusTxMessage().data, .batteryStatusTx),
            (DexcomTransmitterTimeTxMessage().data, .transmitterTimeTx),
            (DexcomGlucoseDataTxMessage().data, .glucoseTx),
            (ResetTxMessage().data, .resetTx),
            (TransmitterVersionTxMessage().data, .transmitterVersionTx),
            (SensorDataTxMessage().data, .sensorDataTx)
        ]

        for (data, opcode) in commands {
            XCTAssertEqual(data, Data(for: opcode).appendingCRC(), opcode.description)
            XCTAssertEqual(data, DexcomG6WatchProtocol.command(opcode.rawValue), opcode.description)
            XCTAssertTrue(data.starts(with: opcode))
        }
    }

    /// Authentication messages are sent without a CRC; the slot byte is always the last byte.
    func testAuthenticationRequestEndsWithSlotByteAndHasNoCRC() {
        for slot in DexcomG6BluetoothSlot.allCases {
            let data = AuthRequestTxMessage(slot: slot).data
            XCTAssertEqual(data.count, 10)
            XCTAssertEqual(data.first, 0x01)
            XCTAssertEqual(data.last, slot.rawValue)
        }
        XCTAssertEqual(KeepAliveTxMessage(time: 0xFF).data, Data([0x06, 0xFF]))
    }

    /// `starts(with:)` must look at the first byte of a slice, not at index 0 of its parent.
    func testStartsWithOpcodeChecksTheFirstByteOfASlice() {
        let buffer = Data([0x00, 0x31, 0x4F])

        XCTAssertTrue(buffer[1...].starts(with: .glucoseRx))
        XCTAssertTrue(buffer[2...].starts(with: .glucoseG6Rx))
        XCTAssertFalse(buffer[1...].starts(with: .authRequestTx))
    }

    // MARK: - backfill request (0x50)

    /// A window that starts less than five minutes after transmitter start widens to a negative
    /// offset, which must be sent as a two's complement 32-bit value.
    func testBackfillRequestEncodesNegativeStartOffsetAsTwosComplement() {
        let data = DexcomBackfillTxMessage(startTime: transmitterStart.addingTimeInterval(100), endTime: transmitterStart.addingTimeInterval(1000), transmitterStartDate: transmitterStart).data

        XCTAssertEqual(Array(data[4..<8]), [0x38, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(data.subdata(in: 4..<8).to(Int32.self), -200)
        XCTAssertEqual(data.subdata(in: 8..<12).to(Int32.self), 1300)
        XCTAssertTrue(data.isCRCValid)
    }

    /// Fractional seconds are truncated toward zero after widening the window.
    func testBackfillRequestTruncatesFractionalSeconds() {
        let data = DexcomBackfillTxMessage(startTime: transmitterStart.addingTimeInterval(600.9), endTime: transmitterStart.addingTimeInterval(1000.7), transmitterStartDate: transmitterStart).data

        XCTAssertEqual(data.subdata(in: 4..<8).to(Int32.self), 300)
        XCTAssertEqual(data.subdata(in: 8..<12).to(Int32.self), 1300)
    }

    // MARK: - calibration (0x34)

    /// Glucose is a 16-bit and the timestamp a 32-bit little-endian field, relative to the
    /// transmitter start, followed by the CRC.
    func testCalibrationCommandRoundTripsThroughLittleEndianReaders() {
        let data = DexcomCalibrationTxMessage(glucose: 400, timeStamp: transmitterStart.addingTimeInterval(864_000), transmitterStartDate: transmitterStart).data

        XCTAssertEqual(data.count, 9)
        XCTAssertEqual(data.first, DexcomTransmitterOpCode.calibrateGlucoseTx.rawValue)
        XCTAssertEqual(data.subdata(in: 1..<3).to(UInt16.self), 400)
        XCTAssertEqual(data.subdata(in: 3..<7).to(Int32.self), 864_000)
        XCTAssertTrue(data.isCRCValid)
    }

    /// A blood glucose timestamp just before the transmitter start encodes as a negative offset.
    func testCalibrationCommandBeforeTransmitterStartIsNegative() {
        let data = DexcomCalibrationTxMessage(glucose: 100, timeStamp: transmitterStart.addingTimeInterval(-60), transmitterStartDate: transmitterStart).data

        XCTAssertEqual(data.subdata(in: 3..<7).to(Int32.self), -60)
        XCTAssertTrue(data.isCRCValid)
    }

    // MARK: - session start (0x26) and stop (0x28)

    /// With a sensor code, both calibration parameters follow the relative and the absolute
    /// start time, each as a 16-bit little-endian value.
    func testSessionStartWithSensorCodeAppendsParametersAfterBothTimes() throws {
        let start = transmitterStart.addingTimeInterval(7200)
        let parameters = try XCTUnwrap(DexcomCalibrationParameters(sensorCode: "5915"))

        let data = DexcomSessionStartTxMessage(startDate: start, transmitterStartDate: transmitterStart, dexcomCalibrationParameters: parameters).data

        XCTAssertEqual(data.count, 15)
        XCTAssertEqual(data.first, DexcomTransmitterOpCode.sessionStartTx.rawValue)
        XCTAssertEqual(data.subdata(in: 1..<5).to(UInt32.self), 7200)
        XCTAssertEqual(data.subdata(in: 5..<9).to(UInt32.self), UInt32(start.timeIntervalSince1970))
        XCTAssertEqual(data.subdata(in: 9..<11).to(Int16.self), 3100)
        XCTAssertEqual(data.subdata(in: 11..<13).to(Int16.self), 3600)
        XCTAssertTrue(data.isCRCValid)
    }

    /// The special null code "0000" means "no code" and must produce the same command.
    func testSessionStartWithNullCodeEqualsNoCode() throws {
        let start = transmitterStart.addingTimeInterval(60)
        let nullCode = try XCTUnwrap(DexcomCalibrationParameters(sensorCode: "0000"))
        let noCode = try XCTUnwrap(DexcomCalibrationParameters(sensorCode: nil))

        let withNullCode = DexcomSessionStartTxMessage(startDate: start, transmitterStartDate: transmitterStart, dexcomCalibrationParameters: nullCode).data
        let withoutCode = DexcomSessionStartTxMessage(startDate: start, transmitterStartDate: transmitterStart, dexcomCalibrationParameters: noCode).data

        XCTAssertEqual(withNullCode, withoutCode)
        XCTAssertEqual(withoutCode.count, 11)
    }

    func testSessionStopKeepsStopDateAndEncodesRelativeTime() {
        let stop = transmitterStart.addingTimeInterval(864_000.5)

        let message = DexcomSessionStopTxMessage(stopDate: stop, transmitterStartDate: transmitterStart)

        XCTAssertEqual(message.stopDate, stop)
        XCTAssertEqual(message.data.count, 7)
        XCTAssertEqual(message.data.subdata(in: 1..<5).to(UInt32.self), 864_000)
        XCTAssertTrue(message.data.isCRCValid)
    }

    // MARK: - sensor codes

    /// Every Dexcom sensor code has a twin printed on other packaging that maps to the same pair
    /// of calibration parameters; distinct pairs must stay distinct.
    func testEachSensorCodeTwinMapsToTheSameParameters() throws {
        let twins = [("5915", "9759"), ("5917", "9357"), ("5931", "9137"), ("5937", "7197"), ("5951", "9517"),
                     ("5955", "9179"), ("7171", "7539"), ("9117", "7135"), ("9159", "5397"), ("9311", "5391"),
                     ("9371", "5375"), ("9515", "5795"), ("9551", "5317"), ("9577", "5177"), ("9713", "5171")]
        var seen = Set<[Int16]>()

        for (first, second) in twins {
            let a = try XCTUnwrap(DexcomCalibrationParameters(sensorCode: first))
            let b = try XCTUnwrap(DexcomCalibrationParameters(sensorCode: second))
            XCTAssertEqual([a.parameter1, a.parameter2], [b.parameter1, b.parameter2], "\(first)/\(second)")
            XCTAssertLessThan(a.parameter1, a.parameter2, "\(first)")
            XCTAssertTrue(seen.insert([a.parameter1, a.parameter2]).inserted, "\(first) duplicates another code")
        }
    }

    /// Codes are matched exactly: padding, truncation or letters are not accepted.
    func testMalformedSensorCodesAreRejected() {
        for code in ["", "591", "59150", " 5915", "5915 ", "abcd", "1234"] {
            XCTAssertNil(DexcomCalibrationParameters(sensorCode: code), "'\(code)'")
        }
    }

    // MARK: - backfill stream

    /// The first two bytes of each packet (sequence and an unused byte) are not data, and the
    /// first four data bytes are a header skipped by the decoder.
    func testBackfillStreamStripsPacketPrefixAndSkipsHeader() {
        let stream = DexcomBackfillStream()

        stream.push(packet([0x01, 0xAB, 0xDE, 0xAD, 0xBE, 0xEF], record(time: 600, glucose: 111, state: 0x06, trend: 0x02)))

        XCTAssertEqual(stream.data.count, 12)
        XCTAssertEqual(stream.data.first, 0xDE)
        let decoded = stream.decode()
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.dexTime, 600)
        XCTAssertEqual(decoded.first?.glucose, 111)
        XCTAssertEqual(decoded.first?.trend, 2)
    }

    /// A record split across two packets is completed when the next packet arrives and decoded
    /// on the following call, without repeating the already returned record.
    func testBackfillStreamCompletesRecordSplitAcrossDecodeCalls() {
        let stream = DexcomBackfillStream()
        let first = record(time: 300, glucose: 100, state: 0x06, trend: 0)
        let second = record(time: 600, glucose: 105, state: 0x07, trend: 1)

        stream.push(packet([0x01, 0x00, 0, 0, 0, 0], first, Array(second.prefix(3))))
        XCTAssertEqual(stream.decode().map(\.dexTime), [300])

        stream.push(packet([0x02, 0x00], Array(second.dropFirst(3))))
        let rest = stream.decode()
        XCTAssertEqual(rest.map(\.dexTime), [600])
        XCTAssertEqual(rest.map(\.glucose), [105])
        XCTAssertTrue(stream.data.isEmpty)
    }

    /// Records whose state byte is not a known algorithm state are dropped without losing the
    /// alignment of the following record.
    func testBackfillStreamDropsUnknownStateRecordsAndKeepsAlignment() {
        let stream = DexcomBackfillStream()

        stream.push(packet([0x01, 0x00, 0, 0, 0, 0], record(time: 300, glucose: 999, state: 0x17, trend: 0), record(time: 600, glucose: 120, state: 0x06, trend: 0xFF)))

        let decoded = stream.decode()
        XCTAssertEqual(decoded.map(\.dexTime), [600])
        XCTAssertEqual(decoded.map(\.glucose), [120])
        XCTAssertEqual(decoded.map(\.trend), [255])
    }

    /// Regression: a record in a known state that is not shown (warm-up here) advanced the read
    /// position without dropping its bytes, and a following partial record then reset the position
    /// to 0 while the header was still in the buffer. The next call read the header as a record and
    /// lost the alignment of everything after it.
    func testBackfillStreamKeepsAlignmentAfterASkippedRecordAndASplitRecord() {
        let stream = DexcomBackfillStream()
        let warmup = record(time: 300, glucose: 0, state: 0x02, trend: 0)
        let second = record(time: 600, glucose: 105, state: 0x06, trend: 1)

        stream.push(packet([0x01, 0x00, 0xDE, 0xAD, 0xBE, 0xEF], warmup, Array(second.prefix(3))))
        XCTAssertTrue(stream.decode().isEmpty)

        stream.push(packet([0x02, 0x00], Array(second.dropFirst(3))))
        let rest = stream.decode()

        XCTAssertEqual(rest.map(\.dexTime), [600])
        XCTAssertEqual(rest.map(\.glucose), [105])
        XCTAssertTrue(stream.data.isEmpty)
    }

    /// Calling decode again without new data returns nothing and loses nothing.
    func testBackfillStreamDecodeIsSafeToRepeat() {
        let stream = DexcomBackfillStream()
        stream.push(packet([0x01, 0x00, 0, 0, 0, 0], record(time: 300, glucose: 100, state: 0x06, trend: 0), record(time: 600, glucose: 0, state: 0x02, trend: 0)))

        XCTAssertEqual(stream.decode().map(\.dexTime), [300])
        XCTAssertTrue(stream.decode().isEmpty)

        stream.push(packet([0x02, 0x00], record(time: 900, glucose: 110, state: 0x07, trend: 0)))
        XCTAssertEqual(stream.decode().map(\.dexTime), [900])
    }

    /// A decode before the whole header has arrived must not drop the header bytes received so far.
    func testBackfillStreamDecodeBeforeTheHeaderIsCompleteKeepsTheHeader() {
        let stream = DexcomBackfillStream()

        stream.push(packet([0x01, 0x00, 0xDE, 0xAD]))
        XCTAssertTrue(stream.decode().isEmpty)
        stream.push(packet([0x02, 0x00, 0xBE, 0xEF], record(time: 600, glucose: 120, state: 0x06, trend: 0)))

        XCTAssertEqual(stream.decode().map(\.glucose), [120])
    }

    // MARK: - Watch helpers

    /// Little-endian reads are bounds checked so a short notification cannot crash the Watch.
    func testWatchUInt32ReadIsBoundsChecked() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        XCTAssertEqual(DexcomWatchProtocol.uint32(data, at: 0), 0x0403_0201)
        XCTAssertEqual(DexcomWatchProtocol.uint32(data, at: 1), 0x0504_0302)
        XCTAssertNil(DexcomWatchProtocol.uint32(data, at: 2))
        XCTAssertNil(DexcomWatchProtocol.uint32(data, at: -1))
    }

    /// The challenge hash needs a six-character transmitter ID and an eight-byte challenge, and
    /// depends on both.
    func testWatchChallengeHashValidatesInputAndDependsOnBoth() throws {
        let challenge = Data(1...8)

        let hash = try XCTUnwrap(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G1234", challenge: challenge))

        XCTAssertEqual(hash.count, 8)
        XCTAssertEqual(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G1234", challenge: challenge), hash)
        XCTAssertNotEqual(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G1235", challenge: challenge), hash)
        XCTAssertNotEqual(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G1234", challenge: Data(2...9)), hash)
        XCTAssertNil(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G123", challenge: challenge))
        XCTAssertNil(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G12345", challenge: challenge))
        XCTAssertNil(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G1234", challenge: Data(1...7)))
    }

    /// The Watch glucose parser accepts both G5 (0x31) and G6 (0x4F) frames only with a valid
    /// CRC, reading the clock at bytes 6-9 and the twelve-bit value at bytes 10-11.
    func testWatchGlucoseParserRequiresKnownOpcodeAndValidCRC() throws {
        let body: [UInt8] = [0x00, 0, 0, 0, 0, 0x10, 0x0E, 0x00, 0x00, 0x2C, 0xF1, 0x06, 0x00, 0x00]

        let g6 = try XCTUnwrap(DexcomG6WatchProtocol.glucose(packet([0x4F], body).appendingCRC()))
        XCTAssertEqual(g6.seconds, 3600)
        XCTAssertEqual(g6.value, 300)
        XCTAssertEqual(g6.state, 0x06)
        XCTAssertNotNil(DexcomG6WatchProtocol.glucose(packet([0x31], body).appendingCRC()))
        XCTAssertNil(DexcomG6WatchProtocol.glucose(packet([0x4E], body).appendingCRC()))
        XCTAssertNil(DexcomG6WatchProtocol.glucose(packet([0x4F], body, [0x00, 0x00])))
    }

    // MARK: - private functions

    /// Concatenates packet fragments; keeps long byte layouts readable and fast to type-check.
    private func packet(_ parts: [UInt8]...) -> Data {
        Data(parts.flatMap { $0 })
    }

    /// One eight-byte backfill record: little-endian time and glucose, then state and trend.
    private func record(time: UInt32, glucose: UInt16, state: UInt8, trend: UInt8) -> [UInt8] {
        let timeBytes: [UInt8] = (0..<4).map { UInt8((time >> (8 * UInt32($0))) & 0xFF) }
        return timeBytes + [UInt8(glucose & 0xFF), UInt8(glucose >> 8), state, trend]
    }
}
