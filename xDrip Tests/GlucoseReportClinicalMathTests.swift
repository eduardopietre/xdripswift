//
//  GlucoseReportClinicalMathTests.swift
//  xdripTests
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

/// Covers the clinical calculations and display geometry of the glucose report against values
/// computed by hand from the published formulas.
///
/// GMI (Bergenstal 2018), the inverse ADAG estimate (Nathan 2008) and the NGSP to IFCC master
/// equation are printed on a document that patients hand to clinicians, so a wrong coefficient or a
/// conversion of an already rounded value is a clinical error, not a cosmetic one. The AGP and
/// Loopalyzer helpers decide where bands and bars are drawn; they must wrap at midnight and never
/// draw outside the 0-1440 minute day.
final class GlucoseReportClinicalMathTests: XCTestCase {

    // MARK: - GMI and estimated HbA1c

    /// GMI(%) = 3.31 + 0.02392 x mean glucose (mg/dL). 154 mg/dL is the textbook example for ~7%.
    func testGMIPercentageFollowsTheBergenstalFormula() {
        XCTAssertEqual(GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 154), 6.993_68, accuracy: 0.000_001)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 100), 5.702, accuracy: 0.000_001)
        // The slope is per mg/dL: 10 mg/dL more always adds 0.2392 percentage points.
        let difference = GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 190)
            - GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 180)
        XCTAssertEqual(difference, 0.2392, accuracy: 0.000_001)
    }

    /// eA1c(%) = (mean + 46.7) / 28.7. For the same mean it differs from GMI, which is why the user
    /// chooses one of them explicitly.
    func testEstimatedHbA1cFollowsTheInverseADAGFormula() {
        XCTAssertEqual(GlucoseReportClinicalMath.estimatedHbA1cPercentage(forAverageMgDl: 154), 6.993_031, accuracy: 0.000_001)
        XCTAssertEqual(GlucoseReportClinicalMath.estimatedHbA1cPercentage(forAverageMgDl: 240), 9.989_547, accuracy: 0.000_001)
        XCTAssertEqual(GlucoseReportClinicalMath.estimatedHbA1cPercentage(forAverageMgDl: 0), 0)
        XCTAssertEqual(GlucoseReportClinicalMath.estimatedHbA1cPercentage(forAverageMgDl: -10), 0)
    }

    /// `statisticsPercentage` picks the requested estimate and guards against an empty average,
    /// while the raw GMI formula alone would report its 3.31% intercept for no data.
    func testStatisticsPercentageSelectsEstimateAndReportsNothingWithoutData() {
        XCTAssertEqual(
            GlucoseReportClinicalMath.statisticsPercentage(forAverageMgDl: 240, useHbA1c: true),
            GlucoseReportClinicalMath.estimatedHbA1cPercentage(forAverageMgDl: 240)
        )
        XCTAssertEqual(
            GlucoseReportClinicalMath.statisticsPercentage(forAverageMgDl: 240, useHbA1c: false),
            GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 240)
        )
        XCTAssertEqual(GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 0), 3.31, accuracy: 0.000_001)
        XCTAssertEqual(GlucoseReportClinicalMath.statisticsPercentage(forAverageMgDl: 0, useHbA1c: false), 0)
        XCTAssertEqual(GlucoseReportClinicalMath.statisticsPercentage(forAverageMgDl: -1, useHbA1c: true), 0)
    }

    /// IFCC (mmol/mol) = (NGSP - 2.152) / 0.09148. The clinical anchors are 6.5% = 48 and 7% = 53.
    func testIFCCConversionMatchesTheNGSPMasterEquationAnchors() {
        XCTAssertEqual(GlucoseReportClinicalMath.gmiValue(6.5, usesIFCC: true), 47.529_5, accuracy: 0.000_1)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiValue(7, usesIFCC: true), 52.995_2, accuracy: 0.000_1)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiValue(8, usesIFCC: true), 63.926_5, accuracy: 0.000_1)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiValue(6.5, usesIFCC: false), 6.5)
    }

    /// A trend point derives its GMI from its own average, so the trend chart and summary agree.
    func testTrendPointGMIUsesItsAverage() {
        let point = GlucoseReportTrendPoint(
            date: Date(timeIntervalSince1970: 0),
            interval: .weekly,
            averageMgDl: 154,
            coefficientOfVariation: 30,
            averageTDDPerDay: nil,
            averageCarbsPerDay: nil,
            sampleCount: 2016
        )

        XCTAssertEqual(point.gmiPercentage, 6.993_68, accuracy: 0.000_001)
    }

    // MARK: - GMI chart domain

    /// Without data the chart shows 5-10%, which in IFCC becomes 30-86 mmol/mol (31.1 and 85.8
    /// widened to even ticks).
    func testGMIDomainWithoutDataUsesTheDefaultRange() {
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [], usesIFCC: false), 5 ... 10)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [], usesIFCC: true), 30 ... 86)
    }

    /// The domain pads the data by 0.2 points and snaps outwards to half percent steps.
    func testGMIDomainPadsAndSnapsToHalfPercent() {
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [6.0, 7.3], usesIFCC: false), 5.5 ... 7.5)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [7.3, 6.0], usesIFCC: false), 5.5 ... 7.5)
        // 5.5% = 36.6 and 7.5% = 58.5 mmol/mol, widened to even numbers.
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [6.0, 7.3], usesIFCC: true), 36 ... 60)
    }

    /// The domain never starts below 4%, is at least one point wide, and the upper bound is capped
    /// at 14% unless that would make it narrower than one point.
    func testGMIDomainClampsLowerBoundWidthAndUpperCap() {
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [3.0], usesIFCC: false), 4 ... 5)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [6.0, 6.0], usesIFCC: false), 5.5 ... 6.5)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [10.0, 13.9], usesIFCC: false), 9.5 ... 14)
    }

    // MARK: - AGP display points

    /// No percentiles means nothing is drawn; there is no invented flat line.
    func testAGPDisplayPointsAreEmptyWithoutData() {
        XCTAssertTrue(GlucoseReportAGPDisplayPoints.smoothedDisplayPoints(from: []).isEmpty)
    }

    /// With fewer than three points there is no smoothing, but the bands are still sorted by time
    /// and extended to 00:00 and 24:00 so the chart spans the whole day.
    func testAGPDisplayPointsSortAndExtendShortSeriesToTheWholeDay() {
        let points = [
            agpPoint(minute: 900, values: [80, 100, 120, 140, 160]),
            agpPoint(minute: 300, values: [60, 70, 90, 110, 130])
        ]

        let display = GlucoseReportAGPDisplayPoints.smoothedDisplayPoints(from: points)

        XCTAssertEqual(display.map(\.minuteOfDay), [0, 300, 900, 1440])
        XCTAssertEqual(values(display[0]), [60, 70, 90, 110, 130])
        XCTAssertEqual(values(display[2]), [80, 100, 120, 140, 160])
        // The 24:00 point repeats the 00:00 point so the curve closes at midnight.
        XCTAssertEqual(values(display[3]), values(display[0]))
    }

    /// Each point is averaged with its direct neighbours (two at the edges), and the 24:00 point
    /// copies the smoothed 00:00 point rather than the last value of the day.
    func testAGPDisplayPointsUseThreePointMovingAverageAndWrapAtMidnight() {
        let points = [
            agpPoint(minute: 0, values: [60, 80, 100, 120, 140]),
            agpPoint(minute: 60, values: [90, 110, 130, 150, 170]),
            agpPoint(minute: 120, values: [120, 140, 160, 180, 200])
        ]

        let display = GlucoseReportAGPDisplayPoints.smoothedDisplayPoints(from: points)

        XCTAssertEqual(display.map(\.minuteOfDay), [0, 60, 120, 1440])
        XCTAssertEqual(values(display[0]), [75, 95, 115, 135, 155])
        XCTAssertEqual(values(display[1]), [90, 110, 130, 150, 170])
        XCTAssertEqual(values(display[2]), [105, 125, 145, 165, 185])
        XCTAssertEqual(values(display[3]), [75, 95, 115, 135, 155])
    }

    /// Smoothed percentiles are re-sorted, so crossed input bands can never be drawn inverted.
    func testAGPDisplayPointsKeepPercentilesOrdered() {
        let crossed = (0 ..< 3).map { index in
            agpPoint(minute: index * 60, values: [150, 100, 120, 90, 200])
        }

        let display = GlucoseReportAGPDisplayPoints.smoothedDisplayPoints(from: crossed)

        for point in display {
            XCTAssertEqual(values(point), [90, 100, 120, 150, 200])
        }
    }

    // MARK: - Loopalyzer buckets

    /// A quarter-hour bucket starting at 00:00 has its midpoint at 7.5 and a bar inset by 1.5 min.
    func testLoopalyzerBucketGeometryForAnOrdinaryBucket() {
        let point = loopalyzerPoint(minute: 0)

        XCTAssertEqual(point.bucketStartMinute, 0)
        XCTAssertEqual(point.bucketMidpointMinute, 7.5)
        XCTAssertEqual(point.bucketEndMinute, 15)
        XCTAssertEqual(point.bucketBarStartMinute, 1.5)
        XCTAssertEqual(point.bucketBarEndMinute, 13.5)
    }

    /// The last bucket of the day ends exactly at 1440, and a bucket at 1440 collapses to zero
    /// width instead of drawing past midnight or producing a bar that ends before it starts.
    func testLoopalyzerBucketGeometryIsClampedToTheDay() {
        let last = loopalyzerPoint(minute: 1425)
        XCTAssertEqual(last.bucketMidpointMinute, 1432.5)
        XCTAssertEqual(last.bucketEndMinute, 1440)
        XCTAssertEqual(last.bucketBarEndMinute, 1438.5)

        let pastEnd = loopalyzerPoint(minute: 1440)
        XCTAssertEqual(pastEnd.bucketMidpointMinute, 1440)
        XCTAssertEqual(pastEnd.bucketEndMinute, 1440)
        XCTAssertEqual(pastEnd.bucketBarStartMinute, 1440)
        XCTAssertEqual(pastEnd.bucketBarEndMinute, 1440)
    }

    // MARK: - range buckets

    /// Time-in-range buckets merge very low into low and very high into high, label the consensus
    /// limits in the user's unit and divide exactly 100% and 1,440 minutes.
    func testTimeInRangeBucketsMergeExtremesAndLabelLimitsInBothUnits() {
        let distribution = GlucoseReportRangeDistribution(veryLow: 1, low: 3, target: 70, high: 20, veryHigh: 6)

        let mgDl = distribution.timeInRangeBuckets(usesMgDl: true)
        let mmol = distribution.timeInRangeBuckets(usesMgDl: false)

        XCTAssertEqual(mgDl.map(\.detail), ["<70", "70-180", ">180"])
        XCTAssertEqual(mmol.map(\.detail), ["<3.9", "3.9-10.0", ">10.0"])
        XCTAssertEqual(mgDl.map(\.wholePercentage), [4, 70, 26])
        // 4% of a day is 57.6 minutes and 26% is 374.4; the spare minute goes to the larger remainder.
        XCTAssertEqual(mgDl.map(\.minutesPerDay), [58, 1008, 374])
        XCTAssertEqual(mgDl.map { $0.title(language: .english) }, ["Low", "In Range", "High"])
    }

    /// Tight-range buckets use the 70-140 mg/dL (3.9-7.8 mmol/L) definition and ignore the very
    /// low and very high fields, which the tight factory leaves at zero.
    func testTightRangeBucketsUseTheTightLimits() {
        let distribution = GlucoseReportRangeDistribution.tightRange(below: 10, target: 50, above: 40)

        let mmol = distribution.tightRangeBuckets(usesMgDl: false)

        XCTAssertEqual(mmol.map(\.detail), ["<3.9", "3.9-7.8", ">7.8"])
        XCTAssertEqual(mmol.map(\.wholePercentage), [10, 50, 40])
        XCTAssertEqual(mmol.map(\.minutesPerDay), [144, 720, 576])
        XCTAssertEqual(mmol.map { $0.title(language: .spanish) }, ["Bajo", "Rango Estrecho", "Alto"])
    }

    // MARK: - report period titles

    /// Period titles are formatted in the report language, not the device language.
    func testReportPeriodTitlesUseTheReportLanguage() {
        XCTAssertEqual(GlucoseReportPeriod.seven.title, "7d")
        XCTAssertEqual(GlucoseReportPeriod.ninety.fileTitle, "90 day CGM Report")
        XCTAssertEqual(GlucoseReportPeriod.thirty.clinicalTitle(language: .english), "30-day report")
        XCTAssertEqual(GlucoseReportPeriod.thirty.clinicalTitle(language: .german), "30-Tage-Bericht")
        XCTAssertEqual(GlucoseReportPeriod.oneYear.clinicalTitle(language: .french), "Rapport de 365 jours")
    }

    // MARK: - private functions

    private func agpPoint(minute: Int, values: [Double]) -> GlucoseReportAGPPoint {
        GlucoseReportAGPPoint(
            minuteOfDay: minute,
            p5MgDl: values[0],
            p25MgDl: values[1],
            medianMgDl: values[2],
            p75MgDl: values[3],
            p95MgDl: values[4]
        )
    }

    private func values(_ point: GlucoseReportAGPPoint) -> [Double] {
        [point.p5MgDl, point.p25MgDl, point.medianMgDl, point.p75MgDl, point.p95MgDl]
    }

    private func loopalyzerPoint(minute: Int) -> GlucoseReportLoopalyzerPoint {
        GlucoseReportLoopalyzerPoint(
            minuteOfDay: minute,
            glucoseMgDl: nil,
            scheduledBasalRate: nil,
            basalDeltaRate: nil,
            iob: nil,
            cob: nil
        )
    }
}
