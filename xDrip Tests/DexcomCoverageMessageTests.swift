//
//  DexcomCoverageMessageTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class DexcomCoverageMessageTests: XCTestCase {
    private let transmitterStart = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - CRC

    func testCRC16MatchesCCITTXModemCheckValue() {
        XCTAssertEqual(Array("123456789".utf8).crc16, 0x31C3)
        XCTAssertEqual([UInt8]().crc16, 0)
        XCTAssertEqual(UInt8(0x22).crc16, 0x0420)
        XCTAssertEqual(UInt8(0x24).crc16, 0x64E6)
    }

    func testAppendingCRCAppendsLittleEndianChecksumAndValidates() {
        let framed = Data([0x24]).appendingCRC()
        XCTAssertEqual(framed, Data([0x24, 0xE6, 0x64]))
        XCTAssertTrue(framed.isCRCValid)
        var corrupted = framed
        corrupted[1] ^= 0x01
        XCTAssertFalse(corrupted.isCRCValid)
    }

    func testCRCValidationWorksOnSlicedData() {
        let payload = Data([0xAA, 0xBB] + Array(Data([0x31, 0x02, 0x03]).appendingCRC()))
        XCTAssertTrue(payload.dropFirst(2).isCRCValid)
    }

    // MARK: - Opcodes

    func testEveryOpcodeHasUniqueDescriptionAndRoundTripsThroughData() {
        var descriptions = Set<String>()
        var count = 0
        for raw in 0...255 {
            guard let opCode = DexcomTransmitterOpCode(rawValue: UInt8(raw)) else { continue }
            count += 1
            XCTAssertFalse(opCode.description.isEmpty)
            XCTAssertTrue(descriptions.insert(opCode.description).inserted, "duplicate \(opCode.description)")
            let data = Data(for: opCode)
            XCTAssertEqual(data, Data([UInt8(raw)]))
            XCTAssertTrue(data.starts(with: opCode))
        }
        XCTAssertEqual(count, 43)
    }

    func testStartsWithOpcodeRejectsEmptyAndOtherOpcodes() {
        XCTAssertFalse(Data().starts(with: .glucoseRx))
        XCTAssertFalse(Data([0x30]).starts(with: .glucoseRx))
        XCTAssertTrue(Data([0x31, 0x00]).dropFirst(0).starts(with: .glucoseRx))
    }

    func testSelectedOpcodeRawValuesMatchProtocol() {
        XCTAssertEqual(DexcomTransmitterOpCode.authRequestTx.rawValue, 0x01)
        XCTAssertEqual(DexcomTransmitterOpCode.glucoseG6Tx.rawValue, 0x4E)
        XCTAssertEqual(DexcomTransmitterOpCode.extendedVersion.rawValue, 0x52)
        XCTAssertEqual(DexcomTransmitterOpCode.backfillFinished.rawValue, 0x59)
        XCTAssertEqual(DexcomTransmitterOpCode.keepAliveRx.rawValue, 0xFF)
        XCTAssertEqual(DexcomTransmitterOpCode.keepAliveRx.description, "keepAliveRx")
    }

    // MARK: - Simple Tx messages

    func testFixedCommandTxMessagesAreOpcodePlusCRC() {
        XCTAssertEqual(BatteryStatusTxMessage().data, Data([0x22, 0x20, 0x04]))
        XCTAssertEqual(BatteryStatusTxMessage().opcode, .batteryStatusTx)
        XCTAssertEqual(DexcomTransmitterTimeTxMessage().data, Data([0x24, 0xE6, 0x64]))
        XCTAssertEqual(DexcomTransmitterTimeTxMessage().opcode, .transmitterTimeTx)
        XCTAssertEqual(DexcomGlucoseDataTxMessage().data, Data([0x30, 0x53, 0x36]))
        XCTAssertEqual(ResetTxMessage().data, Data([0x42, 0x86, 0x68]))
        for data in [TransmitterVersionTxMessage().data, SensorDataTxMessage().data] {
            XCTAssertEqual(data.count, 3)
            XCTAssertTrue(data.isCRCValid)
        }
        XCTAssertEqual(TransmitterVersionTxMessage().data.first, 0x4A)
        XCTAssertEqual(TransmitterVersionTxMessage().opcode, .transmitterVersionTx)
        XCTAssertEqual(SensorDataTxMessage().data.first, 0x2E)
        XCTAssertEqual(FirmwareVersionTxMessage().opcode, .firmwareVersionTx)
    }

    func testKeepAlivePairAndChallengeTxMessagesHaveNoCRC() {
        XCTAssertEqual(KeepAliveTxMessage(time: 25).data, Data([0x06, 25]))
        XCTAssertEqual(PairRequestTxMessage().data, Data([0x07]))
        let hash = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(AuthChallengeTxMessage(challengeHash: hash).data, Data([0x04]) + hash)
    }

    func testAuthRequestTokensAreRandomAndEightBytes() {
        let first = AuthRequestTxMessage()
        let second = AuthRequestTxMessage()
        XCTAssertEqual(first.singleUseToken.count, 8)
        XCTAssertNotEqual(first.singleUseToken, second.singleUseToken)
        XCTAssertEqual(first.data.subdata(in: 1..<9), first.singleUseToken)
        XCTAssertEqual(first.slot, .mobileApp)
    }

    func testG7BluetoothSlotRawValuesAndDefault() {
        XCTAssertEqual(DexcomG7BluetoothSlot.defaultSlot, .mobileApp)
        XCTAssertEqual(DexcomG7BluetoothSlot.allCases.map(\.rawValue).sorted(), [1, 2, 3])
        XCTAssertEqual(DexcomG7BluetoothSlot(rawValue: 3), .smartWatch)
        XCTAssertNil(DexcomG7BluetoothSlot(rawValue: 4))
        XCTAssertEqual(DexcomG6BluetoothSlot.medicalDevice.normalized(isAnubis: false), .medicalDevice)
    }

    // MARK: - Time-based Tx messages

    func testBackfillTxMessageWidensWindowByFiveMinutesAndAppendsCRC() {
        let start = transmitterStart.addingTimeInterval(10_000)
        let end = transmitterStart.addingTimeInterval(20_000)
        let data = DexcomBackfillTxMessage(startTime: start, endTime: end, transmitterStartDate: transmitterStart).data
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x05, 0x02, 0x00])
        XCTAssertEqual(data.subdata(in: 4..<8).to(UInt32.self), 9_700)
        XCTAssertEqual(data.subdata(in: 8..<12).to(UInt32.self), 20_300)
        XCTAssertEqual(Array(data.subdata(in: 12..<18)), [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(data.isCRCValid)
    }

    func testCalibrationTxMessageEncodesGlucoseAndRelativeTime() {
        let data = DexcomCalibrationTxMessage(glucose: 0x0123, timeStamp: transmitterStart.addingTimeInterval(0x01020304), transmitterStartDate: transmitterStart).data
        XCTAssertEqual(Array(data.prefix(7)), [0x34, 0x23, 0x01, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(data.count, 9)
        XCTAssertTrue(data.isCRCValid)
    }

    func testSessionStartTxMessageWithoutCodeOmitsCalibrationParameters() throws {
        let params = try XCTUnwrap(DexcomCalibrationParameters(sensorCode: nil))
        let startDate = transmitterStart.addingTimeInterval(86_400)
        let data = DexcomSessionStartTxMessage(startDate: startDate, transmitterStartDate: transmitterStart, dexcomCalibrationParameters: params).data
        XCTAssertEqual(data.count, 11)
        XCTAssertEqual(data.first, 0x26)
        XCTAssertEqual(data.subdata(in: 1..<5).to(UInt32.self), 86_400)
        XCTAssertEqual(data.subdata(in: 5..<9).to(UInt32.self), UInt32(startDate.timeIntervalSince1970))
        XCTAssertTrue(data.isCRCValid)
    }

    func testSessionStartTxMessageWithCodeAppendsBothParameters() throws {
        let params = try XCTUnwrap(DexcomCalibrationParameters(sensorCode: "5915"))
        let data = DexcomSessionStartTxMessage(startDate: transmitterStart.addingTimeInterval(60), transmitterStartDate: transmitterStart, dexcomCalibrationParameters: params).data
        XCTAssertEqual(data.count, 15)
        XCTAssertEqual(data.subdata(in: 9..<11).to(UInt16.self), 3100)
        XCTAssertEqual(data.subdata(in: 11..<13).to(UInt16.self), 3600)
        XCTAssertTrue(data.isCRCValid)
    }

    func testSessionStopTxMessageEncodesRelativeStopTime() {
        let stopDate = transmitterStart.addingTimeInterval(500_000)
        let message = DexcomSessionStopTxMessage(stopDate: stopDate, transmitterStartDate: transmitterStart)
        XCTAssertEqual(message.stopDate, stopDate)
        XCTAssertEqual(message.data.count, 7)
        XCTAssertEqual(message.data.first, 0x28)
        XCTAssertEqual(message.data.subdata(in: 1..<5).to(UInt32.self), 500_000)
        XCTAssertTrue(message.data.isCRCValid)
    }

    // MARK: - Calibration parameters

    func testCalibrationParametersCoverEveryKnownCode() {
        let table: [(String, Int16, Int16)] = [
            ("0000", 0, 0), ("5915", 3100, 3600), ("9759", 3100, 3600), ("5917", 3000, 3500), ("9357", 3000, 3500),
            ("5931", 2900, 3400), ("9137", 2900, 3400), ("5937", 2800, 3300), ("7197", 2800, 3300),
            ("5951", 3100, 3500), ("9517", 3100, 3500), ("5955", 3000, 3400), ("9179", 3000, 3400),
            ("7171", 2700, 3300), ("7539", 2700, 3300), ("9117", 2700, 3200), ("7135", 2700, 3200),
            ("9159", 2600, 3200), ("5397", 2600, 3200), ("9311", 2600, 3100), ("5391", 2600, 3100),
            ("9371", 2500, 3100), ("5375", 2500, 3100), ("9515", 2500, 3000), ("5795", 2500, 3000),
            ("9551", 2400, 3000), ("5317", 2400, 3000), ("9577", 2400, 2900), ("5177", 2400, 2900),
            ("9713", 2300, 2900), ("5171", 2300, 2900),
        ]
        for (code, p1, p2) in table {
            let params = DexcomCalibrationParameters(sensorCode: code)
            XCTAssertEqual(params?.parameter1, p1, code)
            XCTAssertEqual(params?.parameter2, p2, code)
        }
    }

    func testCalibrationParametersRejectUnknownCodes() {
        for code in ["1234", "", "59150", "abcd"] {
            XCTAssertNil(DexcomCalibrationParameters(sensorCode: code), code)
        }
        XCTAssertEqual(DexcomCalibrationParameters(sensorCode: nil)?.parameter1, 0)
    }

    // MARK: - Auth Rx messages

    func testAuthChallengeRxDecodesAuthenticatedAndPairedFlags() {
        let ok = AuthChallengeRxMessage(data: Data([0x05, 0x01, 0x01]))
        XCTAssertEqual(ok?.authenticated, true)
        XCTAssertEqual(ok?.paired, true)
        let unpaired = AuthChallengeRxMessage(data: Data([0x05, 0x00, 0x02]))
        XCTAssertEqual(unpaired?.authenticated, false)
        XCTAssertEqual(unpaired?.paired, false)
        XCTAssertNil(AuthChallengeRxMessage(data: Data([0x05, 0x01])))
        XCTAssertNil(AuthChallengeRxMessage(data: Data([0x03, 0x01, 0x01])))
    }

    func testAuthRequestRxSplitsTokenHashAndChallenge() {
        let bytes: [UInt8] = [0x03] + Array(1...16)
        let message = AuthRequestRxMessage(data: Data(bytes))
        XCTAssertEqual(message?.tokenHash, Data(Array(1...8)))
        XCTAssertEqual(message?.challenge, Data(Array(9...16)))
        XCTAssertNil(AuthRequestRxMessage(data: Data(bytes.dropLast())))
        XCTAssertNil(AuthRequestRxMessage(data: Data([0x05] + Array(1...16))))
    }

    // MARK: - Battery / version / reset / sensor data

    func testBatteryStatusRxDecodesExtendedFrame() {
        let body: [UInt8] = [0x23, 0x00, 0x3C, 0x01, 0x2C, 0x01, 0xA0, 0x05, 0x5A, 0x1E]
        let message = BatteryStatusRxMessage(data: Data(body).appendingCRC())
        XCTAssertEqual(message?.status, 0)
        XCTAssertEqual(message?.voltageA, 316)
        XCTAssertEqual(message?.voltageB, 300)
        XCTAssertEqual(message?.resist, 1440)
        XCTAssertEqual(message?.runtime, 90)
        XCTAssertEqual(message?.temperature, 30)
    }

    func testBatteryStatusRxShortFrameHasUnknownRuntime() {
        let body: [UInt8] = [0x23, 0x81, 0x3C, 0x01, 0x2C, 0x01, 0xA0, 0x05]
        let message = BatteryStatusRxMessage(data: Data(body).appendingCRC())
        XCTAssertEqual(message?.status, 0x81)
        XCTAssertEqual(message?.runtime, -1)
        XCTAssertEqual(message?.resist, 1440)
    }

    func testBatteryStatusRxRejectsBadCRCShortOrWrongOpcode() {
        var framed = Data([0x23, 0, 1, 1, 1, 1, 1, 1, 1, 1]).appendingCRC()
        framed[3] ^= 0xFF
        XCTAssertNil(BatteryStatusRxMessage(data: framed))
        XCTAssertNil(BatteryStatusRxMessage(data: Data([0x23, 0, 1]).appendingCRC()))
        XCTAssertNil(BatteryStatusRxMessage(data: Data([0x22, 0, 1, 1, 1, 1, 1, 1, 1, 1]).appendingCRC()))
    }

    func testTransmitterVersionRxDecodesFirmwareAndAnubisMarker() {
        var body: [UInt8] = [0x4B, 0x00, 1, 6, 5, 25] + Array(repeating: 0, count: 11)
        body[13] = 180
        let message = TransmitterVersionRxMessage(data: Data(body).appendingCRC())
        XCTAssertEqual(message?.firmwareVersionFormatted(), "1.6.5.25")
        XCTAssertEqual(message?.transmitterExpiryInDays, 180)
        XCTAssertEqual(message?.isAnubis(), true)
        body[13] = 90
        XCTAssertEqual(TransmitterVersionRxMessage(data: Data(body).appendingCRC())?.isAnubis(), false)
    }

    func testTransmitterVersionRxRequiresExactLengthAndValidCRC() {
        let body: [UInt8] = [0x4B, 0x00, 1, 6, 5, 25] + Array(repeating: 0, count: 11)
        XCTAssertNil(TransmitterVersionRxMessage(data: Data(body + [0]).appendingCRC()))
        var corrupted = Data(body).appendingCRC()
        corrupted[2] = 2
        XCTAssertNil(TransmitterVersionRxMessage(data: corrupted))
        var wrongOpcode = body
        wrongOpcode[0] = 0x4A
        XCTAssertNil(TransmitterVersionRxMessage(data: Data(wrongOpcode).appendingCRC()))
    }

    func testResetRxDecodesStatus() {
        XCTAssertEqual(ResetRxMessage(data: Data([0x43, 0x00]))?.status, 0)
        XCTAssertEqual(ResetRxMessage(data: Data([0x43, 0x07]))?.status, 7)
        XCTAssertNil(ResetRxMessage(data: Data([0x43])))
        XCTAssertNil(ResetRxMessage(data: Data([0x42, 0x00])))
    }

    func testSensorDataRxDecodesUnfilteredValue() {
        let body: [UInt8] = [0x2F, 0x00] + Array(repeating: 0, count: 8) + [0x00, 0xFF, 0x1F, 0x00]
        let message = SensorDataRxMessage(data: Data(body).appendingCRC())
        XCTAssertEqual(message?.status, 0)
        XCTAssertEqual(message?.unfiltered, 2_096_896)
        XCTAssertNil(SensorDataRxMessage(data: Data(body)))
        XCTAssertNil(SensorDataRxMessage(data: Data([0x2E] + body.dropFirst()).appendingCRC()))
    }

    // MARK: - Glucose

    func testGlucoseDataRxMasksTwelveBitValueAndMapsAlgorithmState() {
        var bytes: [UInt8] = [0x31, 0x00] + Array(repeating: 0, count: 8) + [0x2C, 0xF1, 0x06, 0x00]
        let message = GlucoseDataRxMessage(data: Data(bytes))
        XCTAssertEqual(message?.calculatedValue, 300)
        XCTAssertEqual(message?.algorithmStatus, .okay)
        bytes[12] = 0x77
        XCTAssertEqual(GlucoseDataRxMessage(data: Data(bytes))?.algorithmStatus, DexcomAlgorithmState.None)
        XCTAssertNil(GlucoseDataRxMessage(data: Data(bytes.prefix(13))))
        XCTAssertNil(GlucoseDataRxMessage(data: Data([0x4F] + bytes.dropFirst())))
    }

    func testG6GlucoseDataRxDecodesSequenceTimestampAndValue() {
        let bytes: [UInt8] = [0x4F, 0x00, 0x10, 0x00, 0x00, 0x00, 0x2C, 0x01, 0x00, 0x00, 0x96, 0xF0, 0x07, 0, 0, 0]
        let message = DexcomG6GlucoseDataRxMessage(data: Data(bytes), transmitterStartDate: transmitterStart)
        XCTAssertEqual(message?.sequenceNumber, 16)
        XCTAssertEqual(message?.timeStamp, transmitterStart.addingTimeInterval(300))
        XCTAssertEqual(message?.calculatedValue, 150)
        XCTAssertEqual(message?.algorithmStatus, .needsCalibration)
        XCTAssertNil(DexcomG6GlucoseDataRxMessage(data: Data(bytes.prefix(15)), transmitterStartDate: transmitterStart))
        XCTAssertNil(DexcomG6GlucoseDataRxMessage(data: Data([0x31] + bytes.dropFirst()), transmitterStartDate: transmitterStart))
    }

    func testG6GlucoseDataRxUsesHighNibbleOfSecondValueByte() {
        let bytes: [UInt8] = [0x4F, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0x01, 0xEE, 0, 0, 0]
        let message = DexcomG6GlucoseDataRxMessage(data: Data(bytes), transmitterStartDate: transmitterStart)
        XCTAssertEqual(message?.calculatedValue, 511)
        XCTAssertEqual(message?.algorithmStatus, DexcomAlgorithmState.None)
    }

    func testGlucoseBackfillRxDecodesWindow() {
        let bytes: [UInt8] = [0x51, 0x00, 0x01, 0x02, 0x10, 0x0E, 0x00, 0x00, 0x20, 0x1C, 0x00, 0x00] + Array(repeating: 0, count: 8)
        let message = GlucoseBackfillRxMessage(data: Data(bytes), transmitterStartDate: transmitterStart)
        XCTAssertEqual(message?.backFillStatus, 1)
        XCTAssertEqual(message?.backFillIdentifier, 2)
        XCTAssertEqual(message?.backFillStartTimeStamp, transmitterStart.addingTimeInterval(3600))
        XCTAssertEqual(message?.backFillEndTimeStamp, transmitterStart.addingTimeInterval(7200))
        XCTAssertNil(GlucoseBackfillRxMessage(data: Data(bytes.prefix(19)), transmitterStartDate: transmitterStart))
        XCTAssertNil(GlucoseBackfillRxMessage(data: Data([0x50] + bytes.dropFirst()), transmitterStartDate: transmitterStart))
    }

    // MARK: - Session start / stop / calibration responses

    func testSessionStartRxDecodesDatesRelativeToTransmitterStart() throws {
        var bytes: [UInt8] = [0x27, 0x00, 0x01]
        bytes += le32(1000) + le32(2000) + le32(5000)
        let message = try XCTUnwrap(DexcomSessionStartRxMessage(data: Data(bytes)))
        XCTAssertEqual(message.sessionStartResponse, .manualCalibrationSessionStarted)
        XCTAssertEqual(message.requestedStartTime, 1000)
        XCTAssertEqual(message.sessionStartTime, 2000)
        XCTAssertEqual(message.transmitterTime, 5000)
        XCTAssertEqual(message.sessionStartDate.timeIntervalSince(message.transmitterStartDate), 2000, accuracy: 0.001)
        XCTAssertEqual(message.requestedStartDate.timeIntervalSince(message.transmitterStartDate), 1000, accuracy: 0.001)
        XCTAssertEqual(Date().timeIntervalSince(message.transmitterStartDate), 5000, accuracy: 5)
    }

    func testSessionStartRxRejectsUnknownResponseShortOrWrongOpcode() {
        let valid: [UInt8] = [0x27, 0x00, 0x06] + le32(1) + le32(2) + le32(3)
        XCTAssertEqual(DexcomSessionStartRxMessage(data: Data(valid))?.sessionStartResponse, .autoCalibrationSessionInProgress)
        var unknown = valid
        unknown[2] = 0x09
        XCTAssertNil(DexcomSessionStartRxMessage(data: Data(unknown)))
        XCTAssertNil(DexcomSessionStartRxMessage(data: Data(valid.prefix(14))))
        XCTAssertNil(DexcomSessionStartRxMessage(data: Data([0x29] + valid.dropFirst())))
    }

    func testSessionStopRxDecodesStopDateAndStatus() throws {
        let bytes: [UInt8] = [0x29, 0x00, 0x01] + le32(4000) + le32(0) + le32(9000)
        let message = try XCTUnwrap(DexcomSessionStopRxMessage(data: Data(bytes)))
        XCTAssertTrue(message.isOkay)
        XCTAssertEqual(message.sessionStopResponse, .stopSessionSuccessful)
        XCTAssertEqual(message.sessionStopDate.timeIntervalSince(message.transmitterStartDate), 4000, accuracy: 0.001)
        var failed = bytes
        failed[1] = 0x01
        failed[2] = 0x03
        let stale = try XCTUnwrap(DexcomSessionStopRxMessage(data: Data(failed)))
        XCTAssertFalse(stale.isOkay)
        XCTAssertEqual(stale.sessionStopResponse, .staleStopCommand)
        failed[2] = 0x04
        XCTAssertNil(DexcomSessionStopRxMessage(data: Data(failed)))
        XCTAssertNil(DexcomSessionStopRxMessage(data: Data(bytes.prefix(10))))
    }

    func testSessionStopResponseDescriptions() {
        XCTAssertEqual(DexcomSessionStopResponse.stopSessionSuccessful.description, "stopSessionSuccessful")
        XCTAssertEqual(DexcomSessionStopResponse.noSessionInProgress.description, "noSessionInProgress")
        XCTAssertEqual(DexcomSessionStopResponse.staleStopCommand.description, "staleStopCommand")
    }

    func testSessionStartResponseDescriptionsAndColors() {
        let expected: [DexcomSessionStartResponse: DexcomSensorStatusIndicatorColor] = [
            .manualCalibrationSessionStarted: .yellow, .manualCalibrationSessionInProgress: .yellow,
            .autoCalibrationSessionInProgress: .yellow, .staleStartComand: .orange, .error: .orange,
            .transmitterEndOfLife: .red,
        ]
        for response in DexcomSessionStartResponse.allCases {
            XCTAssertEqual(response.indicatorColor, expected[response])
            XCTAssertEqual(DexcomSessionStartResponse.indicatorColor(forDescription: response.description), expected[response])
        }
        XCTAssertNil(DexcomSessionStartResponse.indicatorColor(forDescription: "nonsense"))
        XCTAssertEqual(DexcomSessionStartResponse.transmitterEndOfLife.description, "transmitter end of life")
    }

    func testCalibrationRxAcceptanceFollowsResponseType() {
        let accepted: [UInt8] = [0x00, 0x06, 0x0D]
        let rejected: [UInt8] = [0x01, 0x08, 0x0B, 0x0E, 0xFF]
        for raw in accepted {
            XCTAssertEqual(DexcomCalibrationRxMessage(data: Data([0x35, 0x00, raw]))?.accepted, true)
        }
        for raw in rejected {
            XCTAssertEqual(DexcomCalibrationRxMessage(data: Data([0x35, 0x00, raw]))?.accepted, false)
        }
        let unknown = DexcomCalibrationRxMessage(data: Data([0x35, 0x00, 0x42]))
        XCTAssertNil(unknown?.type)
        XCTAssertEqual(unknown?.accepted, false)
        XCTAssertNil(DexcomCalibrationRxMessage(data: Data([0x35, 0x00])))
        XCTAssertNil(DexcomCalibrationRxMessage(data: Data([0x34, 0x00, 0x00])))
    }

    func testCalibrationResponseTypeDescriptionsAndValidCollection() {
        let all: [DexcomCalibrationResponseType] = [.okay, .codeOne, .secondCalibrationNeeded, .rejected, .sensorStopped, .duplicate, .notReady, .unableToDecode]
        XCTAssertEqual(all.map(\.description), ["okay", "codeOne", "secondCalibrationNeeded", "rejected", "sensorStopped", "duplicate", "notReady", "unableToDecode"])
        XCTAssertEqual(DexcomCalibrationResponseType.validCollection, [.okay, .secondCalibrationNeeded, .duplicate])
    }

    // MARK: - Algorithm state

    func testAlgorithmStateColorsCoverAllCases() {
        let green: Set<DexcomAlgorithmState> = [.okay, .needsCalibration]
        let yellow: Set<DexcomAlgorithmState> = [.SensorWarmup, .FirstofTwoBGsNeeded, .SecondofTwoBGsNeeded]
        let orange: Set<DexcomAlgorithmState> = [.excessNoise, .OutOfCalibrationDueToOutlier, .OutlierCalibrationRequest, .TemporarySensorIssue, .questionMarks]
        for state in DexcomAlgorithmState.allCases {
            let expected: DexcomSensorStatusIndicatorColor = green.contains(state) ? .green : yellow.contains(state) ? .yellow : orange.contains(state) ? .orange : .red
            XCTAssertEqual(state.indicatorColor, expected, state.description)
            XCTAssertFalse(state.description.isEmpty)
        }
    }

    func testAlgorithmStateColorLookupByDescription() {
        XCTAssertEqual(DexcomAlgorithmState.indicatorColor(forDescription: "OK / Calibrated"), .green)
        XCTAssertEqual(DexcomAlgorithmState.indicatorColor(forDescription: "Sensor warmup"), .yellow)
        XCTAssertEqual(DexcomAlgorithmState.indicatorColor(forDescription: "???"), .orange)
        XCTAssertEqual(DexcomAlgorithmState.indicatorColor(forDescription: "Sensor failed"), .red)
        XCTAssertNil(DexcomAlgorithmState.indicatorColor(forDescription: "Unknown state"))
    }

    func testAlgorithmStateSensorHealthMapping() {
        XCTAssertEqual(DexcomAlgorithmState.excessNoise.sensorHealthEvent, .temporary(source: .dexcom, reason: .dexcomExcessNoise))
        XCTAssertEqual(DexcomAlgorithmState.TemporarySensorIssue.sensorHealthEvent, .temporary(source: .dexcom, reason: .dexcomTemporarySensorIssue))
        XCTAssertEqual(DexcomAlgorithmState.questionMarks.sensorHealthEvent, .temporary(source: .dexcom, reason: .dexcomQuestionMarks))
        XCTAssertEqual(DexcomAlgorithmState.SessionFailedDueToTransmitterError.sensorHealthEvent, .terminal(source: .dexcom, reason: .dexcomTransmitterFailure))
        let failures: [DexcomAlgorithmState] = [.SensorFailedDuetoCountsAberration, .SensorFailedDuetoResidualAberration, .SessionFailedDueToUnrecoverableError,
                                                .SensorFailedDueToProgressiveSensorDecline, .SensorFailedDueToHighCountsAberration,
                                                .SensorFailedDueToLowCountsAberration, .SensorFailedDueToRestart, .SensorFailed8, .sensorFailed]
        for state in failures {
            XCTAssertEqual(state.sensorHealthEvent, .terminal(source: .dexcom, reason: .dexcomSensorFailure), state.description)
        }
        for state: DexcomAlgorithmState in [.okay, .SensorWarmup, .None, .SessionExpired, .expired, .needsCalibration] {
            XCTAssertEqual(state.sensorHealthEvent, .recovered(source: .dexcom), state.description)
        }
    }

    // MARK: - Backfill stream

    func testBackfillStreamDecodesValidRecordsAcrossPackets() {
        let stream = DexcomBackfillStream()
        let records = record(time: 1000, glucose: 120, state: 0x06, trend: 0xFE)
            + record(time: 1300, glucose: 125, state: 0x02, trend: 0)
            + record(time: 0, glucose: 130, state: 0x06, trend: 0)
            + record(time: 1600, glucose: 140, state: 0x07, trend: 3)
        let all = [UInt8](repeating: 0xAA, count: 4) + records
        stream.push(Data([0x01, 0x00] + all.prefix(18)))
        stream.push(Data([0x02, 0x00] + all.dropFirst(18).prefix(18)))
        stream.push(Data([0x03, 0x00] + all.dropFirst(36)))
        XCTAssertEqual(stream.data.count, all.count)
        let decoded = stream.decode()
        XCTAssertEqual(decoded.map(\.dexTime), [1000, 1600])
        XCTAssertEqual(decoded.map(\.glucose), [120, 140])
        XCTAssertEqual(decoded.map(\.trend), [0xFE, 3])
    }

    func testBackfillStreamIgnoresOutOfOrderAndEmptyPackets() {
        let stream = DexcomBackfillStream()
        stream.push(Data())
        stream.push(Data([0x02, 0x00, 0x01, 0x02]))
        XCTAssertTrue(stream.data.isEmpty)
        stream.push(Data([0x01, 0x00, 0x01, 0x02]))
        stream.push(Data([0x01, 0x00, 0x03]))
        XCTAssertEqual(stream.data, Data([0x01, 0x02]))
    }

    func testBackfillStreamCapsBufferAtOneThousandBytes() {
        let stream = DexcomBackfillStream()
        for sequence in 1...60 {
            stream.push(Data([UInt8(sequence), 0x00] + [UInt8](repeating: 0x11, count: 18)))
        }
        XCTAssertEqual(stream.data.count, 1000)
    }

    func testBackfillStreamWithIncompleteRecordReturnsNothing() {
        let stream = DexcomBackfillStream()
        stream.push(Data([0x01, 0x00] + [0, 0, 0, 0] + record(time: 1000, glucose: 100, state: 6, trend: 0).prefix(7)))
        XCTAssertTrue(stream.decode().isEmpty)
    }

    // MARK: - G7 messages

    func testG7GlucoseMessageDecodesAllFields() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let bytes = g7Glucose(status: 0, txTime: 100_000, age: 60, glucose: 0x0078, state: 0x06, trend: 0xF6, predicted: 0x007D, flags: 0)
        let message = try XCTUnwrap(G7GlucoseMessage(data: Data(bytes), receivedAt: receivedAt))
        XCTAssertEqual(message.responseStatus, 0)
        XCTAssertEqual(message.transmitterTime, 100_000)
        XCTAssertEqual(message.messageAge, 60)
        XCTAssertEqual(message.sensorAge, 99_940)
        XCTAssertEqual(message.timeStamp, receivedAt.addingTimeInterval(-60))
        XCTAssertEqual(message.receivedAt, receivedAt)
        XCTAssertEqual(message.calculatedValue, 120)
        XCTAssertEqual(message.algorithmStatus, .okay)
    }

    func testG7GlucoseMessageHandlesMissingGlucoseAndUnknownState() throws {
        let bytes = g7Glucose(status: 0x81, txTime: 500, age: 10, glucose: 0xFFFF, state: 0x99, trend: 0x7F, predicted: 0xFFFF, flags: 0x10)
        let message = try XCTUnwrap(G7GlucoseMessage(data: Data(bytes)))
        XCTAssertEqual(message.responseStatus, 0x81)
        XCTAssertEqual(message.calculatedValue, 0)
        XCTAssertEqual(message.algorithmStatus, DexcomAlgorithmState.None)
    }

    func testG7GlucoseMessageRejectsAgeGreaterThanTransmitterTimeShortOrWrongOpcode() {
        XCTAssertNil(G7GlucoseMessage(data: Data(g7Glucose(status: 0, txTime: 30, age: 31, glucose: 100, state: 6, trend: 0, predicted: 0, flags: 0))))
        let valid = g7Glucose(status: 0, txTime: 300, age: 30, glucose: 100, state: 6, trend: 0, predicted: 0, flags: 0)
        XCTAssertNil(G7GlucoseMessage(data: Data(valid.prefix(18))))
        XCTAssertNil(G7GlucoseMessage(data: Data([0x4F] + valid.dropFirst())))
    }

    func testG7GlucoseMessageMasksDisplayOnlyFlagBits() throws {
        let bytes = g7Glucose(status: 0, txTime: 300, age: 0, glucose: 0xF0C8, state: 6, trend: 0, predicted: 0, flags: 0)
        XCTAssertEqual(try XCTUnwrap(G7GlucoseMessage(data: Data(bytes))).calculatedValue, 200)
    }

    func testG7CoexistenceGlucoseMessageDecodesClockAndValue() {
        let bytes: [UInt8] = [0x31, 0x00, 0, 0, 0, 0] + le32(86_400) + [0x96, 0xF0, 0x0F, 0, 0, 0]
        let message = G7CoexistenceGlucoseMessage(data: Data(bytes))
        XCTAssertEqual(message?.calculatedValue, 150)
        XCTAssertEqual(message?.algorithmStatus, .SessionExpired)
        XCTAssertEqual(message?.transmitterTime, 86_400)
        XCTAssertNil(G7CoexistenceGlucoseMessage(data: Data(bytes.prefix(15))))
        var unknown = bytes
        unknown[12] = 0xEE
        XCTAssertEqual(G7CoexistenceGlucoseMessage(data: Data(unknown))?.algorithmStatus, DexcomAlgorithmState.None)
    }

    func testG7BackfillMessageAnchorsToSensorStart() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let message = try XCTUnwrap(DexcomG7BackfillMessage(data: Data(le32(0x00_00A1_45) + [0x96, 0x00, 0x06, 0x0F, 0xFC]), sensorStartDate: start))
        XCTAssertEqual(message.timeStamp, start.addingTimeInterval(0xA145))
        XCTAssertEqual(message.calculatedValue, 150)
    }

    func testG7BackfillMessageHandlesMissingValueAndLength() throws {
        let start = Date(timeIntervalSince1970: 0)
        let missing = try XCTUnwrap(DexcomG7BackfillMessage(data: Data(le32(300) + [0xFF, 0xFF, 0x06, 0x00, 0x7F]), sensorStartDate: start))
        XCTAssertEqual(missing.calculatedValue, 0)
        let flagged = try XCTUnwrap(DexcomG7BackfillMessage(data: Data(le32(300) + [0x64, 0x10, 0x06, 0x00, 0x05]), sensorStartDate: start))
        XCTAssertEqual(flagged.calculatedValue, 100)
        XCTAssertNotEqual(missing, flagged)
        XCTAssertEqual(flagged, DexcomG7BackfillMessage(data: Data(le32(300) + [0x64, 0x10, 0x06, 0x00, 0x05]), sensorStartDate: start))
        XCTAssertNil(DexcomG7BackfillMessage(data: Data(repeating: 0, count: 8), sensorStartDate: start))
        XCTAssertNil(DexcomG7BackfillMessage(data: Data(repeating: 0, count: 10), sensorStartDate: start))
    }

    func testG7BatteryStatusDecodesSignedTemperature() {
        let message = DexcomG7BatteryStatusMessage(data: Data([0x22, 0x00, 0x3C, 0x01, 0x2C, 0x01, 0xA0, 0x05, 0x0A, 0xFB]))
        XCTAssertEqual(message?.voltageA, 316)
        XCTAssertEqual(message?.voltageB, 300)
        XCTAssertEqual(message?.resistance, 1440)
        XCTAssertEqual(message?.runtime, 10)
        XCTAssertEqual(message?.temperature, -5)
        XCTAssertNil(DexcomG7BatteryStatusMessage(data: Data([0x22, 0, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertNil(DexcomG7BatteryStatusMessage(data: Data([0x23, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertEqual(DexcomG7BatteryStatusMessage.opCode, 0x22)
    }

    func testG7VersionMessageDecodesFirmwareBuildAndSerial() {
        let bytes: [UInt8] = [0x4A, 0x00, 2, 18, 2, 88] + le32(0x0102_0304) + le32(77) + [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
        let message = DexcomG7VersionMessage(data: Data(bytes))
        XCTAssertEqual(message?.firmwareVersion, "2.18.2.88")
        XCTAssertEqual(message?.buildVersion, 0x0102_0304)
        XCTAssertEqual(message?.versionCode, 77)
        XCTAssertEqual(message?.serialNumber, 0x0605_0403_0201)
        XCTAssertNil(DexcomG7VersionMessage(data: Data(bytes.prefix(19))))
        XCTAssertNil(DexcomG7VersionMessage(data: Data([0x4B] + bytes.dropFirst())))
    }

    func testG7ExtendedVersionDecodesLifetimeFields() {
        let bytes: [UInt8] = [0x52, 0x00] + le32(907_200) + [0x08, 0x07] + le32(0xAABB_CCDD) + [0x03, 0x0F, 0x00]
        let message = DexcomG7ExtendedVersionMessage(data: Data(bytes))
        XCTAssertEqual(message?.sessionLength, 907_200)
        XCTAssertEqual(message?.warmupDuration, 1800)
        XCTAssertEqual(message?.algorithmVersion, 0xAABB_CCDD)
        XCTAssertEqual(message?.hardwareVersion, 3)
        XCTAssertEqual(message?.maxLifetimeDays, 15)
        XCTAssertNil(DexcomG7ExtendedVersionMessage(data: Data(bytes.prefix(14))))
        XCTAssertNil(DexcomG7ExtendedVersionMessage(data: Data([0x53] + bytes.dropFirst())))
    }

    func testG7SensorLifetimeSupportsOnlyKnownSessionLengths() {
        XCTAssertEqual(DexcomG7SensorLifetime.supportedSessionLength(907_200), 907_200)
        XCTAssertEqual(DexcomG7SensorLifetime.supportedSessionLength(1_339_200), 1_339_200)
        XCTAssertNil(DexcomG7SensorLifetime.supportedSessionLength(864_000))
        XCTAssertNil(DexcomG7SensorLifetime.supportedSessionLength(nil))
        XCTAssertEqual(DexcomG7SensorLifetime.diagnosticDescription(907_200), "10-day sensor (+ 12-hour grace period)")
        XCTAssertEqual(DexcomG7SensorLifetime.diagnosticDescription(1_339_200), "15-day sensor (+ 12-hour grace period)")
        XCTAssertEqual(DexcomG7SensorLifetime.diagnosticDescription(1), "not detected")
    }

    func testG7MaximumSensorAgePrefersReportedLengthThenSteloName() {
        XCTAssertEqual(DexcomG7SensorLifetime.maximumSensorAgeInDays(reportedSessionLength: 1_339_200, deviceName: "DXCMAB"), 15.5)
        XCTAssertEqual(DexcomG7SensorLifetime.maximumSensorAgeInDays(reportedSessionLength: 907_200, deviceName: "DX01AB"), 10.5)
        XCTAssertEqual(DexcomG7SensorLifetime.maximumSensorAgeInDays(reportedSessionLength: nil, deviceName: "dx01ab"), 15.5)
        XCTAssertEqual(DexcomG7SensorLifetime.maximumSensorAgeInDays(reportedSessionLength: nil, deviceName: "DXCMAB"), 10.5)
        XCTAssertEqual(DexcomG7SensorLifetime.maximumSensorAgeInDays(reportedSessionLength: 5, deviceName: nil), 10.5)
    }

    func testG7CalibrationTraceDescriptionsAndFlags() {
        XCTAssertEqual(DexcomG7CalibrationCommandStatus.acceptedHigh(.accepted).traceDescription, "accepted high likelihood: accepted")
        XCTAssertEqual(DexcomG7CalibrationCommandStatus.acceptedLow(.error1).traceDescription, "accepted low likelihood: error 1")
        XCTAssertEqual(DexcomG7CalibrationCommandStatus.rejected(.stale).traceDescription, "rejected: stale")
        XCTAssertEqual(DexcomG7CalibrationCommandStatus.factoryCalibrated.traceDescription, "factory calibrated")
        XCTAssertEqual(DexcomG7CalibrationCommandStatus.unknown(primary: 7, secondary: 8).traceDescription, "unknown primary=7 secondary=8")
        XCTAssertTrue(DexcomG7CalibrationCommandStatus.acceptedHigh(.accepted).accepted)
        XCTAssertFalse(DexcomG7CalibrationCommandStatus.acceptedLow(.error0).accepted)
        XCTAssertTrue(DexcomG7CalibrationCommandStatus.factoryCalibrated.accepted)
        XCTAssertFalse(DexcomG7CalibrationCommandStatus.rejected(.duplicate).accepted)
        XCTAssertFalse(DexcomG7CalibrationCommandStatus.unknown(primary: 4, secondary: 0).accepted)
        XCTAssertEqual(DexcomG7CalibrationAcceptanceDetail(rawValue: 9).traceDescription, "unknown (9)")
        XCTAssertEqual(DexcomG7CalibrationAcceptanceDetail(rawValue: 1).traceDescription, "error 0")
    }

    func testG7RejectionReasonTraceAndDuplicateClassification() {
        let descriptions = (0...12).map { DexcomG7CalibrationRejectionReason(rawValue: UInt8($0)).traceDescription }
        XCTAssertEqual(descriptions, ["unspecified", "outside range", "timestamp in future", "duplicate", "earlier than session start",
                                      "not in order", "already entered", "disabled", "not permitted", "calibration bounds failed",
                                      "extreme outlier", "stale", "unknown (12)"])
        XCTAssertTrue(DexcomG7CalibrationRejectionReason.duplicate.isTerminalDuplicate)
        XCTAssertTrue(DexcomG7CalibrationRejectionReason.alreadyEntered.isTerminalDuplicate)
        XCTAssertFalse(DexcomG7CalibrationRejectionReason.stale.isTerminalDuplicate)
    }

    func testG7CalibrationBoundsKeepsUnknownProcessingAndDisplayBytes() throws {
        var bytes: [UInt8] = [0x32, 0x00, 0x02] + le32(9) + [0x64, 0x00] + le32(1000) + [0x09, 0x00, 0x0C] + le32(1200)
        let bounds = try XCTUnwrap(DexcomG7CalibrationBounds(data: Data(bytes)))
        XCTAssertNil(bounds.processingState)
        XCTAssertEqual(bounds.processingRawValue, 9)
        XCTAssertFalse(bounds.calibrationsPermitted)
        XCTAssertNil(bounds.originatingDisplay)
        XCTAssertEqual(bounds.originatingDisplayRawValue, 12)
        XCTAssertTrue(bounds.matches(glucose: 99.6, transmitterTime: 1002))
        XCTAssertFalse(bounds.matches(glucose: 100, transmitterTime: 1003))
        XCTAssertTrue(bounds.matches(glucose: 100, transmitterTime: 1005, tolerance: 5))
        bytes[13] = 4
        bytes[15] = 5
        let complete = try XCTUnwrap(DexcomG7CalibrationBounds(data: Data(bytes)))
        XCTAssertEqual(complete.processingState, .completeLow)
        XCTAssertEqual(complete.originatingDisplay, .pump)
    }

    func testG7ProcessingStateTraceDescriptions() {
        let states: [DexcomG7CalibrationProcessingState] = [.none, .factoryCalibrated, .inProgress, .completeHigh, .completeLow]
        XCTAssertEqual(states.map(\.traceDescription), ["none", "factory calibrated", "in progress", "complete high", "complete low"])
        XCTAssertEqual(DexcomG7CalibrationDisplay(rawValue: 9), .transmitter)
        XCTAssertNil(DexcomG7CalibrationDisplay(rawValue: 10))
    }

    func testG7ClockReferenceRejectsOutOfRangeTimes() {
        let reference = Date(timeIntervalSince1970: 10_000)
        let clock = DexcomG7TransmitterClockReference(transmitterTime: 100, referenceDate: reference)
        XCTAssertNil(clock.transmitterTime(for: reference.addingTimeInterval(-101)))
        XCTAssertEqual(clock.transmitterTime(for: reference.addingTimeInterval(-100)), 0)
        XCTAssertEqual(clock.transmitterTime(for: reference.addingTimeInterval(0.6)), 101)
        let high = DexcomG7TransmitterClockReference(transmitterTime: UInt32.max, referenceDate: reference)
        XCTAssertNil(high.transmitterTime(for: reference.addingTimeInterval(1)))
    }

    func testG7CalibrationCommandEncodesLittleEndianFields() {
        let data = DexcomG7CalibrationCommand(glucose: 0x0201, transmitterTime: 0x0605_0403).data
        XCTAssertEqual(Array(data.prefix(7)), [0x34, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        XCTAssertTrue(data.isCRCValid)
    }

    // MARK: - Watch protocol helpers

    func testWatchProtocolReadsLittleEndianUInt32WithBoundsCheck() {
        let data = Data([0xAA, 0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(DexcomWatchProtocol.uint32(data, at: 1), 0x0403_0201)
        XCTAssertNil(DexcomWatchProtocol.uint32(data, at: 2))
        XCTAssertNil(DexcomWatchProtocol.uint32(data, at: -1))
    }

    func testG6WatchChallengeHashMatchesAESReference() {
        let challenge = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G1234", challenge: challenge),
                       Data([0x7D, 0x3F, 0xF9, 0x60, 0xCF, 0x00, 0x5C, 0x1C]))
        XCTAssertNil(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G123", challenge: challenge))
        XCTAssertNil(DexcomG6WatchProtocol.challengeHash(transmitterID: "8G1234", challenge: challenge.prefix(7)))
    }

    func testG6WatchCommandAndChecksumMatchMessageCRC() {
        XCTAssertEqual(DexcomG6WatchProtocol.command(0x24), DexcomTransmitterTimeTxMessage().data)
        XCTAssertEqual(DexcomG6WatchProtocol.checksum(Data("123456789".utf8)), 0x31C3)
        XCTAssertTrue(DexcomG6WatchProtocol.hasValidCRC(Data([0x30]).appendingCRC()))
        XCTAssertFalse(DexcomG6WatchProtocol.hasValidCRC(Data([0x30, 0x00, 0x00])))
        XCTAssertFalse(DexcomG6WatchProtocol.hasValidCRC(Data([0x30, 0x00])))
    }

    func testG6WatchGlucoseParsesBothOpcodesAndRequiresCRC() throws {
        let body: [UInt8] = [0x31, 0x00, 0, 0, 0, 0] + le32(7200) + [0x96, 0xF0, 0x06, 0x00]
        let parsed = try XCTUnwrap(DexcomG6WatchProtocol.glucose(Data(body).appendingCRC()))
        XCTAssertEqual(parsed.seconds, 7200)
        XCTAssertEqual(parsed.value, 150)
        XCTAssertEqual(parsed.state, 6)
        XCTAssertNotNil(DexcomG6WatchProtocol.glucose(Data([0x4F] + body.dropFirst()).appendingCRC()))
        XCTAssertNil(DexcomG6WatchProtocol.glucose(Data([0x30] + body.dropFirst()).appendingCRC()))
        XCTAssertNil(DexcomG6WatchProtocol.glucose(Data(body + [0, 0])))
    }

    // MARK: - Misc

    func testFireflyDetectionUsesLeadingDigit() {
        XCTAssertFalse("4ABCDE".isFireFly())
        XCTAssertTrue("8GABCD".isFireFly())
        XCTAssertTrue("".isFireFly())
    }

    func testDexcomErrorIsHighPriorityBatteryMessage() {
        let error = DexcomError.receivedEnfilteredValue2096896
        XCTAssertEqual(error.priority, .HIGH)
        XCTAssertEqual(error.errorDescription, Texts_HomeView.dexcomBatteryTooLow)
    }

    func testProofSignerProducesVerifiableP256Signature() throws {
        let challenge = Data(repeating: 0x42, count: 16)
        let key = Data((1...32).map { UInt8($0) })
        var error: NSError?
        let signature = try XCTUnwrap(DexcomG7CryptoKitProofSigner.rawProofSignature(forChallenge: challenge as NSData, privateKeyRaw: key as NSData, error: &error))
        XCTAssertNil(error)
        XCTAssertEqual(signature.length, 64)
    }

    func testProofSignerReportsErrorForInvalidKey() {
        var error: NSError?
        XCTAssertNil(DexcomG7CryptoKitProofSigner.rawProofSignature(forChallenge: Data([1]) as NSData, privateKeyRaw: Data([1, 2, 3]) as NSData, error: &error))
        XCTAssertNotNil(error)
    }

    // MARK: - Helpers

    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private func record(time: UInt32, glucose: UInt16, state: UInt8, trend: UInt8) -> [UInt8] {
        le32(time) + [UInt8(glucose & 0xFF), UInt8(glucose >> 8), state, trend]
    }

    private func g7Glucose(status: UInt8, txTime: UInt32, age: UInt16, glucose: UInt16, state: UInt8, trend: UInt8, predicted: UInt16, flags: UInt8) -> [UInt8] {
        [0x4E, status] + le32(txTime) + [0x01, 0x00, 0x00, 0x00, UInt8(age & 0xFF), UInt8(age >> 8),
                                         UInt8(glucose & 0xFF), UInt8(glucose >> 8), state, trend,
                                         UInt8(predicted & 0xFF), UInt8(predicted >> 8), flags]
    }
}

extension DexcomCoverageMessageTests {
    func testTransmitterVersionRxKeepsTheHighByteOfTheExpiry() {
        var body: [UInt8] = [0x4B, 0x00, 1, 6, 5, 25] + Array(repeating: 0, count: 11)
        body[13] = 0x6D
        body[14] = 0x01
        let message = TransmitterVersionRxMessage(data: Data(body).appendingCRC())
        XCTAssertEqual(message?.transmitterExpiryInDays, 365)
        XCTAssertEqual(message?.isAnubis(), false)
        body[13] = 180
        XCTAssertEqual(TransmitterVersionRxMessage(data: Data(body).appendingCRC())?.isAnubis(), false)
    }
}
