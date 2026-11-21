//
//  LibreCoverageRealDataTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Libre 2 direct Bluetooth decryption and parsing, driven by captured frames.
final class LibreCoverageRealDataTests: XCTestCase {
    private var snapshot: LibreCoverageDefaultsSnapshot!
    private let newest = Date(timeIntervalSince1970: 1_000_000)
    private let multiplier = ConstantsBloodGlucose.libreMultiplier
    private var uid: Data { LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2UID) }

    override func setUp() {
        super.setUp()
        snapshot = LibreCoverageDefaultsSnapshot()
        snapshot.clear()
    }

    override func tearDown() {
        snapshot.restore()
        super.tearDown()
    }

    private func decrypted(_ index: Int) throws -> Data {
        Data(try Libre2BLEUtilities.decryptBLE(sensorUID: uid, data: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[index])))
    }

    private func parse(_ data: Data, parameters: Libre1DerivedAlgorithmParameters? = nil) -> Libre2BLEUtilities.ParsedBLEData {
        Libre2BLEUtilities.parseBLEData(data, libre1DerivedAlgorithmParameters: parameters, newestReadingDate: newest)
    }

    /// 44 byte decrypted frame: seven 4 byte readings at minutes 0, 2, 4, 6, 7, 12, 15 then the wear time.
    private func frame(raw: [Int], temperature: Int = 1500, adjustment: Int = 0, negative: Bool = false, minutes: UInt16 = 1234) -> Data {
        var data = Data(repeating: 0, count: 44)
        for (i, value) in raw.enumerated() {
            data = LibreCalibrationInfo.writeBits(data, i * 4, 0, 0xE, value)
            data = LibreCalibrationInfo.writeBits(data, i * 4, 0xE, 0xC, temperature)
            data = LibreCalibrationInfo.writeBits(data, i * 4, 0x1A, 0x5, adjustment)
            data = LibreCalibrationInfo.writeBits(data, i * 4, 0x1F, 0x1, negative ? 1 : 0)
        }
        data[40] = UInt8(minutes & 0xFF)
        data[41] = UInt8(minutes >> 8)
        return data
    }

    // MARK: - decryptBLE

    func testDecryptBLEProducesFrameWithValidCRC() throws {
        for index in LibreCoverageSamples.libre2Frames.indices {
            let plain = try decrypted(index)
            XCTAssertEqual(plain.count, 44)
            XCTAssertEqual(LibreCoverageBytes.crc16(Array(plain.prefix(42))), UInt16(plain[42]) << 8 | UInt16(plain[43]))
        }
    }

    func testDecryptBLEOfFirstCapturedFrame() throws {
        XCTAssertEqual(try decrypted(0).hexEncodedString(), "8802ee85a082f485ab420086bac21786c80217860903e38529c3b78121c3b781e8c2af812643b2851b03168b")
    }

    func testDecryptBLERejectsTamperedFrame() {
        var tampered = LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0])
        tampered[10] ^= 0x01
        XCTAssertThrowsError(try Libre2BLEUtilities.decryptBLE(sensorUID: uid, data: tampered)) { error in
            XCTAssertEqual(error.localizedDescription, "BLE data decryption failed")
        }
    }

    func testDecryptBLERejectsWrongSensorUID() {
        let other = LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID)
        XCTAssertThrowsError(try Libre2BLEUtilities.decryptBLE(sensorUID: other, data: LibreCoverageBytes.data(hex: LibreCoverageSamples.libre2Frames[0])))
    }

    // MARK: - parseBLEData without history

    func testParsesWearTimeFromLastTwoBytes() throws {
        let minutes = try LibreCoverageSamples.libre2Frames.indices.map { Int(parse(try decrypted($0)).sensorTimeInMinutes) }
        XCTAssertEqual(minutes, [795, 796, 797, 798, 799, 800])
    }

    func testParsesCapturedFrameIntoMinuteSpacedReadingsFillingSingleGaps() throws {
        let parsed = parse(try decrypted(0))
        let minutesBack = parsed.bleGlucose.map { Int((newest.timeIntervalSince($0.timeStamp) / 60).rounded()) }
        XCTAssertEqual(minutesBack, [0, 1, 2, 3, 4, 5, 6, 7, 12, 15])
        let raw = parsed.bleGlucose.map { $0.glucoseLevelRaw / multiplier }
        let expected: [Double] = [648, 660, 672, 677.5, 683, 690.5, 698, 712, 777, 809]
        for (value, expectedValue) in zip(raw, expected) {
            XCTAssertEqual(value, expectedValue, accuracy: 0.01)
        }
    }

    func testFrameWhoseNewestReadingIsZeroIsDropped() throws {
        let parsed = parse(try decrypted(1))
        XCTAssertEqual(parsed.sensorTimeInMinutes, 796)
        XCTAssertTrue(parsed.bleGlucose.isEmpty)
    }

    func testInterpolatesSingleMissingMinutesLinearly() {
        let parsed = parse(frame(raw: [100, 120, 140, 160, 170, 220, 250]))
        XCTAssertEqual(parsed.bleGlucose.map { ($0.glucoseLevelRaw / multiplier).rounded() }, [100, 110, 120, 130, 140, 150, 160, 170, 220, 250])
        XCTAssertEqual(parsed.sensorTimeInMinutes, 1234)
    }

    func testDropsWholeFrameWhenARawValueIsImplausiblyHigh() {
        XCTAssertTrue(parse(frame(raw: [100, 100, 100, 100, 100, 100, 3001])).bleGlucose.isEmpty)
        XCTAssertEqual(parse(frame(raw: [100, 100, 100, 100, 100, 100, 3000])).bleGlucose.count, 10)
    }

    func testZeroReadingsInTheMiddleAreFilteredOut() {
        let parsed = parse(frame(raw: [100, 0, 0, 0, 0, 0, 200]))
        XCTAssertEqual(parsed.bleGlucose.map { Int((newest.timeIntervalSince($0.timeStamp) / 60).rounded()) }, [0, 15])
    }

    func testUsesDerivedParametersWhenAvailable() {
        let parameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 1, offset_offset: 0, isValidForFooterWithReverseCRCs: 0, extraSlope: 2, extraOffset: 5, sensorSerialNumber: "S")
        let parsed = parse(frame(raw: [100, 120, 140, 160, 170, 220, 250]), parameters: parameters)
        XCTAssertEqual(parsed.bleGlucose.first?.glucoseLevelRaw, 205)
        XCTAssertEqual(parsed.bleGlucose.last?.glucoseLevelRaw, 505)
    }

    func testDerivedParameterResultAbove3000IsRejected() {
        let parameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 1, offset_offset: 0, isValidForFooterWithReverseCRCs: 0, extraSlope: 2, extraOffset: 5, sensorSerialNumber: "S")
        XCTAssertTrue(parse(frame(raw: [1600, 100, 100, 100, 100, 100, 100]), parameters: parameters).bleGlucose.isEmpty)
    }

    func testNonPositiveDerivedResultFallsBackToRawMultiplier() {
        let parameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 0, offset_offset: -10, isValidForFooterWithReverseCRCs: 0, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "S")
        let parsed = parse(frame(raw: [100, 100, 100, 100, 100, 100, 100]), parameters: parameters)
        XCTAssertEqual(parsed.bleGlucose.first?.glucoseLevelRaw ?? 0, 100 * multiplier, accuracy: 1e-6)
    }

    func testDerivedResultIgnoresTemperatureAdjustmentBits() {
        let parameters = Libre1DerivedAlgorithmParameters(slope_slope: 0.0001, slope_offset: 0.001, offset_slope: 0.1, offset_offset: 1, isValidForFooterWithReverseCRCs: 0, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "S")
        let positive = parse(frame(raw: [500, 500, 500, 500, 500, 500, 500], adjustment: 10), parameters: parameters).bleGlucose.first?.glucoseLevelRaw
        let negative = parse(frame(raw: [500, 500, 500, 500, 500, 500, 500], adjustment: 10, negative: true), parameters: parameters).bleGlucose.first?.glucoseLevelRaw
        XCTAssertEqual(positive, negative)
        XCTAssertNotNil(positive)
    }

    // MARK: - overlap history

    func testCommitStoresSixteenValueHistory() throws {
        let parsed = parse(try decrypted(0))
        Libre2BLEUtilities.commitRawValueHistory(from: parsed)
        let glucose = try XCTUnwrap(UserDefaults.standard.previousRawGlucoseValues)
        XCTAssertEqual(glucose.count, 16)
        XCTAssertEqual(glucose[0], 648)
        XCTAssertEqual(glucose[1], 0, "history keeps the raw sparse values")
        XCTAssertEqual(glucose[15], 809)
        XCTAssertEqual(UserDefaults.standard.previousRawTemperatureValues?.count, 16)
        XCTAssertEqual(UserDefaults.standard.previousTemperatureAdjustmentValues?.count, 16)
    }

    func testCommitIsSkippedForFlatSensorResult() throws {
        Libre2BLEUtilities.commitRawValueHistory(from: parse(try decrypted(0)))
        let flat = parse(try decrypted(0))
        XCTAssertTrue(flat.bleGlucose.isEmpty, "five identical leading values mark an expired sensor")
        UserDefaults.standard.previousRawGlucoseValues = [1]
        Libre2BLEUtilities.commitRawValueHistory(from: flat)
        XCTAssertEqual(UserDefaults.standard.previousRawGlucoseValues, [1])
    }

    func testHistoryFromTwoMinutesEarlierExtendsAndFillsTheFrame() throws {
        let withoutHistory = parse(try decrypted(2))
        Libre2BLEUtilities.commitRawValueHistory(from: parse(try decrypted(0)))
        let withHistory = parse(try decrypted(2))

        let minutesBack = withHistory.bleGlucose.map { Int((newest.timeIntervalSince($0.timeStamp) / 60).rounded()) }
        XCTAssertEqual(minutesBack, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 17])
        XCTAssertGreaterThan(withHistory.bleGlucose.count, withoutHistory.bleGlucose.count)
        XCTAssertEqual(withHistory.bleGlucose.last?.glucoseLevelRaw ?? 0, 809 * multiplier, accuracy: 0.01)
        XCTAssertEqual(withHistory.bleGlucose[2].glucoseLevelRaw, withoutHistory.bleGlucose[2].glucoseLevelRaw)
    }

    func testUnrelatedHistoryLeavesFrameUnchanged() throws {
        UserDefaults.standard.previousRawGlucoseValues = Array(repeating: 5, count: 16)
        UserDefaults.standard.previousRawTemperatureValues = Array(repeating: 5, count: 16)
        UserDefaults.standard.previousTemperatureAdjustmentValues = Array(repeating: 0, count: 16)
        XCTAssertEqual(parse(try decrypted(0)).bleGlucose.count, 10)
    }

    func testInconsistentHistoryArraysAreIgnored() throws {
        let data = try decrypted(0)
        Libre2BLEUtilities.commitRawValueHistory(from: parse(data))
        UserDefaults.standard.previousRawTemperatureValues = [1, 2, 3]
        XCTAssertEqual(parse(data).bleGlucose.count, 10, "flat detection needs a consistent stored history")
    }

    func testShortHistoryMatchesOnASingleValue() {
        UserDefaults.standard.previousRawGlucoseValues = [300, 0, 280]
        UserDefaults.standard.previousRawTemperatureValues = [1500, 0, 1500]
        UserDefaults.standard.previousTemperatureAdjustmentValues = [0, 0, 0]
        let parsed = parse(frame(raw: [310, 300, 280, 260, 250, 200, 180]))
        XCTAssertEqual(parsed.bleGlucose.count, 10)
        XCTAssertEqual(parsed.bleGlucose.first?.glucoseLevelRaw ?? 0, 310 * multiplier, accuracy: 0.01)
    }

    // MARK: - streaming unlock

    func testStreamingUnlockPayloadMatchesKnownVector() {
        let payload = Libre2BLEUtilities.streamingUnlockPayload(sensorUID: uid, info: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo), enableTime: 42, unlockCount: 1)
        XCTAssertEqual(Data(payload).hexEncodedString(), "2b000000fc0c79c72c2d2bcf")
    }

    func testStreamingUnlockPayloadStartsWithLittleEndianTimePlusCount() {
        let payload = Libre2BLEUtilities.streamingUnlockPayload(sensorUID: uid, info: LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo), enableTime: 0x01020304, unlockCount: 0x10)
        XCTAssertEqual(payload.count, 12)
        XCTAssertEqual(Array(payload.prefix(4)), [0x14, 0x03, 0x02, 0x01])
    }

    func testStreamingUnlockPayloadChangesWithEveryUnlock() {
        let info = LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo)
        let payloads = (0..<5).map { Data(Libre2BLEUtilities.streamingUnlockPayload(sensorUID: uid, info: info, enableTime: 1_000, unlockCount: UInt16($0))) }
        XCTAssertEqual(Set(payloads).count, 5)
        XCTAssertEqual(payloads[1], Data(Libre2BLEUtilities.streamingUnlockPayload(sensorUID: uid, info: info, enableTime: 1_000, unlockCount: 1)))
    }
}
