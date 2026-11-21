//
//  DataCoverageExtensionsTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreBluetooth
import XCTest
@testable import xdrip

final class DataCoverageExtensionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: - Array<GlucoseData>

    func testFill0GapsInterpolatesSingleAndDoubleGapsLinearly() {
        let data = glucoseData([10, 0, 20, 0, 0, 50])
        data.fill0Gaps(maxGapWidth: 3)
        XCTAssertEqual(data.map(\.glucoseLevelRaw), [10, 15, 20, 30, 40, 50])
    }

    func testFill0GapsLeavesGapsWiderThanMaxGapWidth() {
        let data = glucoseData([10, 0, 0, 40, 0, 60])
        data.fill0Gaps(maxGapWidth: 1)
        XCTAssertEqual(data.map(\.glucoseLevelRaw), [10, 0, 0, 40, 50, 60])
    }

    func testFill0GapsDoesNotFillLeadingOrTrailingZeros() {
        let leading = glucoseData([0, 0, 10, 0, 30])
        leading.fill0Gaps(maxGapWidth: 5)
        XCTAssertEqual(leading.map(\.glucoseLevelRaw), [0, 0, 10, 20, 30])

        let trailing = glucoseData([10, 20, 0, 0])
        trailing.fill0Gaps(maxGapWidth: 5)
        XCTAssertEqual(trailing.map(\.glucoseLevelRaw), [10, 20, 0, 0])

        let empty = glucoseData([])
        empty.fill0Gaps(maxGapWidth: 5)
        XCTAssertTrue(empty.isEmpty)
    }

    func testGlucoseDataHasEqualValuesComparesPrefixAndLength() {
        let data = glucoseData([1, 2, 3])
        XCTAssertTrue(data.hasEqualValues(howManyToCheck: 3, otherArray: [1, 2, 3]))
        XCTAssertTrue(data.hasEqualValues(howManyToCheck: 2, otherArray: [1, 2, 9]))
        XCTAssertFalse(data.hasEqualValues(howManyToCheck: 3, otherArray: [1, 2, 9]))
        XCTAssertFalse(data.hasEqualValues(howManyToCheck: 4, otherArray: [1, 2, 3, 4]))
        XCTAssertTrue(data.hasEqualValues(howManyToCheck: 10, otherArray: [1, 2, 3]))
        XCTAssertFalse(glucoseData([1, 2]).hasEqualValues(howManyToCheck: 3, otherArray: [1, 2, 3]))
    }

    func testIntArrayHasEqualValues() {
        XCTAssertTrue([1, 2, 3].hasEqualValues(howManyToCheck: 3, otherArray: [1, 2, 3]))
        XCTAssertFalse([1, 2, 3].hasEqualValues(howManyToCheck: 3, otherArray: [1, 2, 4]))
        XCTAssertTrue([1, 2, 3].hasEqualValues(howManyToCheck: 2, otherArray: [1, 2, 4]))
        XCTAssertFalse([1, 2].hasEqualValues(howManyToCheck: 3, otherArray: [1, 2, 3]))
        XCTAssertFalse([1, 2, 3].hasEqualValues(howManyToCheck: 3, otherArray: [1, 2]))
        XCTAssertTrue([1, 2].hasEqualValues(howManyToCheck: 5, otherArray: [1, 2]))
        XCTAssertTrue([Int]().hasEqualValues(howManyToCheck: 0, otherArray: [7]))
    }

    // MARK: - Array<BgReading> and Array<BgReadingSnapshot> filtering

    func testBgReadingFilterWithoutLastProcessedKeepsReadingsAtLeastMinimumApart() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let readings = [0, 1, 3, 5, 6, 10].map { bgReading(minutesAgo: $0, core: core) }
        let filtered = readings.filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: nil, timeStampLastProcessedBgReading: nil)
        XCTAssertEqual(filtered.map { $0.id }, [readings[0].id, readings[4].id])
    }

    func testBgReadingFilterStopsAtLastProcessedReading() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let readings = [0, 1, 3, 5, 6, 10].map { bgReading(minutesAgo: $0, core: core) }
        let filtered = readings.filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: nil, timeStampLastProcessedBgReading: now.addingTimeInterval(-8 * 60))
        XCTAssertEqual(filtered.map { $0.id }, [readings[0].id, readings[4].id])
    }

    func testBgReadingFilterReturnsNothingWhenLatestIsTooCloseToLastProcessed() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let readings = [0, 1, 3].map { bgReading(minutesAgo: $0, core: core) }
        let lastProcessed = now.addingTimeInterval(-2 * 60)
        XCTAssertTrue(readings.filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: nil, timeStampLastProcessedBgReading: lastProcessed).isEmpty)
        XCTAssertTrue(readings.filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: now.addingTimeInterval(-10 * 60), timeStampLastProcessedBgReading: lastProcessed).isEmpty)
        let afterReconnect = readings.filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: now.addingTimeInterval(-60), timeStampLastProcessedBgReading: lastProcessed)
        XCTAssertEqual(afterReconnect.map { $0.id }, [readings[0].id])
        XCTAssertTrue([BgReading]().filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: nil, timeStampLastProcessedBgReading: nil).isEmpty)
    }

    func testSnapshotFilterMatchesManagedObjectFilter() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let readings = [0, 1, 3, 5, 6, 10, 12].map { bgReading(minutesAgo: $0, core: core) }
        let snapshots = readings.map(snapshot)
        for lastProcessed in [nil, now.addingTimeInterval(-8 * 60), now.addingTimeInterval(-2 * 60)] {
            for reconnect in [nil, now.addingTimeInterval(-60)] {
                let managed = readings.filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: reconnect, timeStampLastProcessedBgReading: lastProcessed)
                let values = snapshots.filter(minimumTimeBetweenTwoReadingsInMinutes: 5, lastConnectionStatusChangeTimeStamp: reconnect, timeStampLastProcessedBgReading: lastProcessed)
                XCTAssertEqual(managed.map { $0.id }, values.map(\.id))
            }
        }
    }

    // MARK: - Double

    func testDoubleRawRepresentableAndTrailingZeroes() {
        XCTAssertEqual(Double(rawValue: 4.5), 4.5)
        XCTAssertEqual(4.5.rawValue, 4.5)
        XCTAssertEqual(5.0.stringWithoutTrailingZeroes, "5")
        XCTAssertEqual(5.25.stringWithoutTrailingZeroes, "5.25")
        XCTAssertEqual((-3.0).stringWithoutTrailingZeroes, "-3")
    }

    func testDoubleUnitConversionsRoundTrip() {
        XCTAssertEqual(100.0.mgDlToMmol(), 5.55, accuracy: 0.000_001)
        XCTAssertEqual(100.0.mgDlToMmol(mgDl: true), 100)
        XCTAssertEqual(100.0.mgDlToMmol(mgDl: false), 5.55, accuracy: 0.000_001)
        XCTAssertEqual(5.55.mmolToMgdl(), 100, accuracy: 0.000_001)
        XCTAssertEqual(5.55.mmolToMgdl(mgDl: true), 5.55)
        XCTAssertEqual(10.0.mmolToMgdl(mgDl: false), 180.18018, accuracy: 0.0001)
        XCTAssertEqual(180.0.mgDlToMmol().mmolToMgdl(), 180, accuracy: 0.000_001)
    }

    func testDoubleRoundingAndBgStrings() {
        XCTAssertEqual(1.23456.round(toDecimalPlaces: 2), 1.23)
        XCTAssertEqual(1.235_01.round(toDecimalPlaces: 2), 1.24)
        XCTAssertEqual(99.6.bgValueToString(mgDl: true), "100")
        XCTAssertEqual(5.56.bgValueToString(mgDl: false), "5.6")
        XCTAssertEqual(99.6.bgValueRounded(mgDl: true), 100)
        XCTAssertEqual(5.56.bgValueRounded(mgDl: false), 5.6, accuracy: 0.000_001)
        XCTAssertEqual(180.0.mgDlToMmolAndToString(mgDl: true), "180")
        XCTAssertEqual(180.0.mgDlToMmolAndToString(mgDl: false), "10.0")
        XCTAssertEqual(5.0.mmolToString(), "5.0")
        XCTAssertEqual(12.345.mmolToString(), "12.3")
    }

    func testDoubleMillisecondTimestampString() {
        let milliseconds = 1_642_028_657_190.0
        XCTAssertEqual(milliseconds.asTimeStampInMilliSecondsToString(), Date(timeIntervalSince1970: 1_642_028_657.19).description(with: .current))
    }

    func testMinutesToDaysAndHoursUsesMinutesHoursOrDays() {
        XCTAssertEqual(0.0.minutesToDaysAndHours(), "0m")
        XCTAssertEqual(12.0.minutesToDaysAndHours(), "12m")
        XCTAssertEqual(78.0.minutesToDaysAndHours(), "1h18m")
        XCTAssertEqual(719.0.minutesToDaysAndHours(), "11h59m")
        XCTAssertEqual(720.0.minutesToDaysAndHours(), "0d12h")
        XCTAssertEqual(1500.0.minutesToDaysAndHours(), "1d1h")
        XCTAssertEqual(9300.0.minutesToDaysAndHours(), "6d11h")
    }

    func testDoubleSmoothableValueReadsAndWritesSelf() {
        var value = 1.5
        XCTAssertEqual(value.value, 1.5)
        value.value = 2.5
        XCTAssertEqual(value, 2.5)
    }

    // MARK: - Integers

    func testIntToByteArrayIsLittleEndianAndFullWidth() {
        XCTAssertEqual(1.toByteArray(), [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(0x0102.toByteArray(), [2, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(0x7FFF_FFFF.toByteArray(), [0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0])
        XCTAssertEqual(0x0A0B.toData(), Data([0x0B, 0x0A, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual((-1).toByteArray(), Array(repeating: UInt8(0xFF), count: 8))
    }

    func testMinutesToTimeStringIsConsistentAcrossIntegerTypes() {
        let expected = 1068.convertMinutesToTimeAsString()
        XCTAssertTrue(expected.contains("48"))
        XCTAssertEqual(Int16(1068).convertMinutesToTimeAsString(), expected)
        XCTAssertEqual(UInt16(1068).convertMinutesToTimeAsString(), expected)
        XCTAssertNotEqual(0.convertMinutesToTimeAsString(), expected)
    }

    func testUInt16InitializersAndData() {
        XCTAssertEqual(UInt16(0x12, 0x34), 0x1234)
        XCTAssertEqual(UInt16(Data([0x34, 0x12])), 0x1234)
        let slice = Data([0x00, 0x78, 0x56, 0xFF]).dropFirst()
        XCTAssertEqual(UInt16(Data(slice)), 0x5678)
        XCTAssertEqual(UInt16(slice), 0x5678)
        XCTAssertEqual(UInt16(0x1234).data, Data([0x34, 0x12]))
    }

    func testUInt32AndUInt8DataEncoding() {
        XCTAssertEqual(UInt32(0x0102_0304).data, Data([4, 3, 2, 1]))
        XCTAssertEqual(UInt32(0x0102_0304).byteArrayLittleEndian, [1, 2, 3, 4])
        XCTAssertEqual(UInt8(0xAB).data, Data([0xAB]))
    }

    // MARK: - TimeInterval

    func testTimeIntervalFactoriesAndAccessors() {
        XCTAssertEqual(TimeInterval.seconds(5), 5)
        XCTAssertEqual(TimeInterval.minutes(2), 120)
        XCTAssertEqual(TimeInterval.hours(1.5), 5400)
        XCTAssertEqual(TimeInterval.days(1), 86400)
        XCTAssertEqual(TimeInterval(minutes: 3), 180)
        XCTAssertEqual(TimeInterval(hours: 2), 7200)
        XCTAssertEqual(TimeInterval(days: 2), 172_800)
        let interval: TimeInterval = 7200
        XCTAssertEqual(interval.minutes, 120)
        XCTAssertEqual(interval.hours, 2)
        XCTAssertEqual(interval.days, 1.0 / 12.0, accuracy: 0.000_001)
    }

    // MARK: - StringProtocol and String

    func testIndexesFindsAllNonOverlappingMatches() {
        XCTAssertEqual("a,b,,c".indexes(of: ",").count, 3)
        XCTAssertEqual("aaaa".indexes(of: "aa").count, 2)
        XCTAssertEqual("abc".indexes(of: "x").count, 0)
        XCTAssertEqual("ABab".indexes(of: "ab", options: .caseInsensitive).count, 2)
        let text = "hello world"
        XCTAssertEqual(text.indexes(of: "o").map { text.distance(from: text.startIndex, to: $0) }, [4, 7])
    }

    func testStringRangeSubscriptClampsBounds() {
        XCTAssertEqual("hello"[0..<3], "hel")
        XCTAssertEqual("hello"[3..<10], "lo")
        XCTAssertEqual("hello"[-2..<2], "he")
        XCTAssertEqual("hello"[2..<2], "")
    }

    func testStringRegexPrefixAndContainsHelpers() throws {
        let regex = try NSRegularExpression(pattern: "^[0-9]{3}$")
        XCTAssertTrue("123".validate(withRegex: regex))
        XCTAssertFalse("12a".validate(withRegex: regex))
        XCTAssertTrue("HTTPS://site".startsWith("https://"))
        XCTAssertFalse("site".startsWith("https://"))
        XCTAssertTrue("abcdef".contains(find: "cd"))
        XCTAssertFalse("abcdef".contains(find: "CD"))
        XCTAssertTrue("abcdef".containsIgnoringCase(find: "CD"))
        XCTAssertFalse("abcdef".containsIgnoringCase(find: "xy"))
    }

    func testStringToDoubleAcceptsCommaAndDotDecimalSeparators() {
        XCTAssertEqual("1.5".toDouble(), 1.5)
        XCTAssertEqual("1,5".toDouble(), 1.5)
        XCTAssertEqual("-12".toDouble(), -12)
        XCTAssertNil("".toDouble())
        XCTAssertNil("abc".toDouble())
        XCTAssertNil("1.2.3".toDouble())
        XCTAssertNil("1,2,3".toDouble())
    }

    func testStringHashes() {
        XCTAssertEqual("abc".sha1(), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual("abc".sha256(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual("".sha1(), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testStringEncodingHelpers() {
        XCTAssertEqual("abc".toNilIfLength0(), "abc")
        XCTAssertNil("".toNilIfLength0())
        XCTAssertEqual("a b&c=d~-._".stringByAddingPercentEscapesForQueryValue(), "a%20b%26c%3Dd~-._")
        XCTAssertEqual("hello".base64Encoded(), "aGVsbG8=")
        XCTAssertEqual("aGVsbG8=".base64Decoded(), Array("hello".utf8))
        XCTAssertNil("!!not base64".base64Decoded())
    }

    func testIndicatesOnTogglesAtEachScheduleEntry() throws {
        let schedule = "480-1080"
        XCTAssertTrue(schedule.indicatesOn(forWhen: try localDate(hour: 7, minute: 0)))
        XCTAssertFalse(schedule.indicatesOn(forWhen: try localDate(hour: 8, minute: 0)))
        XCTAssertFalse(schedule.indicatesOn(forWhen: try localDate(hour: 17, minute: 59)))
        XCTAssertTrue(schedule.indicatesOn(forWhen: try localDate(hour: 18, minute: 0)))
        XCTAssertTrue("".indicatesOn(forWhen: try localDate(hour: 12, minute: 0)))
        XCTAssertEqual("5-480-x-1080".splitToInt(), [5, 480, 0, 1080])
        XCTAssertEqual("".splitToInt(), [])
    }

    func testStringHexadecimalMatchesDataInitializer() {
        XCTAssertEqual("0aFF10".hexadecimal(), Data([0x0A, 0xFF, 0x10]))
        XCTAssertEqual("0aFF10".hexadecimal(), Data(hexadecimalString: "0aFF10"))
        XCTAssertNil("zz".hexadecimal())
        XCTAssertNil("".hexadecimal())
    }

    func testStringDateFromISOStringAndNewLineAppend() {
        XCTAssertEqual("2022-01-12T23:04:17.190+0000".dateFromISOString()?.timeIntervalSince1970 ?? 0, 1_642_028_657.19, accuracy: 0.001)
        XCTAssertNil("2022-01-12 23:04".dateFromISOString())
        var text = "a"
        text.appendStringAndNewLine("b")
        text.appendStringAndNewLine("")
        XCTAssertEqual(text, "ab\n\n")
    }

    func testObscuredKeepsLeadingCharactersAndCapsLength() {
        XCTAssertEqual("".obscured(), "")
        XCTAssertEqual("abc".obscured(), "***")
        XCTAssertEqual("abcd".obscured(), "a***")
        XCTAssertEqual("abcdef".obscured(), "ab****")
        XCTAssertEqual("abcdefgh".obscured(), "abc*****")
        XCTAssertEqual("abcdefghijk".obscured(), "abcd*******")
        XCTAssertEqual(String(repeating: "x", count: 26).obscured(), "xxxx********")
        XCTAssertEqual(String(repeating: "x", count: 60).obscured(), String(repeating: "*", count: 12))
    }

    func testCapitalizedSentenceAndHttpsNormalisation() {
        XCTAssertEqual("hELLO World".capitalizedSentence, "Hello world")
        XCTAssertEqual("".capitalizedSentence, "")
        XCTAssertNil(Optional<String>.none.addHttpsIfNeeded())
        XCTAssertEqual(Optional("example.com/").addHttpsIfNeeded(), "https://example.com")
        XCTAssertEqual(Optional("http://example.com").addHttpsIfNeeded(), "http://example.com")
        XCTAssertEqual(Optional("HTTPS://Example.com/").addHttpsIfNeeded(), "HTTPS://Example.com")
    }

    // MARK: - Data

    func testDataHexadecimalInitializerValidatesInput() {
        XCTAssertEqual(Data(hexadecimalString: "0a1B"), Data([0x0A, 0x1B]))
        XCTAssertEqual(Data(hexadecimalString: ""), Data())
        XCTAssertNil(Data(hexadecimalString: "abc"))
        XCTAssertNil(Data(hexadecimalString: "zz"))
        XCTAssertNil(Data(hexadecimalString: "0g"))
    }

    func testDataHexEncodingAndIntegerReads() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xFF])
        XCTAssertEqual(data.hexEncodedString(), "0102030405060708ff")
        XCTAssertEqual(data.uint8(position: 8), 0xFF)
        XCTAssertEqual(data.uint16(position: 0), 0x0201)
        XCTAssertEqual(data.uint32(position: 1), 0x0504_0302)
        XCTAssertEqual(data.uint64(position: 0), 0x0807_0605_0403_0201)
        XCTAssertEqual(data.getByteAt(position: 2), 3)
        XCTAssertEqual(Data([0x34, 0x12]).to(UInt16.self), 0x1234)
        let int32: Int32 = Data([0xFF, 0xFF, 0xFF, 0xFF]).toInt()
        XCTAssertEqual(int32, -1)
    }

    func testDataAppendFixedWidthIntegerIsLittleEndian() {
        var data = Data()
        data.append(UInt16(0x0102))
        data.append(Int32(-2))
        data.append(UInt8(9))
        XCTAssertEqual(data, Data([0x02, 0x01, 0xFE, 0xFF, 0xFF, 0xFF, 0x09]))
    }

    func testDataHexDumpFormatsRowsAddressesAndPrintableCharacters() {
        let data = Data("ABC".utf8) + Data([0x01])
        XCTAssertEqual(data.hexDump(), "41 42 43 01 " + String(repeating: " ", count: 12) + " ABC.")
        XCTAssertEqual(Data("AB".utf8).hexDump(address: 16, header: "H"), "H\n0010  41 42 " + String(repeating: " ", count: 18) + " AB")
        let twoRows = Data(Array("ABCDEFGHI".utf8)).hexDump()
        let rows = twoRows.components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], "41 42 43 44 45 46 47 48  ABCDEFGH")
        XCTAssertEqual(rows[1], "49 " + String(repeating: " ", count: 21) + " I")
        XCTAssertEqual(Data([0xAB, 0x01, 0x00]).hexAddress, "AB:01:00")
        XCTAssertEqual(Data().hexAddress, "")
    }

    // MARK: - Date

    func testDateMillisecondAndSecondConversions() {
        let date = Date(timeIntervalSince1970: 1.0006)
        XCTAssertEqual(date.toMillisecondsAsDouble(), 1000.6, accuracy: 0.000_1)
        XCTAssertEqual(date.toMillisecondsAsInt64(), 1001)
        XCTAssertEqual(Date(timeIntervalSince1970: 1.6).toSecondsAsInt64(), 2)
        XCTAssertEqual(Date(timeIntervalSince1970: -1.5).toMillisecondsAsDouble(), -1500)
    }

    func testDateMinutesSinceMidnightAndToMidnight() throws {
        let date = try localDate(hour: 5, minute: 20, second: 33)
        XCTAssertEqual(date.minutesSinceMidNightLocalTime(), 320)
        let midnight = date.toMidnight()
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: midnight)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
        XCTAssertEqual(Calendar.current.startOfDay(for: date), midnight)
    }

    func testDateISOStringRoundTripWithAndWithoutReusedFormatter() {
        let date = Date(timeIntervalSince1970: 1_642_028_657.19)
        XCTAssertEqual(date.ISOStringFromDate(), "2022-01-12T23:04:17.190Z")
        let formatter = Date.ISODateFormatter()
        XCTAssertEqual(date.ISOStringFromDate(reuseDateFormatter: formatter), "2022-01-12T23:04:17.190Z")
        XCTAssertEqual(date.ISOStringFromDate(reuseDateFormatter: nil), "2022-01-12T23:04:17.190Z")
        XCTAssertEqual(Date.fromISOString("2022-01-12T23:04:17.190Z")?.timeIntervalSince1970 ?? 0, 1_642_028_657.19, accuracy: 0.001)
        XCTAssertEqual(Date.fromISOString("2022-01-12T23:04:17.190Z", reuseDateFormatter: formatter), Date.fromISOString("2022-01-12T23:04:17.190Z"))
        XCTAssertNil(Date.fromISOString("2022-01-12T23:04:17Z"))
        XCTAssertNil(Date.fromISOString("garbage", reuseDateFormatter: nil))
    }

    func testDateTraceStringsUseFixedLocalesAndUTC() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(date.toDateOnlyStringForTrace(), "1970-01-01")
        XCTAssertEqual(Date(timeIntervalSince1970: 86_399).toDateOnlyStringForTrace(), "1970-01-01")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeStyle = .short
        formatter.dateStyle = .medium
        XCTAssertEqual(now.toStringForTrace(timeStyle: .short, dateStyle: .medium), formatter.string(from: now))
        let plain = DateFormatter()
        plain.timeStyle = .none
        plain.dateStyle = .long
        XCTAssertEqual(now.toString(timeStyle: .none, dateStyle: .long), plain.string(from: now))
    }

    func testDateUserLocaleStringsFollowTemplates() {
        func expected(_ template: String, timeZone: TimeZone? = nil) -> String {
            let formatter = DateFormatter()
            formatter.amSymbol = ConstantsUI.timeFormatAM
            formatter.pmSymbol = ConstantsUI.timeFormatPM
            if let timeZone { formatter.timeZone = timeZone }
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: now)
        }
        XCTAssertEqual(now.toStringInUserLocale(timeStyle: .none, dateStyle: .short), expected("dd/MM/yyyy"))
        XCTAssertEqual(now.toStringInUserLocale(timeStyle: .short, dateStyle: .none), expected("jj:mm"))
        XCTAssertEqual(now.toStringInUserLocale(timeStyle: .short, dateStyle: .none, showTimeZone: true), expected("jj:mm zzz"))
        XCTAssertEqual(now.toStringInUserLocale(timeStyle: .short, dateStyle: .short), expected("dd/MM/yyyy, jj:mm"))
        XCTAssertEqual(now.toStringInUserLocale(timeStyle: .short, dateStyle: .short, showTimeZone: true), expected("dd/MM/yyyy, jj:mm zzz"))
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(now.toStringInUserLocale(timeStyle: .none, dateStyle: .short, showTimeZone: nil, timeZone: utc), expected("dd/MM/yyyy", timeZone: utc))
    }

    func testToLowerHourTruncatesToTheHour() {
        let date = Date(timeIntervalSinceReferenceDate: 3600 * 100 + 1234)
        XCTAssertEqual(date.toLowerHour(), Date(timeIntervalSinceReferenceDate: 3600 * 100))
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: 7200).toLowerHour(), Date(timeIntervalSinceReferenceDate: 7200))
    }

    func testDaysAndHoursAgoForTraceVariants() {
        let twoDaysAgo = Date().addingTimeInterval(-(2 * 86_400 + 3 * 3600 + 120))
        XCTAssertEqual(twoDaysAgo.daysAndHoursAgo(forTrace: true), "2d3h")
        XCTAssertEqual(twoDaysAgo.daysAndHoursAgo(appendAgo: true, forTrace: true), "2d3h ago")
        XCTAssertEqual(twoDaysAgo.daysAndHoursAgo(showOnlyDays: true, forTrace: true), "2d")
        XCTAssertEqual(twoDaysAgo.daysAndHoursAgo(showOnlyHours: true, forTrace: true), "51h")
        XCTAssertEqual(Date().addingTimeInterval(-(30 * 60 + 5)).daysAndHoursAgo(forTrace: true), "30m")
        XCTAssertEqual(Date().addingTimeInterval(-(5 * 3600 + 120)).daysAndHoursAgo(forTrace: true), "5h")
        XCTAssertEqual(Date().addingTimeInterval(-(30 * 60 + 5)).daysAndHoursAgo(), "30" + Texts_Common.minuteshort)
    }

    func testDaysAndHoursAgoFullUsesSingularAndPluralTexts() {
        XCTAssertEqual(Date().addingTimeInterval(-(60 + 5)).daysAndHoursAgoFull(), "1 " + Texts_Common.minute)
        XCTAssertEqual(Date().addingTimeInterval(-(3600 + 2 * 60 + 5)).daysAndHoursAgoFull(), "1 " + Texts_Common.hour + " 2 " + Texts_Common.minutes)
        XCTAssertEqual(Date().addingTimeInterval(-(86_400 + 2 * 3600 + 5)).daysAndHoursAgoFull(appendAgo: true), "1 " + Texts_Common.day + " 2 " + Texts_Common.hours + " " + Texts_HomeView.ago)
    }

    func testDaysAndHoursRemainingRoundsUpOneMinute() {
        XCTAssertEqual(Date().addingTimeInterval(10 * 60 + 30).daysAndHoursRemaining(), "11" + Texts_Common.minuteshort)
        XCTAssertEqual(Date().addingTimeInterval(2 * 3600 + 30).daysAndHoursRemaining(), "2" + Texts_Common.hourshort + "1" + Texts_Common.minuteshort)
        let threeDays = Date().addingTimeInterval(3 * 86_400 + 4 * 3600 + 30)
        XCTAssertEqual(threeDays.daysAndHoursRemaining(), "3" + Texts_Common.dayshort + "4" + Texts_Common.hourshort)
        XCTAssertEqual(threeDays.daysAndHoursRemaining(appendRemaining: true, showOnlyDays: true), "3" + Texts_Common.dayshort + " " + Texts_HomeView.remaining)
    }

    // MARK: - Others

    func testURLRequestFormBodyIsPercentEncoded() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.setBodyContent(contentMap: ["user": "a b&c"])
        XCTAssertEqual(request.httpBody.flatMap { String(data: $0, encoding: .utf8) }, "user=a%20b%26c")
        request.setBodyContent(contentMap: [:])
        XCTAssertEqual(request.httpBody, Data())
    }

    func testURLFileAttributesForExistingAndMissingFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DataCoverage-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 10).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.fileSize, 10)
        XCTAssertNotNil(url.creationDate)
        XCTAssertEqual(url.fileSizeString, ByteCountFormatter.string(fromByteCount: 10, countStyle: .file))
        let missing = url.appendingPathExtension("missing")
        XCTAssertNil(missing.attributes)
        XCTAssertEqual(missing.fileSize, 0)
        XCTAssertNil(missing.creationDate)
    }

    func testChartWidthFallsBackToDefaultWhenUnset() throws {
        let name = "DataCoverageCharts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(defaults.chartWidthInHours, ConstantsGlucoseChart.defaultChartWidthInHours)
        defaults.chartWidthInHours = 12
        XCTAssertEqual(defaults.chartWidthInHours, 12)
        defaults.chartWidthInHours = 0
        XCTAssertEqual(defaults.chartWidthInHours, ConstantsGlucoseChart.defaultChartWidthInHours)
    }

    func testBluetoothStateDescriptions() {
        XCTAssertEqual(CBManagerState.poweredOff.toString(), "poweredOff")
        XCTAssertEqual(CBManagerState.poweredOn.toString(), "poweredOn")
        XCTAssertEqual(CBManagerState.resetting.toString(), "resetting")
        XCTAssertEqual(CBManagerState.unauthorized.toString(), "unauthorized")
        XCTAssertEqual(CBManagerState.unknown.toString(), "unknown")
        XCTAssertEqual(CBManagerState.unsupported.toString(), "unsupported")
        XCTAssertEqual(CBPeripheralState.connected.description(), "connected")
        XCTAssertEqual(CBPeripheralState.connecting.description(), "connecting")
        XCTAssertEqual(CBPeripheralState.disconnected.description(), "disconnected")
        XCTAssertEqual(CBPeripheralState.disconnecting.description(), "disconnecting")
    }

    func testBundleLoopShareFlagMatchesInfoDictionary() {
        let bundle = Bundle.main
        let raw = (bundle.object(forInfoDictionaryKey: "DisableLoopShare") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        XCTAssertEqual(bundle.disableLoopShare, ["YES", "TRUE", "1"].contains(raw ?? ""))
        if let suite = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String {
            XCTAssertEqual(bundle.appGroupSuiteName, suite)
        }
    }

    // MARK: - Helpers

    private func glucoseData(_ values: [Double]) -> [GlucoseData] {
        values.enumerated().map { GlucoseData(timeStamp: now.addingTimeInterval(Double($0.offset) * 60), glucoseLevelRaw: $0.element) }
    }

    private func bgReading(minutesAgo: Int, core: CoreDataManager) -> BgReading {
        let reading = BgReading(timeStamp: now.addingTimeInterval(-Double(minutesAgo) * 60), sensor: nil, calibration: nil, rawData: 100, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        reading.calculatedValue = 100
        return reading
    }

    private func snapshot(_ reading: BgReading) -> BgReadingSnapshot {
        BgReadingSnapshot(timeStamp: reading.timeStamp, calculatedValue: reading.calculatedValue, rawData: reading.rawData, finalValue: reading.finalValue, adjustedValue: nil, smoothedValue: nil, backfilledAt: nil, valueIsFromWatch: false, watchReceivedAt: nil, wasAlsoCollectedByWatch: false, calculatedValueSlope: 0, hideSlope: false, id: reading.id, deviceName: nil, calibrationSnapshot: nil, sensorID: nil, objectID: reading.objectID)
    }

    private func localDate(hour: Int, minute: Int, second: Int = 0) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute, second: second)))
    }
}
