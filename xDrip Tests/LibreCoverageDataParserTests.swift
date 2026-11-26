//
//  LibreCoverageDataParserTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class LibreCoverageDataParserTests: XCTestCase {
    private struct Outcome {
        let spy: LibreCoverageCGMDelegateSpy
        var completions: [(LibreSensorState?, XdripError?)]
        var glucose: [GlucoseData] { spy.receivedGlucose.last ?? [] }
    }

    private var snapshot: LibreCoverageDefaultsSnapshot!
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let multiplier = ConstantsBloodGlucose.libreMultiplier

    override func setUp() {
        super.setUp()
        snapshot = LibreCoverageDefaultsSnapshot()
        snapshot.clear()
    }

    override func tearDown() {
        snapshot.restore()
        super.tearDown()
    }

    private func standardFRAM(state: UInt8 = 3, minutes: Int = 1000, trend: [Int]? = nil) -> LibreCoverageFRAM {
        var fram = LibreCoverageFRAM()
        fram.state = state
        fram.sensorMinutes = minutes
        fram.trendIndex = 7
        // keeps the history index in sync with the minute counter: ((minutes - 3) / 15) % 32
        fram.historyIndex = ((minutes - 3) / 15) % 32
        fram.trend = trend ?? (0..<16).map { 300 - $0 * 5 }
        fram.history = (0..<32).map { 500 + $0 }
        return fram
    }

    @discardableResult
    private func process(_ parser: LibreDataParser, data: Data, patchInfo: String? = nil, webOOP: Bool = false, serial: String? = nil, decrypted: Bool = false, time: Date? = nil) -> Outcome {
        let spy = LibreCoverageCGMDelegateSpy()
        var completions: [(LibreSensorState?, XdripError?)] = []
        parser.libreDataProcessor(libreSensorSerialNumber: serial, patchInfo: patchInfo, webOOPEnabled: webOOP, libreData: data, cgmTransmitterDelegate: spy, dataIsDecryptedToLibre1Format: decrypted, testTimeStamp: time ?? now) { state, error in
            completions.append((state, error))
        }
        return Outcome(spy: spy, completions: completions)
    }

    private func minutesBefore(_ date: Date, _ reading: GlucoseData) -> Int {
        Int((date.timeIntervalSince(reading.timeStamp) / 60).rounded())
    }

    // MARK: - local Libre 1 parsing

    func testReadySensorDeliversTrendThenHistory() {
        let outcome = process(LibreDataParser(), data: standardFRAM().data())
        XCTAssertEqual(outcome.completions.count, 1)
        XCTAssertEqual(outcome.completions.first?.0, .ready)
        XCTAssertNil(outcome.completions.first?.1)
        XCTAssertEqual(outcome.spy.receivedSensorAges, [1000 * 60])
        XCTAssertNil(outcome.spy.receivedBattery.first ?? nil)

        let glucose = outcome.glucose
        let trend = Array(glucose.prefix(16))
        XCTAssertEqual(trend.map { minutesBefore(now, $0) }, Array(0..<16))
        XCTAssertEqual(trend.map { ($0.glucoseLevelRaw / multiplier).rounded() }, (0..<16).map { Double(300 - $0 * 5) })

        let history = Array(glucose.dropFirst(16))
        XCTAssertEqual(history.count, 31)
        XCTAssertEqual(history.map { minutesBefore(now, $0) }, (1..<32).map { 10 + 15 * $0 }.filter { $0 > 15 })
        XCTAssertEqual((history.first?.glucoseLevelRaw ?? 0) / multiplier, 501, accuracy: 0.001)
        XCTAssertEqual((history.last?.glucoseLevelRaw ?? 0) / multiplier, 531, accuracy: 0.001)
        XCTAssertEqual(outcome.spy.healthEvents, [.recovered(source: .libre)])
    }

    func testHistoryTimingWhenHistoryIndexRunsAheadOfMinuteCounter() {
        var fram = standardFRAM()
        fram.historyIndex = (fram.historyIndex + 1) % 32
        let glucose = process(LibreDataParser(), data: fram.data()).glucose
        let history = Array(glucose.dropFirst(16))
        // the most recent history value is then 15 minutes more recent: -5, 10, 25, ... minutes ago
        XCTAssertEqual(history.map { minutesBefore(now, $0) }, (0..<32).map { -5 + 15 * $0 }.filter { $0 > 15 })
    }

    func testZeroRawValuesAreSkipped() {
        var trend = (0..<16).map { 300 - $0 * 5 }
        trend[3] = 0
        var fram = standardFRAM(trend: trend)
        fram.history = Array(repeating: 0, count: 32)
        let glucose = process(LibreDataParser(), data: fram.data()).glucose
        XCTAssertEqual(glucose.count, 15)
        XCTAssertFalse(glucose.map { minutesBefore(now, $0) }.contains(3))
    }

    func testTrendIndexWrapsAroundTheRingBuffer() {
        for trendIndex in [0, 1, 15] {
            UserDefaults.standard.previousRawLibreValues = []
            var fram = standardFRAM()
            fram.trendIndex = trendIndex
            let trend = process(LibreDataParser(), data: fram.data()).glucose.prefix(16)
            XCTAssertEqual(trend.map { ($0.glucoseLevelRaw / multiplier).rounded() }, (0..<16).map { Double(300 - $0 * 5) }, "trend index \(trendIndex)")
        }
    }

    func testIdenticalSecondReadingIsTreatedAsFlatExpiredSensor() {
        let parser = LibreDataParser()
        let data = standardFRAM().data()
        process(parser, data: data)
        let second = process(parser, data: data, time: now.addingTimeInterval(60))
        XCTAssertEqual(second.spy.receivedGlucose.count, 1)
        XCTAssertTrue(second.glucose.isEmpty)
        XCTAssertEqual(second.completions.first?.0, .ready)
    }

    func testTrendIsExtendedWithMatchingPreviousValues() {
        let parser = LibreDataParser()
        let first = (0..<16).map { 300 - $0 * 5 }
        process(parser, data: standardFRAM(trend: first).data())
        XCTAssertEqual(UserDefaults.standard.previousRawLibreValues.count, 16)

        let later = now.addingTimeInterval(120)
        let second = [320, 310] + Array(first.prefix(14))
        let glucose = process(parser, data: standardFRAM(minutes: 1002, trend: second).data(), time: later).glucose
        let trend = glucose.filter { minutesBefore(later, $0) <= 17 }
        XCTAssertEqual(trend.count, 18)
        XCTAssertEqual(trend.map { minutesBefore(later, $0) }, Array(0..<18))
        XCTAssertEqual(trend.suffix(2).map { ($0.glucoseLevelRaw / multiplier).rounded() }, [Double(first[14]), Double(first[15])])
        XCTAssertEqual(UserDefaults.standard.previousRawLibreValues.count, 18)
    }

    func testPreviousValuesWithoutOverlapAreNotAppended() {
        let parser = LibreDataParser()
        process(parser, data: standardFRAM(trend: (0..<16).map { 100 + $0 }).data())
        let glucose = process(parser, data: standardFRAM(trend: (0..<16).map { 900 + $0 }).data()).glucose
        XCTAssertEqual(glucose.filter { minutesBefore(now, $0) < 16 }.count, 16)
        XCTAssertEqual(UserDefaults.standard.previousRawLibreValues.count, 16)
    }

    func testStoredHistoryIsLimitedTo27Values() {
        UserDefaults.standard.previousRawLibreValues = (0..<40).map { Double(1000 + $0) * ConstantsBloodGlucose.libreMultiplier }
        let parser = LibreDataParser()
        let trend = [1, 2, 3, 4].map { 2000 + $0 } + (0..<12).map { 1000 + $0 }
        process(parser, data: standardFRAM(trend: trend).data())
        XCTAssertEqual(UserDefaults.standard.previousRawLibreValues.count, 27)
    }

    // MARK: - sensor state handling

    func testYoungSensorReportsStartingWithEmptyReadings() {
        let outcome = process(LibreDataParser(), data: standardFRAM(minutes: 30).data())
        XCTAssertEqual(outcome.spy.receivedGlucose.count, 1)
        XCTAssertTrue(outcome.glucose.isEmpty)
        XCTAssertEqual(outcome.spy.receivedSensorAges, [30 * 60])
        XCTAssertEqual(outcome.completions.first?.0, .starting)
        XCTAssertNil(outcome.completions.first?.1)
    }

    func testFailedSensorReportsTerminalHealthEventAndNoReadings() {
        let outcome = process(LibreDataParser(), data: standardFRAM(state: 6).data())
        XCTAssertEqual(outcome.completions.first?.0, .failure)
        XCTAssertEqual(outcome.completions.first?.1?.errorDescription, LibreError.sensorNotReady.errorDescription)
        XCTAssertEqual(outcome.spy.healthEvents, [.terminal(source: .libre, reason: .libreSensorFailure)])
        XCTAssertTrue(outcome.spy.receivedGlucose.isEmpty)
        XCTAssertTrue(outcome.spy.errors.isEmpty)
    }

    func testLifecycleStatesSuppressReadingsWithoutErrors() {
        for (byte, state) in [(UInt8(1), LibreSensorState.notYetStarted), (2, .starting), (5, .shutdown)] {
            let outcome = process(LibreDataParser(), data: standardFRAM(state: byte).data())
            XCTAssertEqual(outcome.completions.first?.0, state)
            XCTAssertNotNil(outcome.completions.first?.1)
            XCTAssertTrue(outcome.spy.receivedGlucose.isEmpty)
            XCTAssertTrue(outcome.spy.errors.isEmpty)
            XCTAssertTrue(outcome.spy.healthEvents.isEmpty)
        }
    }

    func testUnknownStateReportsErrorToDelegate() {
        let outcome = process(LibreDataParser(), data: standardFRAM(state: 0x09).data())
        XCTAssertEqual(outcome.completions.first?.0, .unknown)
        XCTAssertEqual(outcome.spy.errors.count, 1)
        XCTAssertEqual(outcome.spy.errors.first?.errorDescription, LibreError.sensorNotReady.errorDescription)
        XCTAssertTrue(outcome.spy.receivedGlucose.isEmpty)
    }

    func testExpiredSensorStillDeliversReadings() {
        let outcome = process(LibreDataParser(), data: standardFRAM(state: 4, minutes: 20_500).data())
        XCTAssertEqual(outcome.completions.first?.0, .expired)
        XCTAssertEqual(outcome.glucose.count, 47)
        XCTAssertEqual(outcome.spy.healthEvents, [.recovered(source: .libre)])
    }

    // MARK: - routing

    func testUnknownPatchInfoStopsProcessing() {
        let outcome = process(LibreDataParser(), data: standardFRAM().data(), patchInfo: "AB0000000000")
        XCTAssertTrue(outcome.completions.isEmpty)
        XCTAssertTrue(outcome.spy.receivedGlucose.isEmpty)
    }

    func testLibreUSWithWebOOPReportsUnsupported() {
        let outcome = process(LibreDataParser(), data: standardFRAM().data(), patchInfo: "E50003000000", webOOP: true, serial: "0ABC")
        XCTAssertEqual(outcome.spy.errors.map(\.errorDescription), [LibreOOPWebError.libreUSNotSupported.errorDescription])
        XCTAssertTrue(outcome.completions.isEmpty)
    }

    func testUndecryptedLibre2WithWebOOPIsIgnored() {
        let outcome = process(LibreDataParser(), data: standardFRAM().data(), patchInfo: "9D083001FB30", webOOP: true, serial: "3ABC")
        XCTAssertTrue(outcome.completions.isEmpty)
        XCTAssertTrue(outcome.spy.receivedGlucose.isEmpty)
        XCTAssertTrue(outcome.spy.errors.isEmpty)
    }

    func testWebOOPWithoutSerialNumberAndUndecryptedDataIsIgnored() {
        let outcome = process(LibreDataParser(), data: standardFRAM().data(), webOOP: true, serial: nil)
        XCTAssertTrue(outcome.completions.isEmpty)
        XCTAssertTrue(outcome.spy.receivedGlucose.isEmpty)
    }

    func testDecryptedDataWithoutSerialFallsBackToLocalParsing() {
        let outcome = process(LibreDataParser(), data: standardFRAM().data(), patchInfo: "9D083001FB30", webOOP: true, serial: nil, decrypted: true)
        XCTAssertEqual(outcome.glucose.first.map { ($0.glucoseLevelRaw / multiplier).rounded() }, 300)
        XCTAssertNil(UserDefaults.standard.libre1DerivedAlgorithmParameters)
    }

    // MARK: - derived algorithm path

    func testWebOOPDerivesAndStoresParametersForTheSensor() throws {
        let data = standardFRAM().data()
        let outcome = process(LibreDataParser(), data: data, webOOP: true, serial: "0SERIAL")
        let parameters = try XCTUnwrap(UserDefaults.standard.libre1DerivedAlgorithmParameters)
        XCTAssertEqual(parameters.serialNumber, "0SERIAL")
        let newestRecord = data.subdata(in: (28 + 6 * 6)..<(28 + 6 * 6 + 6))
        let expected = LibreMeasurement(bytes: newestRecord, date: now, libre1DerivedAlgorithmParameters: parameters).temperatureAlgorithmGlucose
        XCTAssertEqual(outcome.glucose.first?.glucoseLevelRaw ?? .nan, expected, accuracy: 1e-9)
        XCTAssertEqual(outcome.glucose.first?.timeStamp, now)
        XCTAssertEqual(outcome.completions.first?.0, .ready)
    }

    /// Blank calibration info (i2 = 0) has no calibration table entry. Parameters derived from it would
    /// all be 0 and, stored per sensor, make every later reading 0; so none are stored, nothing is
    /// delivered, and the next data with usable calibration info derives them.
    func testBlankCalibrationInfoStoresNoParametersAndTheNextUsableDataDerivesThem() {
        var blank = standardFRAM()
        blank.calibrationI2 = 0
        let outcome = process(LibreDataParser(), data: blank.data(), webOOP: true, serial: "0BLANK")
        XCTAssertNil(UserDefaults.standard.libre1DerivedAlgorithmParameters)
        XCTAssertTrue(outcome.glucose.isEmpty)

        process(LibreDataParser(), data: standardFRAM().data(), webOOP: true, serial: "0BLANK")
        XCTAssertEqual(UserDefaults.standard.libre1DerivedAlgorithmParameters?.serialNumber, "0BLANK")
    }

    func testStoredParametersOfAnotherSensorAreReplaced() {
        UserDefaults.standard.libre1DerivedAlgorithmParameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 1, offset_offset: 0, isValidForFooterWithReverseCRCs: 0, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "OLD")
        process(LibreDataParser(), data: standardFRAM().data(), webOOP: true, serial: "NEW")
        XCTAssertEqual(UserDefaults.standard.libre1DerivedAlgorithmParameters?.serialNumber, "NEW")
        XCTAssertNotEqual(UserDefaults.standard.libre1DerivedAlgorithmParameters?.offset_slope, 1)
    }

    func testStoredParametersOfTheSameSensorAreReused() {
        UserDefaults.standard.libre1DerivedAlgorithmParameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 1, offset_offset: 0, isValidForFooterWithReverseCRCs: 0, extraSlope: 2, extraOffset: 1, sensorSerialNumber: "SAME")
        let glucose = process(LibreDataParser(), data: standardFRAM().data(), webOOP: true, serial: "SAME").glucose
        XCTAssertEqual(glucose.first?.glucoseLevelRaw, 601)
        XCTAssertEqual(glucose.count, 16 + 31)
    }

    func testDecryptedLibre2WithSerialUsesDerivedAlgorithm() {
        UserDefaults.standard.libre1DerivedAlgorithmParameters = Libre1DerivedAlgorithmParameters(slope_slope: 0, slope_offset: 0, offset_slope: 1, offset_offset: 0, isValidForFooterWithReverseCRCs: 0, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "3X")
        let glucose = process(LibreDataParser(), data: standardFRAM().data(), patchInfo: "9D083001FB30", webOOP: true, serial: "3X", decrypted: true).glucose
        XCTAssertEqual(glucose.first?.glucoseLevelRaw, 300)
    }

    // MARK: - Libre Pro H layout

    func testProHLayoutUsesItsOwnOffsets() {
        var bytes = [UInt8](repeating: 0, count: 344)
        bytes[4] = 3
        bytes[74] = UInt8(1000 & 0xFF)
        bytes[75] = UInt8(1000 >> 8)
        bytes[76] = 4
        for k in 0..<16 {
            var slot = 4 - k - 1
            if slot < 0 { slot += 16 }
            bytes[80 + slot * 6] = UInt8(200 + k)
        }
        // history slot 0 shares its bytes with trend slot 15 and is never read
        for slot in 1..<28 { bytes[170 + slot * 6] = 150 }
        let outcome = process(LibreDataParser(), data: Data(bytes), patchInfo: "700000000000")
        let glucose = outcome.glucose
        XCTAssertEqual(outcome.completions.first?.0, .ready)
        XCTAssertEqual(glucose.prefix(16).map { ($0.glucoseLevelRaw / multiplier).rounded() }, (0..<16).map { Double(200 + $0) })
        XCTAssertGreaterThan(glucose.count, 16)
        XCTAssertTrue(glucose.dropFirst(16).allSatisfy { ($0.glucoseLevelRaw / multiplier).rounded() == 150 })
        XCTAssertEqual(outcome.spy.receivedSensorAges, [1000 * 60])
    }

    // MARK: - real decrypted Libre 2 data

    func testRealDecryptedLibre2BlockIsParsedLocally() {
        let decrypted = Data(PreLibre2.decryptFRAM(
            Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoUID)),
            Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoPatchInfo)),
            Array(LibreCoverageBytes.data(hex: LibreCoverageSamples.miaoMiaoEncryptedFRAM))))
        let outcome = process(LibreDataParser(), data: decrypted, patchInfo: LibreCoverageSamples.miaoMiaoPatchInfo, decrypted: true)
        XCTAssertEqual(outcome.completions.first?.0, .ready)
        XCTAssertEqual(outcome.spy.receivedSensorAges, [1030 * 60])
        let glucose = outcome.glucose
        XCTAssertGreaterThanOrEqual(glucose.count, 40)
        XCTAssertEqual(glucose.first?.timeStamp, now)
        XCTAssertEqual(glucose.map(\.timeStamp), glucose.map(\.timeStamp).sorted(by: >), "readings are ordered newest first")
        XCTAssertTrue(glucose.allSatisfy { $0.glucoseLevelRaw > 0 && $0.glucoseLevelRaw < 8192 * multiplier })
    }

    // MARK: - MiaoMiao test entry points

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func testMiaoMiaoSamplePacketIsDecryptedCheckedAndParsed() {
        let spy = LibreCoverageCGMDelegateSpy()
        CGMMiaoMiaoTransmitter.testPeripheralDidUpdateValue(libreDataAsHexString: nil, serialNumberAsHexString: nil, patchInfoAsHexString: nil, cGMTransmitterDelegate: spy, libreDataParser: LibreDataParser(), testTimeStamp: now)
        drainMainQueue()
        XCTAssertEqual(spy.receivedGlucose.count, 1)
        XCTAssertEqual(spy.receivedSensorAges, [1030 * 60])
        XCTAssertEqual(spy.receivedGlucose.first?.first?.timeStamp, now)
        XCTAssertEqual(UserDefaults.standard.libre1DerivedAlgorithmParameters?.serialNumber, "3MH00199R7W")
    }

    func testMiaoMiaoPacketWithBadCRCIsDropped() {
        var corrupted = standardFRAM().bytes()
        corrupted[100] ^= 0xFF
        let spy = LibreCoverageCGMDelegateSpy()
        CGMMiaoMiaoTransmitter.testPeripheralDidUpdateValue(libreDataAsHexString: Data(corrupted).hexEncodedString(), serialNumberAsHexString: "0000000000a007e0", patchInfoAsHexString: "DF0000080000", cGMTransmitterDelegate: spy, libreDataParser: LibreDataParser(), testTimeStamp: now)
        drainMainQueue()
        XCTAssertTrue(spy.receivedGlucose.isEmpty)
    }

    func testMiaoMiaoLibre1PacketUsesDerivedAlgorithm() {
        let spy = LibreCoverageCGMDelegateSpy()
        CGMMiaoMiaoTransmitter.testPeripheralDidUpdateValue(libreDataAsHexString: standardFRAM().data().hexEncodedString(), serialNumberAsHexString: "5e90250000a007e0", patchInfoAsHexString: "DF0000080000", cGMTransmitterDelegate: spy, libreDataParser: LibreDataParser(), testTimeStamp: now)
        drainMainQueue()
        XCTAssertEqual(spy.receivedGlucose.first?.count, 47)
        XCTAssertEqual(UserDefaults.standard.libre1DerivedAlgorithmParameters?.serialNumber, "0M00009DHCR")
    }

}
