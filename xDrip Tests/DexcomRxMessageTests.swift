//
//  DexcomRxMessageTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the decoding of Dexcom G5/G6/G7 responses (Rx messages).
///
/// Each packet is built from the byte layout documented in the parser, with distinct values in
/// every field, so a parser that reads the wrong offset, the wrong byte order, a signed instead of
/// an unsigned field or accepts a packet of the wrong length or opcode fails here instead of
/// producing a plausible but wrong glucose value, date or sensor state on a real device.
final class DexcomRxMessageTests: XCTestCase {

    // MARK: - properties

    /// Fixed receipt time so dates derived from relative transmitter clocks are exact.
    private let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// Fixed transmitter start used by parsers that take it as input.
    private let transmitterStart = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - transmitter time (0x25)

    /// Both clocks are little-endian seconds: the first is relative to transmitter start, the
    /// second is the sensor session start relative to that same origin.
    func testTransmitterTimeDecodesBothClocksRelativeToReceipt() throws {
        let data = packet([0x25, 0x00], le32(1_000_000), le32(400_000)).appendingCRC()

        let message = try XCTUnwrap(DexcomTransmitterTimeRxMessage(data: data, receivedAt: receivedAt))

        XCTAssertEqual(message.transmitterTime, 1_000_000)
        XCTAssertEqual(message.transmitterStartDate, receivedAt.addingTimeInterval(-1_000_000))
        XCTAssertEqual(message.sensorStartDate, receivedAt.addingTimeInterval(-600_000))
        XCTAssertEqual(message.sensorStartCounter, 400_000)
    }

    /// A six-byte response carries only the transmitter clock, so no session can be inferred.
    func testTransmitterTimeWithoutSessionFieldHasNoSensorStart() throws {
        let message = try XCTUnwrap(DexcomTransmitterTimeRxMessage(data: packet([0x25, 0x00], le32(3600)), receivedAt: receivedAt))

        XCTAssertEqual(message.transmitterStartDate, receivedAt.addingTimeInterval(-3600))
        XCTAssertNil(message.sensorStartDate)
        XCTAssertNil(message.sensorStartCounter)
    }

    func testTransmitterTimeRejectsShortPacketAndOtherOpcode() {
        XCTAssertNil(DexcomTransmitterTimeRxMessage(data: Data([0x25, 0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(DexcomTransmitterTimeRxMessage(data: packet([0x24, 0x00], le32(3600), le32(60))))
    }

    /// A counter that is later than the transmitter clock is impossible and must not be used to
    /// identify a session, even though the legacy date is still derived from it.
    func testTransmitterTimeIgnoresCounterLaterThanTheClock() throws {
        let data = packet([0x25, 0x00], le32(1000), le32(2000))

        let message = try XCTUnwrap(DexcomTransmitterTimeRxMessage(data: data, receivedAt: receivedAt))

        XCTAssertNil(message.sensorStartCounter)
        XCTAssertEqual(message.sensorStartDate, receivedAt.addingTimeInterval(1000))
    }

    // MARK: - battery status (0x23 for G6, 0x22 for G7)

    /// Every field sits at its documented offset; voltages and resistance are little-endian.
    func testBatteryStatusDecodesFieldsAtDocumentedOffsets() throws {
        let data = packet([0x23, 0x00], le16(310), le16(298), le16(1500), [0x2A, 0x22]).appendingCRC()

        let message = try XCTUnwrap(BatteryStatusRxMessage(data: data))

        XCTAssertEqual(message.status, 0)
        XCTAssertEqual(message.voltageA, 310)
        XCTAssertEqual(message.voltageB, 298)
        XCTAssertEqual(message.resist, 1500)
        XCTAssertEqual(message.runtime, 42)
        XCTAssertEqual(message.temperature, 34)
    }

    /// G7 answers with opcode 0x22 and no CRC. The strict G6 parser must reject that frame and
    /// the G7 parser must reject a G6 frame, so neither protocol is decoded by the other.
    func testBatteryStatusParsersDoNotAcceptEachOthersFrames() throws {
        let g7Frame = packet([0x22, 0x00], le16(310), le16(298), le16(1500), [0x2A, 0x22])
        let g6Frame = packet([0x23], Array(g7Frame.dropFirst())).appendingCRC()

        XCTAssertNil(BatteryStatusRxMessage(data: g7Frame.appendingCRC()))
        XCTAssertNil(DexcomG7BatteryStatusMessage(data: g6Frame))

        let g7 = try XCTUnwrap(DexcomG7BatteryStatusMessage(data: g7Frame))
        let g6 = try XCTUnwrap(BatteryStatusRxMessage(data: g6Frame))
        XCTAssertEqual(g7.voltageA, g6.voltageA)
        XCTAssertEqual(g7.voltageB, g6.voltageB)
        XCTAssertEqual(g7.resistance, g6.resist)
        XCTAssertEqual(g7.runtime, g6.runtime)
    }

    /// The G6 parser reads the temperature unsigned while the G7 parser reads it signed.
    func testG7BatteryTemperatureIsSignedAndExtraBytesAreIgnored() throws {
        let data = packet([0x22, 0x01], le16(300), le16(290), le16(1200), [0x05, 0xF6, 0xEE, 0xEE])

        let message = try XCTUnwrap(DexcomG7BatteryStatusMessage(data: data))

        XCTAssertEqual(message.status, 1)
        XCTAssertEqual(message.temperature, -10)
        XCTAssertEqual(message.runtime, 5)
    }

    // MARK: - glucose (0x31)

    /// The upper nibble of the value carries flags and must be masked; an unknown algorithm byte
    /// falls back to `None` instead of discarding the reading.
    func testGlucoseRxMasksFlagNibbleAndFallsBackToNoneForUnknownState() throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x31
        bytes[1] = 0x81
        bytes[10] = 0x2C
        bytes[11] = 0xF1
        bytes[12] = 0x17

        let message = try XCTUnwrap(GlucoseDataRxMessage(data: Data(bytes)))

        XCTAssertEqual(message.transmitterStatus, 0x81)
        XCTAssertEqual(message.calculatedValue, 300)
        XCTAssertEqual(message.algorithmStatus, DexcomAlgorithmState.None)
    }

    func testGlucoseRxRejectsShortPacketAndG6Opcode() {
        XCTAssertNil(GlucoseDataRxMessage(data: packet([0x31], [UInt8](repeating: 0, count: 12))))
        XCTAssertNil(GlucoseDataRxMessage(data: packet([0x4F], [UInt8](repeating: 0, count: 15))))
    }

    // MARK: - G6 glucose (0x4F)

    /// Sequence and timestamp are 32-bit little-endian; the timestamp is relative to the
    /// transmitter start that the caller supplies.
    func testG6GlucoseDecodesSequenceTimestampValueAndState() throws {
        let data = packet([0x4F, 0x00], le32(0x0102_0304), le32(86_400), [0x96, 0x00, 0x07, 0x00, 0x00, 0x00])

        let message = try XCTUnwrap(DexcomG6GlucoseDataRxMessage(data: data, transmitterStartDate: transmitterStart))

        XCTAssertEqual(message.sequenceNumber, 0x0102_0304)
        XCTAssertEqual(message.timeStamp, transmitterStart.addingTimeInterval(86_400))
        XCTAssertEqual(message.calculatedValue, 150)
        XCTAssertEqual(message.algorithmStatus, .needsCalibration)
    }

    /// The timestamp field is signed, so a reading just before the transmitter start (as seen
    /// after a clock adjustment) is placed before it rather than about 136 years later.
    func testG6GlucoseNegativeRelativeTimeIsBeforeTransmitterStart() throws {
        let data = packet([0x4F, 0x00], le32(1), le32(UInt32(bitPattern: -10)), [0x64, 0x00, 0x06, 0x00, 0x00, 0x00])

        let message = try XCTUnwrap(DexcomG6GlucoseDataRxMessage(data: data, transmitterStartDate: transmitterStart))

        XCTAssertEqual(message.timeStamp, transmitterStart.addingTimeInterval(-10))
    }

    /// The value is twelve bits wide: all flag bits set still give at most 4095.
    func testG6GlucoseValueIsLimitedToTwelveBits() throws {
        let data = packet([0x4F, 0x00], le32(1), le32(300), [0xFF, 0xFF, 0x30, 0x00, 0x00, 0x00])

        let message = try XCTUnwrap(DexcomG6GlucoseDataRxMessage(data: data, transmitterStartDate: transmitterStart))

        XCTAssertEqual(message.calculatedValue, 4095)
        XCTAssertEqual(message.algorithmStatus, DexcomAlgorithmState.None)
    }

    func testG6GlucoseRejectsShortPacketAndG5Opcode() {
        let valid = [UInt8](packet([0x4F, 0x00], le32(1), le32(300), [0x64, 0x00, 0x06, 0x00, 0x00, 0x00]))
        XCTAssertNil(DexcomG6GlucoseDataRxMessage(data: Data(valid.prefix(15)), transmitterStartDate: transmitterStart))
        XCTAssertNil(DexcomG6GlucoseDataRxMessage(data: packet([0x31], Array(valid.dropFirst())), transmitterStartDate: transmitterStart))
    }

    // MARK: - backfill (0x51)

    func testGlucoseBackfillRxDecodesIdentifiersAndWindow() throws {
        let data = packet([0x51, 0x00, 0x01, 0x07], le32(1000), le32(4000), [UInt8](repeating: 0, count: 8))

        let message = try XCTUnwrap(GlucoseBackfillRxMessage(data: data, transmitterStartDate: transmitterStart))

        XCTAssertEqual(message.transmitterStatus, 0)
        XCTAssertEqual(message.backFillStatus, 1)
        XCTAssertEqual(message.backFillIdentifier, 7)
        XCTAssertEqual(message.backFillStartTimeStamp, transmitterStart.addingTimeInterval(1000))
        XCTAssertEqual(message.backFillEndTimeStamp, transmitterStart.addingTimeInterval(4000))
    }

    /// The request opcode 0x50 must never be decoded as the response.
    func testGlucoseBackfillRxRejectsShortPacketAndRequestOpcode() {
        let valid = [UInt8](packet([0x51, 0x00, 0x01, 0x07], le32(1000), le32(4000), [UInt8](repeating: 0, count: 8)))
        XCTAssertNil(GlucoseBackfillRxMessage(data: Data(valid.prefix(19)), transmitterStartDate: transmitterStart))
        XCTAssertNil(GlucoseBackfillRxMessage(data: packet([0x50], Array(valid.dropFirst())), transmitterStartDate: transmitterStart))
    }

    // MARK: - sensor data (0x2F)

    /// The unfiltered raw value is an unsigned 32-bit field: a high bit must not turn negative.
    func testSensorDataReadsUnfilteredAsUnsigned() throws {
        let data = packet([0x2F, 0x00], le32(0), le32(0), le32(0x8000_0001)).appendingCRC()

        let message = try XCTUnwrap(SensorDataRxMessage(data: data))

        XCTAssertEqual(message.unfiltered, 2_147_483_649)
    }

    func testSensorDataRejectsBadCRCAndShortPacket() {
        var data = packet([0x2F, 0x00], le32(0), le32(0), le32(123_456)).appendingCRC()
        data[data.count - 1] ^= 0x01
        XCTAssertNil(SensorDataRxMessage(data: data))
        XCTAssertNil(SensorDataRxMessage(data: packet([0x2F, 0x00], le32(0), le32(0)).appendingCRC()))
    }

    // MARK: - transmitter version (0x4B)

    /// The expiry is little-endian at bytes 13-14; only exactly 180 days identifies Anubis.
    func testTransmitterVersionFormatsFirmwareAndDetectsAnubisFromExpiry() throws {
        func version(expiry: UInt16) -> TransmitterVersionRxMessage? {
            TransmitterVersionRxMessage(data: packet([0x4B, 0x00, 1, 6, 5, 27], [UInt8](repeating: 0, count: 7), le16(expiry), [0, 0]).appendingCRC())
        }

        let standard = try XCTUnwrap(version(expiry: 90))
        XCTAssertEqual(standard.firmwareVersionFormatted(), "1.6.5.27")
        XCTAssertEqual(standard.transmitterExpiryInDays, 90)
        XCTAssertFalse(standard.isAnubis())

        XCTAssertTrue(try XCTUnwrap(version(expiry: 180)).isAnubis())
        XCTAssertFalse(try XCTUnwrap(version(expiry: 0x01B4)).isAnubis(), "436 days shares its low byte with 180")
    }

    /// The parser accepts only the exact 19-byte frame, even when the CRC is valid.
    func testTransmitterVersionRequiresExactLength() {
        XCTAssertNil(TransmitterVersionRxMessage(data: packet([0x4B], [UInt8](repeating: 0, count: 15)).appendingCRC()))
        XCTAssertNil(TransmitterVersionRxMessage(data: packet([0x4B], [UInt8](repeating: 0, count: 17)).appendingCRC()))
        XCTAssertNil(TransmitterVersionRxMessage(data: packet([0x4A], [UInt8](repeating: 0, count: 16)).appendingCRC()))
        XCTAssertNotNil(TransmitterVersionRxMessage(data: packet([0x4B], [UInt8](repeating: 0, count: 16)).appendingCRC()))
    }

    // MARK: - authentication

    /// Only status 0x01 means authenticated and only 0x02 means "not paired"; every other byte
    /// keeps the opposite meaning, so the pairing flow is not started by unknown values.
    func testAuthChallengeFlagsDependOnExactStatusBytes() {
        for value: UInt8 in [0x00, 0x01, 0x02, 0x03, 0xFF] {
            let message = AuthChallengeRxMessage(data: Data([0x05, value, value]))
            XCTAssertEqual(message?.authenticated, value == 0x01, "authenticated byte \(value)")
            XCTAssertEqual(message?.paired, value != 0x02, "paired byte \(value)")
        }
        XCTAssertNil(AuthChallengeRxMessage(data: Data([0x05, 0x01])))
        XCTAssertNil(AuthChallengeRxMessage(data: Data([0x03, 0x01, 0x01])))
    }

    /// Extra trailing bytes are ignored; the token hash and challenge are each eight bytes.
    func testAuthRequestRxIgnoresTrailingBytesAndRejectsShortOrOtherOpcode() throws {
        let payload = (1...16).map { UInt8($0) }

        let message = try XCTUnwrap(AuthRequestRxMessage(data: packet([0x03], payload, [0xEE, 0xEE])))

        XCTAssertEqual(message.tokenHash, Data(1...8))
        XCTAssertEqual(message.challenge, Data(9...16))
        XCTAssertNil(AuthRequestRxMessage(data: packet([0x03], Array(payload.dropLast()))))
        XCTAssertNil(AuthRequestRxMessage(data: packet([0x05], payload)))
    }

    func testResetRxDecodesStatusAndRejectsRequestOpcode() {
        XCTAssertEqual(ResetRxMessage(data: Data([0x43, 0x02]))?.status, 2)
        XCTAssertNil(ResetRxMessage(data: Data([0x43])))
        XCTAssertNil(ResetRxMessage(data: Data([0x42, 0x00])))
    }

    // MARK: - calibration (0x35)

    /// `35 00 00 552e` is the captured transmitter answer documented in the parser. It must pass
    /// the CRC check and decode as an accepted calibration.
    func testCapturedCalibrationResponseIsValidAndAccepted() throws {
        let data = try XCTUnwrap(Data(hexadecimalString: "350000552e"))

        XCTAssertTrue(data.isCRCValid)
        let message = try XCTUnwrap(DexcomCalibrationRxMessage(data: data))
        XCTAssertEqual(message.type, .okay)
        XCTAssertTrue(message.accepted)
    }

    /// A response byte that is not a known type must not count as accepted.
    func testCalibrationResponseUnknownOrRejectingTypesAreNotAccepted() {
        let unknown = DexcomCalibrationRxMessage(data: Data([0x35, 0x00, 0x07]))
        XCTAssertNotNil(unknown)
        XCTAssertNil(unknown?.type)
        XCTAssertEqual(unknown?.accepted, false)

        for type: DexcomCalibrationResponseType in [.codeOne, .rejected, .sensorStopped, .notReady, .unableToDecode] {
            XCTAssertEqual(DexcomCalibrationRxMessage(data: Data([0x35, 0x00, type.rawValue]))?.accepted, false, type.description)
        }
        XCTAssertEqual(DexcomCalibrationRxMessage(data: Data([0x35, 0x00, 0x0D]))?.accepted, true)
    }

    func testCalibrationResponseRejectsShortPacketAndRequestOpcode() {
        XCTAssertNil(DexcomCalibrationRxMessage(data: Data([0x35, 0x00])))
        XCTAssertNil(DexcomCalibrationRxMessage(data: Data([0x34, 0x00, 0x00])))
    }

    // MARK: - session start (0x27) and stop (0x29)

    /// The three clocks are unsigned 32-bit seconds; session and requested start are relative to
    /// the transmitter start derived from the current transmitter time.
    func testSessionStartRxDecodesClocksRelativeToTransmitterStart() throws {
        let data = packet([0x27, 0x00, 0x01], le32(100), le32(200), le32(5000)).appendingCRC()

        let message = try XCTUnwrap(DexcomSessionStartRxMessage(data: data))

        XCTAssertEqual(message.sessionStartResponse, .manualCalibrationSessionStarted)
        XCTAssertEqual(message.requestedStartTime, 100)
        XCTAssertEqual(message.sessionStartTime, 200)
        XCTAssertEqual(message.transmitterTime, 5000)
        XCTAssertEqual(message.sessionStartDate.timeIntervalSince(message.transmitterStartDate), 200, accuracy: 0.001)
        XCTAssertEqual(message.requestedStartDate.timeIntervalSince(message.transmitterStartDate), 100, accuracy: 0.001)
        XCTAssertEqual(message.transmitterStartDate.timeIntervalSinceNow, -5000, accuracy: 5)
    }

    /// Response bytes outside the known set make the whole message invalid.
    func testSessionStartRxRejectsResponseOutsideKnownRange() {
        for response: UInt8 in [0x00, 0x07, 0xFF] {
            XCTAssertNil(DexcomSessionStartRxMessage(data: packet([0x27, 0x00, response], le32(1), le32(2), le32(3))), "response \(response)")
        }
        XCTAssertNotNil(DexcomSessionStartRxMessage(data: packet([0x27, 0x00, 0x06], le32(1), le32(2), le32(3))))
    }

    /// The stop time is at bytes 3-6 and the transmitter time at 11-14; `isOkay` follows the
    /// status byte, independent of the response code.
    func testSessionStopRxDecodesResponseStopDateAndStatus() throws {
        let data = packet([0x29, 0x00, 0x02], le32(7200), le32(0xFFFF_FFFF), le32(9000))

        let message = try XCTUnwrap(DexcomSessionStopRxMessage(data: data))

        XCTAssertEqual(message.sessionStopResponse, .noSessionInProgress)
        XCTAssertTrue(message.isOkay)
        XCTAssertEqual(message.sessionStopTime, 7200)
        XCTAssertEqual(message.transmitterTime, 9000)
        XCTAssertEqual(message.sessionStopDate.timeIntervalSince(message.transmitterStartDate), 7200, accuracy: 0.001)

        let failed = DexcomSessionStopRxMessage(data: packet([0x29, 0x01, 0x01], le32(1), le32(0), le32(2)))
        XCTAssertEqual(failed?.isOkay, false)
    }

    func testSessionStopRxRejectsUnknownResponseShortPacketAndStartOpcode() {
        XCTAssertNil(DexcomSessionStopRxMessage(data: packet([0x29, 0x00, 0x04], le32(1), le32(0), le32(2))))
        XCTAssertNil(DexcomSessionStopRxMessage(data: packet([0x29, 0x00, 0x01], le32(1), le32(0), [0, 0, 0])))
        XCTAssertNil(DexcomSessionStopRxMessage(data: packet([0x27, 0x00, 0x01], le32(1), le32(0), le32(2))))
    }

    // MARK: - G7 glucose (0x4E)

    /// The sample packet from the field layout comment in `G7GlucoseMessage`:
    /// `4e 00 d5070000 0900 00 01 0500 6100 06 01 ffff 0e`.
    func testG7GlucoseDecodesDocumentedSamplePacket() throws {
        let data = try XCTUnwrap(Data(hexadecimalString: "4e00d5070000090000010500610006" + "01ffff0e"))

        let message = try XCTUnwrap(G7GlucoseMessage(data: data, receivedAt: receivedAt))

        XCTAssertEqual(message.responseStatus, 0)
        XCTAssertEqual(message.transmitterTime, 2005)
        XCTAssertEqual(message.messageAge, 5)
        XCTAssertEqual(message.sensorAge, 2000)
        XCTAssertEqual(message.timeStamp, receivedAt.addingTimeInterval(-5))
        XCTAssertEqual(message.calculatedValue, 97)
        XCTAssertEqual(message.algorithmStatus, .okay)
    }

    /// The age is two bytes wide; the high byte matters for old cached records.
    func testG7GlucoseAgeUsesBothBytes() throws {
        let data = packet([0x4E, 0x00], le32(1000), le16(9), [0x00, 0x00], le16(0x0102), le16(120), [0x06, 0x00], le16(0xFFFF), [0x00])

        let message = try XCTUnwrap(G7GlucoseMessage(data: data, receivedAt: receivedAt))

        XCTAssertEqual(message.messageAge, 258)
        XCTAssertEqual(message.sensorAge, 742)
        XCTAssertEqual(message.timeStamp, receivedAt.addingTimeInterval(-258))
    }

    /// An age equal to the transmitter clock is the boundary that is still accepted (age 0).
    func testG7GlucoseAcceptsAgeEqualToTransmitterTime() throws {
        let data = packet([0x4E, 0x00], le32(300), le16(1), [0x00, 0x00], le16(300), le16(110), [0x02, 0x7F], le16(0xFFFF), [0x00])

        let message = try XCTUnwrap(G7GlucoseMessage(data: data, receivedAt: receivedAt))

        XCTAssertEqual(message.sensorAge, 0)
        XCTAssertEqual(message.algorithmStatus, .SensorWarmup)
    }

    /// A failed sensor answers with a non-zero status and SensorFailed8 (0x1B) while keeping its
    /// last value. The parser must keep both so the transmitter can raise a terminal alert
    /// without publishing the stale value.
    func testG7FailedSensorFrameKeepsCachedValueAndReportsTerminalHealth() throws {
        let data = packet([0x4E, 0x80], le32(500_000), le16(3), [0x00, 0x00], le16(3600), le16(88), [0x1B, 0x00], le16(90), [0x00])

        let message = try XCTUnwrap(G7GlucoseMessage(data: data, receivedAt: receivedAt))

        XCTAssertEqual(message.responseStatus, 0x80)
        XCTAssertEqual(message.calculatedValue, 88)
        XCTAssertEqual(message.algorithmStatus, .SensorFailed8)
        XCTAssertEqual(message.algorithmStatus.sensorHealthEvent, .terminal(source: .dexcom, reason: .dexcomSensorFailure))
    }

    // MARK: - G7 backfill

    /// The sample record from the layout comment in `DexcomG7BackfillMessage`
    /// (`45a100 00 9600 06 0f fc`) is anchored to the sensor start, not to the receipt time,
    /// so history received late does not shift.
    func testG7BackfillDecodesDocumentedSampleRelativeToSensorStart() throws {
        let sensorStart = Date(timeIntervalSince1970: 1_799_900_000)
        let data = try XCTUnwrap(Data(hexadecimalString: "45a10000960006" + "0ffc"))

        let message = try XCTUnwrap(DexcomG7BackfillMessage(data: data, sensorStartDate: sensorStart))

        XCTAssertEqual(message.timeStamp, sensorStart.addingTimeInterval(41_285))
        XCTAssertEqual(message.calculatedValue, 150)
    }

    /// Flag bits in the upper nibble of the glucose are removed, so a display-only record keeps
    /// its value; the unavailable sentinel yields zero instead of 4095.
    func testG7BackfillMasksFlagBitsAndMapsUnavailableToZero() throws {
        let sensorStart = Date(timeIntervalSince1970: 0)

        let flagged = try XCTUnwrap(DexcomG7BackfillMessage(data: packet(le32(600), le16(0xF0C8), [0x06, 0x00, 0x7F]), sensorStartDate: sensorStart))
        let unavailable = try XCTUnwrap(DexcomG7BackfillMessage(data: packet(le32(600), le16(0xFFFF), [0x06, 0x00, 0x7F]), sensorStartDate: sensorStart))

        XCTAssertEqual(flagged.calculatedValue, 200)
        XCTAssertEqual(unavailable.calculatedValue, 0)
        XCTAssertEqual(unavailable.timeStamp, flagged.timeStamp)
    }

    // MARK: - session start response colours

    /// The status screen stores only the description string; the colour must be recoverable
    /// from it for every response, and unknown text must not get a colour.
    func testSessionStartResponseColorIsRecoverableFromItsDescription() {
        for response in DexcomSessionStartResponse.allCases {
            XCTAssertEqual(DexcomSessionStartResponse.indicatorColor(forDescription: response.description), response.indicatorColor, response.description)
        }
        XCTAssertEqual(DexcomSessionStartResponse.indicatorColor(forDescription: "transmitter end of life"), .red)
        XCTAssertNil(DexcomSessionStartResponse.indicatorColor(forDescription: "OK / Calibrated"))
    }

    // MARK: - G7 version and lifetime

    /// Newer firmware may append fields after the serial number; the known prefix still decodes.
    func testG7VersionAcceptsLongerResponse() throws {
        let data = packet([0x4A, 0x00, 1, 2, 3, 4], le32(0xDEAD_BEEF), le32(42), [0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA], [0x99, 0x99])

        let message = try XCTUnwrap(DexcomG7VersionMessage(data: data))

        XCTAssertEqual(message.firmwareVersion, "1.2.3.4")
        XCTAssertEqual(message.buildVersion, 0xDEAD_BEEF)
        XCTAssertEqual(message.versionCode, 42)
        XCTAssertEqual(message.serialNumber, 0xAABB_CCDD_EEFF)
    }

    /// A 15.5-day session length read from the extended version packet must be recognised by
    /// the lifetime rules, while the separate `maxLifetimeDays` field is not the session length.
    func testG7ExtendedVersionSessionLengthDrivesSensorLifetime() throws {
        let fifteenAndAHalfDays: UInt32 = 1_339_200
        let data = packet([0x52, 0x00], le32(fifteenAndAHalfDays), le16(3600), le32(7), [0x02], le16(17))

        let message = try XCTUnwrap(DexcomG7ExtendedVersionMessage(data: data))

        XCTAssertEqual(message.maxLifetimeDays, 17)
        XCTAssertEqual(message.warmupDuration, 3600)
        XCTAssertEqual(DexcomG7SensorLifetime.diagnosticDescription(message.sessionLength), "15-day sensor (+ 12-hour grace period)")
        XCTAssertEqual(DexcomG7SensorLifetime.maximumSensorAgeInDays(reportedSessionLength: message.sessionLength, deviceName: "DXCM12"), 15.5)
        XCTAssertNil(DexcomG7SensorLifetime.supportedSessionLength(TimeInterval(message.maxLifetimeDays) * 86_400))
    }

    // MARK: - algorithm state

    /// `SensorFailed8` and `sensorFailed` share their user-facing text, so the lookup by
    /// description (used for persisted status strings) must still resolve to red.
    func testSharedSensorFailedDescriptionResolvesToRed() {
        XCTAssertEqual(DexcomAlgorithmState.SensorFailed8.description, DexcomAlgorithmState.sensorFailed.description)
        XCTAssertEqual(DexcomAlgorithmState.indicatorColor(forDescription: "Sensor failed"), .red)
        XCTAssertNil(DexcomAlgorithmState.indicatorColor(forDescription: "sensor failed"))
    }

    /// Temporary sensor problems are orange and open a recoverable warning; warmup and
    /// calibration requests are not health problems and close any open warning.
    func testTemporaryAndOperationalStatesMapToMatchingColorAndHealthEvent() {
        for state: DexcomAlgorithmState in [.excessNoise, .TemporarySensorIssue, .questionMarks] {
            XCTAssertEqual(state.indicatorColor, .orange, state.description)
            guard case .temporary(source: .dexcom, reason: _) = state.sensorHealthEvent else {
                return XCTFail("\(state) should be a temporary health event")
            }
        }
        for state: DexcomAlgorithmState in [.SensorWarmup, .FirstofTwoBGsNeeded, .okay, .needsCalibration] {
            XCTAssertEqual(state.sensorHealthEvent, .recovered(source: .dexcom), state.description)
        }
    }

    // MARK: - private functions

    /// Concatenates packet fragments; keeps long byte layouts readable and fast to type-check.
    private func packet(_ parts: [UInt8]...) -> Data {
        Data(parts.flatMap { $0 })
    }

    /// Little-endian bytes of a 16-bit value, as Dexcom transmits multibyte fields.
    private func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    /// Little-endian bytes of a 32-bit value, as Dexcom transmits multibyte fields.
    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }
}
