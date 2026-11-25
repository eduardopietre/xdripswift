//
//  DateExtensionTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers the `Date` helpers with a pinned time zone, at the rounding and format boundaries.
///
/// The local-time helpers read `Calendar.current`, so results depend on the device time zone. Each
/// test pins the default time zone (including a half-hour offset zone, where whole-hour arithmetic
/// goes wrong first) and restores it afterwards. Millisecond conversions feed Nightscout and
/// Dexcom Share uploads, where an off-by-one rounding creates duplicate or missing entries.
final class DateExtensionTests: XCTestCase {

    // MARK: - properties

    private var savedTimeZone: TimeZone!

    /// 2026-01-15 00:10:00 UTC, which is 05:40 in India (UTC+5:30) and 14:10 the day before in Hawaii.
    private let referenceDate = Date(timeIntervalSince1970: 1_768_435_800)

    // MARK: - set up

    override func setUp() {
        super.setUp()
        savedTimeZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = savedTimeZone
        super.tearDown()
    }

    // MARK: - millisecond and second conversions

    /// Milliseconds round to the nearest value, also before 1970, and half seconds round away from
    /// zero. `Date` stores seconds since 2001, so sub-millisecond ties near 1970 are not exact and
    /// are deliberately avoided for the millisecond checks.
    func testMillisecondAndSecondConversionsRoundToNearest() {
        XCTAssertEqual(Date(timeIntervalSince1970: 0.0006).toMillisecondsAsInt64(), 1)
        XCTAssertEqual(Date(timeIntervalSince1970: 0.0004).toMillisecondsAsInt64(), 0)
        XCTAssertEqual(Date(timeIntervalSince1970: -0.0016).toMillisecondsAsInt64(), -2)
        XCTAssertEqual(Date(timeIntervalSince1970: -0.0015).toMillisecondsAsDouble(), -1.5, accuracy: 0.000_1)
        XCTAssertEqual(Date(timeIntervalSince1970: 0.5).toSecondsAsInt64(), 1)
        XCTAssertEqual(Date(timeIntervalSince1970: 1.49).toSecondsAsInt64(), 1)
        XCTAssertEqual(Date(timeIntervalSince1970: -0.5).toSecondsAsInt64(), -1)
    }

    /// The millisecond value of a real reading date must round-trip back to the same date.
    func testMillisecondsRoundTripForARealReadingDate() {
        let date = Date(timeIntervalSince1970: 1_768_435_800.123)
        let milliseconds = date.toMillisecondsAsInt64()

        XCTAssertEqual(milliseconds, 1_768_435_800_123)
        XCTAssertEqual(Date(timeIntervalSince1970: Double(milliseconds) / 1000).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.000_5)
    }

    // MARK: - toLowerHour

    /// `toLowerHour` floors, so dates before the reference date move back to the previous hour
    /// instead of being truncated towards zero.
    func testToLowerHourFloorsAlsoBeforeTheReferenceDate() {
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: -1).toLowerHour(), Date(timeIntervalSinceReferenceDate: -3600))
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: 3599.999).toLowerHour(), Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: 3600).toLowerHour(), Date(timeIntervalSinceReferenceDate: 3600))
    }

    // MARK: - local time helpers

    /// Minutes since midnight follow the device time zone, including half-hour offsets.
    func testMinutesSinceMidnightFollowTheDeviceTimeZone() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(referenceDate.minutesSinceMidNightLocalTime(), 10)

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        XCTAssertEqual(referenceDate.minutesSinceMidNightLocalTime(), 5 * 60 + 40)

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        XCTAssertEqual(referenceDate.minutesSinceMidNightLocalTime(), 14 * 60 + 10)
    }

    /// Local midnight in a UTC+5:30 zone is 18:30 UTC of the previous day.
    func testToMidnightUsesLocalMidnightInAHalfHourOffsetZone() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))

        let midnight = referenceDate.addingTimeInterval(17).toMidnight()

        // 2026-01-14 18:30:00 UTC
        XCTAssertEqual(midnight, Date(timeIntervalSince1970: 1_768_415_400))
        XCTAssertEqual(midnight.minutesSinceMidNightLocalTime(), 0)
    }

    /// One second before local midnight still belongs to the same local day.
    func testToMidnightOneSecondBeforeMidnightStaysOnTheSameDay() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let lastSecondOfDay = Date(timeIntervalSince1970: 1_768_435_200 + 86_399)

        XCTAssertEqual(lastSecondOfDay.toMidnight(), Date(timeIntervalSince1970: 1_768_435_200))
        XCTAssertEqual(lastSecondOfDay.minutesSinceMidNightLocalTime(), 1439)
    }

    /// Regression: `toMidnight()` subtracted hours × 3600 + minutes × 60 + seconds, which is one
    /// hour off on days when the clock changes. On 2026-03-29 in Amsterdam the clock jumps from
    /// 02:00 to 03:00, so 05:00 is only four hours after midnight and the old code returned 23:00
    /// of the day before. The BG readings, treatments and landscape date ranges start there.
    func testToMidnightOnTheSpringForwardDay() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        // 2026-03-29 05:00 CEST = 03:00 UTC
        let morning = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T03:00:00Z"))

        // 2026-03-29 00:00 CET = 2026-03-28 23:00 UTC
        XCTAssertEqual(morning.toMidnight(), ISO8601DateFormatter().date(from: "2026-03-28T23:00:00Z"))
    }

    /// On 2026-10-25 in Amsterdam the clock goes back from 03:00 to 02:00, so 05:00 is six hours
    /// after midnight and the old code returned 01:00 of the same day.
    func testToMidnightOnTheFallBackDay() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        // 2026-10-25 05:00 CET = 04:00 UTC
        let morning = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T04:00:00Z"))

        // 2026-10-25 00:00 CEST = 2026-10-24 22:00 UTC
        XCTAssertEqual(morning.toMidnight(), ISO8601DateFormatter().date(from: "2026-10-24T22:00:00Z"))
    }

    /// Brazil used to change the clock at midnight: on 2018-11-04 in São Paulo the day started at
    /// 01:00, because 00:00 to 00:59 did not exist. The start of that day is 01:00.
    func testToMidnightOnADayThatHasNoMidnight() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        // 2018-11-04 10:00 BRST (UTC-2) = 12:00 UTC
        let morning = try XCTUnwrap(ISO8601DateFormatter().date(from: "2018-11-04T12:00:00Z"))

        // 2018-11-04 01:00 BRST = 03:00 UTC
        XCTAssertEqual(morning.toMidnight(), ISO8601DateFormatter().date(from: "2018-11-04T03:00:00Z"))
    }

    /// The old code kept the fraction of a second, so midnight of 05:00:00.5 was 00:00:00.5.
    func testToMidnightDropsFractionsOfASecond() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_768_435_200 + 5 * 3600 + 0.5)

        XCTAssertEqual(date.toMidnight(), Date(timeIntervalSince1970: 1_768_435_200))
    }

    // MARK: - ISO and trace strings

    /// ISO strings are always UTC with a `Z` suffix, whatever the device time zone.
    func testISOStringsAreIndependentOfTheDeviceTimeZone() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))

        XCTAssertEqual(referenceDate.ISOStringFromDate(), "2026-01-15T00:10:00.000Z")
        XCTAssertEqual(Date.fromISOString("2026-01-15T00:10:00.000Z"), referenceDate)
        // An offset instead of the literal Z is not accepted by the fixed format.
        XCTAssertNil(Date.fromISOString("2026-01-15T05:40:00.000+05:30"))
    }

    /// Date-only trace strings stay on the UTC calendar day for users west of UTC.
    func testDateOnlyTraceStringIgnoresTheDeviceTimeZone() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))

        XCTAssertEqual(referenceDate.toDateOnlyStringForTrace(), "2026-01-15")
        XCTAssertEqual(Date(timeIntervalSince1970: 1_768_435_200 - 1).toDateOnlyStringForTrace(), "2026-01-14")
    }

    // MARK: - relative age strings

    /// The trace age string switches from minutes to hours at one hour and to days at one day.
    func testDaysAndHoursAgoSwitchesUnitAtOneHourAndOneDay() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date()

        XCTAssertEqual(now.addingTimeInterval(-(59 * 60 + 30)).daysAndHoursAgo(forTrace: true), "59m")
        XCTAssertEqual(now.addingTimeInterval(-(3600 + 30)).daysAndHoursAgo(forTrace: true), "1h")
        XCTAssertEqual(now.addingTimeInterval(-(23 * 3600 + 59 * 60 + 30)).daysAndHoursAgo(forTrace: true), "23h")
        XCTAssertEqual(now.addingTimeInterval(-(86_400 + 30)).daysAndHoursAgo(forTrace: true), "1d0h")
        XCTAssertEqual(now.addingTimeInterval(-(86_400 + 30)).daysAndHoursAgo(showOnlyHours: true, forTrace: true), "24h")
    }

    /// The remaining time adds one minute so that 59 seconds left is not shown as "0m", and keeps
    /// minutes only below twelve hours.
    func testDaysAndHoursRemainingRoundsUpAndDropsMinutesFromTwelveHours() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date()
        let minute = Texts_Common.minuteshort
        let hour = Texts_Common.hourshort
        let day = Texts_Common.dayshort

        XCTAssertEqual(now.addingTimeInterval(30).daysAndHoursRemaining(), "1" + minute)
        XCTAssertEqual(now.addingTimeInterval(11 * 3600 + 58 * 60 + 30).daysAndHoursRemaining(), "11" + hour + "59" + minute)
        XCTAssertEqual(now.addingTimeInterval(12 * 3600 + 30).daysAndHoursRemaining(), "0" + day + "12" + hour)
    }
}
