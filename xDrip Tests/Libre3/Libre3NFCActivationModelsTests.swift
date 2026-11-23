//
//  Libre3NFCActivationModelsTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Guards the parsing and validation of Libre 3 NFC responses (patch info and activation
/// response) and of the persisted `Libre3SensorState` built from them.
///
/// The patch info decides whether the app activates or merely switches receiver, and
/// sets warmup and wear durations; the activation response gives the BLE address and
/// PIN. A lenient parser would pair with garbage, a strict one would refuse a sensor
/// because CoreNFC framed the reply differently.
final class Libre3NFCActivationModelsTests: XCTestCase {

    // MARK: - fixtures

    /// Live patch info of an active sensor (state 0x04), framed with the 00 a5 header.
    private let activePatchInfoHex = "00a50001000200010060541e020401040c04305252433938394151c6ca"

    /// Live activation response: BLE address 58f9b8df22cc (LE), PIN 3225ec72.
    private let activationResponseHex = "00a50058f9b8df22cc3225ec7200000000ad06"

    private func data(_ hex: String) -> Data {
        Libre3ProtocolFixtures.data(hex: hex)
    }

    // MARK: - patch info

    /// Field offsets: security version, region and generation are LE words, the firmware
    /// version is bytes 11-14 printed most significant first, warmup is byte 16 in
    /// 5-minute units and the serial number is the 9 ASCII bytes 18-26.
    func testPatchInfoDecodesEveryFieldFromSyntheticFrame() throws {
        let frame = "00a5" + "00" + "3412" + "7856" + "bc9a" + "a08c" + "04030201" + "09" + "12" + "02"
            + "414243444546474849" + "ffff"
        let info = try Libre3NFCPatchInfo(raw: data(frame))

        XCTAssertEqual(info.securityVersion, 0x1234)
        XCTAssertEqual(info.region, 0x5678)
        XCTAssertEqual(info.generation, 0x9abc)
        XCTAssertEqual(info.wearDurationMinutes, 0x8ca0)
        XCTAssertEqual(info.firmwareVersion, "1.2.3.4")
        XCTAssertEqual(info.productType, 9)
        XCTAssertEqual(info.warmupMinutes, 90)
        XCTAssertEqual(info.stateByte, 2)
        XCTAssertEqual(info.serialNumber, "ABCDEFGHI")
        XCTAssertEqual(info.recommendedCommandCode, .switchReceiver)
    }

    /// Only state 0x01 (fresh, never activated) needs the activation command; every other
    /// state is a receiver switch, so an already-running sensor is never re-activated.
    func testOnlyFreshStateRecommendsActivation() throws {
        var bytes = data(activePatchInfoHex)
        for state in [UInt8(0x00), 0x01, 0x02, 0x03, 0x04, 0x05, 0xff] {
            bytes[17] = state
            let info = try Libre3NFCPatchInfo(raw: bytes)
            XCTAssertEqual(info.recommendedCommandCode, state == 0x01 ? .activate : .switchReceiver, "state \(state)")
        }
    }

    /// The warmup byte is multiplied by 5 in 16-bit space, so the largest byte still fits.
    func testWarmupByteIsFiveMinuteUnitsUpToByteMaximum() throws {
        var bytes = data(activePatchInfoHex)
        for (raw, minutes) in [(UInt8(0), UInt16(0)), (1, 5), (12, 60), (255, 1275)] {
            bytes[16] = raw
            XCTAssertEqual(try Libre3NFCPatchInfo(raw: bytes).warmupMinutes, minutes)
        }
    }

    /// Truncated or wrongly framed replies are rejected and the error carries the original
    /// input, so the log shows what the reader actually returned.
    func testPatchInfoRejectsTruncatedOrMisframedReplies() {
        let valid = data(activePatchInfoHex)
        let cases: [(name: String, raw: Data)] = [
            ("empty", Data()),
            ("28 bytes", valid.prefix(28)),
            ("wrong first byte", Data([0x01]) + valid.dropFirst()),
            ("missing a5 marker", Data([0x00, 0x00]) + valid.dropFirst(2)),
            ("only header", Data([0x00, 0xa5])),
            ("header followed only by a5 padding", Data([0x00]) + Data(repeating: 0xa5, count: 30)),
        ]
        for c in cases {
            XCTAssertThrowsError(try Libre3NFCPatchInfo(raw: Data(c.raw)), c.name) { error in
                XCTAssertEqual(error as? Libre3NFCError, .invalidPatchInfo(Data(c.raw)), c.name)
            }
        }
    }

    /// CoreNFC can strip the leading 00 and repeat the a5 marker; both quirks together must
    /// still normalise to the canonical frame.
    func testPatchInfoNormalisesMissingLeadingZeroAndRepeatedMarker() throws {
        let raw = data("a5a5a5" + String(activePatchInfoHex.dropFirst(4)))
        let info = try Libre3NFCPatchInfo(raw: raw)

        XCTAssertEqual(info.inputRaw, raw)
        XCTAssertEqual(info.raw.hex, activePatchInfoHex)
        XCTAssertEqual(info.serialNumber, "0RRC989AQ")
        XCTAssertEqual(info.wearDurationMinutes, 21600)
    }

    /// Trailing bytes after the 29-byte body (e.g. CRC) are tolerated and kept in `raw`.
    func testPatchInfoAcceptsTrailingBytes() throws {
        let info = try Libre3NFCPatchInfo(raw: data(activePatchInfoHex + "0102"))
        XCTAssertEqual(info.raw.count, 31)
        XCTAssertEqual(info.serialNumber, "0RRC989AQ")
    }

    // MARK: - activation response

    func testActivationResponseRejectsWrongLengthOrStatus() {
        let valid = data(activationResponseHex)
        let cases: [(name: String, raw: Data)] = [
            ("empty", Data()),
            ("18 bytes with header", valid.prefix(18)),
            ("20 bytes", valid + Data([0x00])),
            ("non-zero status byte", { var d = valid; d[2] = 0x01; return d }()),
            ("wrong marker", { var d = valid; d[1] = 0xa4; return d }()),
            ("17 bytes without leading zero", Data(valid.dropFirst().prefix(17))),
        ]
        for c in cases {
            XCTAssertThrowsError(try Libre3NFCActivationResponse(raw: Data(c.raw)), c.name) { error in
                XCTAssertEqual(error as? Libre3NFCError, .invalidActivationResponse(Data(c.raw)), c.name)
            }
        }
    }

    /// The BLE address is sent little-endian and displayed big-endian, upper-case,
    /// colon-separated (the format CoreBluetooth logs and the user sees).
    func testActivationResponseAddressDisplayReversesBytes() throws {
        var bytes = data(activationResponseHex)
        bytes.replaceSubrange(3..<9, with: [0x01, 0x23, 0x45, 0x67, 0x89, 0xab])
        let response = try Libre3NFCActivationResponse(raw: bytes)

        XCTAssertEqual(response.bleAddressDisplay, "AB:89:67:45:23:01")
    }

    /// When patch info is known, its warmup and wear are stored in the sensor state so
    /// that reconnects do not fall back to the default cycle.
    func testActivationResponseSensorStateCarriesPatchInfoCycle() throws {
        let response = try Libre3NFCActivationResponse(raw: data(activationResponseHex))
        let info = try Libre3NFCPatchInfo(raw: data(activePatchInfoHex))

        let withInfo = try response.sensorState(serialNumber: info.serialNumber, patchInfo: info, source: nil)
        XCTAssertEqual(withInfo.blePIN.hex, "3225ec72")
        XCTAssertEqual(withInfo.bleAddress, "CC:22:DF:B8:F9:58")
        XCTAssertEqual(withInfo.warmupDurationMinutes, 60)
        XCTAssertEqual(withInfo.wearDurationMinutes, 21600)
        XCTAssertNil(withInfo.source)
        XCTAssertNil(withInfo.lastGlucoseLifeCount)

        let withoutInfo = try response.sensorState(serialNumber: nil)
        XCTAssertNil(withoutInfo.warmupDurationMinutes)
        XCTAssertNil(withoutInfo.wearDurationMinutes)
        XCTAssertNil(withoutInfo.serialNumber)
    }

    // MARK: - sensor state

    /// The BLE PIN is exactly 4 bytes; anything else would fail authentication later with
    /// a far less helpful error.
    func testSensorStateRejectsBlePINOfWrongSize() {
        for size in [0, 3, 5, 16] {
            XCTAssertThrowsError(try Libre3SensorState(serialNumber: nil, blePIN: Data(count: size)), "size \(size)") { error in
                XCTAssertEqual(error as? Libre3SensorStateError, .wrongBlePINSize(size))
            }
        }
        XCTAssertNoThrow(try Libre3SensorState(serialNumber: nil, blePIN: Data(count: 4)))
    }

    func testSensorStateClampsNegativeDurations() throws {
        let state = try Libre3SensorState(serialNumber: nil, blePIN: Data(count: 4), warmupDurationMinutes: -1, wearDurationMinutes: -100)
        XCTAssertEqual(state.warmupDurationMinutes, 0)
        XCTAssertEqual(state.wearDurationMinutes, 0)
    }

    /// Each "updating" copy changes only its own fields and keeps everything else,
    /// including the receiver ID needed to reconnect.
    func testSensorStateCopiesChangeOnlyTheirOwnFields() throws {
        let original = try Libre3SensorState(
            serialNumber: "0RRC989AQ", blePIN: Data([9, 8, 7, 6]), bleAddress: "CC:22:DF:B8:F9:58",
            receiverID: Libre3ReceiverID(0x6f0d8378), source: "test",
            lastGlucoseLifeCount: 10, lastGlucoseMgDL: 100,
            warmupDurationMinutes: 60, wearDurationMinutes: 21600
        )

        let glucose = try original.updatingLastGlucose(lifeCount: 20, mgDL: nil)
        XCTAssertEqual(glucose.lastGlucoseLifeCount, 20)
        XCTAssertNil(glucose.lastGlucoseMgDL)
        XCTAssertEqual(glucose.receiverID, original.receiverID)
        XCTAssertEqual(glucose.bleAddress, original.bleAddress)
        XCTAssertEqual(glucose.source, "test")
        XCTAssertEqual(glucose.wearDurationMinutes, 21600)

        var patchInfoBytes = data(activePatchInfoHex)
        patchInfoBytes[16] = 6
        patchInfoBytes.replaceSubrange(9..<11, with: [0x40, 0x38])
        let cycle = try original.applyingSensorCycle(from: Libre3NFCPatchInfo(raw: patchInfoBytes))
        XCTAssertEqual(cycle.warmupDurationMinutes, 30)
        XCTAssertEqual(cycle.wearDurationMinutes, 14400)
        XCTAssertEqual(cycle.lastGlucoseLifeCount, 10)
        XCTAssertEqual(cycle.lastGlucoseMgDL, 100)
        XCTAssertEqual(cycle.blePIN, original.blePIN)
    }

    // MARK: - errors

    /// Error descriptions go to the troubleshooting log and must never contain the raw
    /// bytes (which include the BLE PIN), only their size and the sensor state.
    func testNFCErrorDescriptionsLogSizesNotContents() throws {
        let info = try Libre3NFCPatchInfo(raw: data(activePatchInfoHex))
        let response = data(activationResponseHex)

        XCTAssertEqual(Libre3NFCError.invalidActivationResponse(response).description, "invalidActivationResponse(19 bytes)")
        XCTAssertEqual(Libre3NFCError.invalidPatchInfo(Data(count: 3)).description, "invalidPatchInfo(3 bytes)")
        XCTAssertEqual(
            Libre3NFCError.invalidActivationResponseForPatch(commandCode: .switchReceiver, patchInfo: info, raw: response).description,
            "invalidActivationResponse(command=\(Libre3NFCActivationCommandCode.switchReceiver.rawValue), state=4, bytes=19)"
        )
        XCTAssertEqual(Libre3NFCError.unexpectedSensorState(patchInfo: info).description, "unexpectedSensorState(4)")
        XCTAssertEqual(
            [Libre3NFCError.readerUnavailable, .sessionAlreadyActive, .noTag, .multipleTags, .nonISO15693Tag].map(\.description),
            ["readerUnavailable", "sessionAlreadyActive", "noTag", "multipleTags", "nonISO15693Tag"]
        )
        XCTAssertFalse(Libre3NFCError.invalidActivationResponse(response).description.contains("3225ec72"))
    }
}
