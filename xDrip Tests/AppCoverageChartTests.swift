//
//  AppCoverageChartTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI
import XCTest
@testable import xdrip

final class AppCoverageChartTests: XCTestCase {

    // MARK: - GlucoseChartType

    func testEveryChartTypeHasAUsableDefaultSurface() {
        for type in GlucoseChartType.allCases {
            for liveActivityType in LiveActivityType.allCases {
                let size = type.viewSize(liveActivityType: liveActivityType)
                XCTAssertGreaterThan(size.width, 0, type.description)
                XCTAssertGreaterThan(size.height, 0, type.description)
                XCTAssertGreaterThan(type.hoursToShow(liveActivityType: liveActivityType), 0)
                XCTAssertGreaterThan(type.glucoseCircleDiameter(liveActivityType: liveActivityType), 0)
                XCTAssertEqual(type.intervalBetweenAxisValues(liveActivityType: liveActivityType), ConstantsGlucoseChartSwiftUI.xAxisIntervalBetweenValues)
            }
            XCTAssertFalse(type.description.isEmpty)
            XCTAssertGreaterThanOrEqual(type.cornerRadius(), 0)
            XCTAssertGreaterThan(type.yAxisLineSize(), 0)
        }
    }

    // MARK: - Chart constants

    func testMinimumChartValueLeavesBasalSpaceBelowOneDay() {
        XCTAssertEqual(ConstantsGlucoseChartSwiftUI.minimumChartValueWithBottomSpace(hours: 6), ConstantsGlucoseChartSwiftUI.minimumChartValueWithBasal)
        XCTAssertEqual(ConstantsGlucoseChartSwiftUI.minimumChartValueWithBottomSpace(hours: 24), ConstantsGlucoseChartSwiftUI.minimumChartValueWithBasal24Hours)
    }

    func testXAxisDatesAreAnchoredToClockHours() throws {
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9, minute: 20)))
        let end = start.addingTimeInterval(6 * 3600)
        let hourly = ConstantsGlucoseChartSwiftUI.xAxisDates(from: start, to: end, everyHours: 1)
        XCTAssertEqual(hourly.map { calendar.component(.hour, from: $0) }, [10, 11, 12, 13, 14, 15])
        XCTAssertTrue(hourly.allSatisfy { calendar.component(.minute, from: $0) == 0 })
        let even = ConstantsGlucoseChartSwiftUI.xAxisDates(from: start, to: end, everyHours: 2)
        XCTAssertEqual(even.map { calendar.component(.hour, from: $0) }, [10, 12, 14])
        XCTAssertEqual(ConstantsGlucoseChartSwiftUI.xAxisDates(from: start, to: end, everyHours: 0).count, 6)
        XCTAssertTrue(ConstantsGlucoseChartSwiftUI.xAxisDates(from: end, to: start, everyHours: 1).isEmpty)
    }

    func testMiniChartEdgeInsetSolvesForCornerClearance() {
        let inset = ConstantsHomeView.standardCornerRadius
        let width: CGFloat = 300
        let padding = ConstantsGlucoseChartSwiftUI.miniChartEdgeInsetTimeInterval(visibleTimeInterval: 3600, chartWidth: width)
        XCTAssertEqual(3600 / (3600 + padding), Double((width - inset) / width), accuracy: 1e-9)
        XCTAssertEqual(ConstantsGlucoseChartSwiftUI.miniChartEdgeInsetTimeInterval(visibleTimeInterval: 0, chartWidth: width), 0)
        XCTAssertEqual(ConstantsGlucoseChartSwiftUI.miniChartEdgeInsetTimeInterval(visibleTimeInterval: 3600, chartWidth: inset), 0)
    }

    // MARK: - Scroll coordinator

    func testScrollCoordinatorNormalisesDurationAndDerivesStart() {
        let end = Date(timeIntervalSince1970: 1_000_000)
        let coordinator = GlucoseChartScrollCoordinator(endDate: end, visibleTimeInterval: -3600)
        XCTAssertEqual(coordinator.visibleTimeInterval, 3600)
        XCTAssertEqual(coordinator.startDate, end.addingTimeInterval(-3600))
        XCTAssertFalse(coordinator.isShowingCurrentTimeRange)
        coordinator.setVisibleTimeInterval(-7200)
        XCTAssertEqual(coordinator.visibleTimeInterval, 7200)
        XCTAssertEqual(coordinator.endDate, end)
        XCTAssertEqual(coordinator.startDate, end.addingTimeInterval(-7200))
    }

    func testRefreshOnlyFollowsNowWhenShowingCurrentRange() {
        let past = Date().addingTimeInterval(-120)
        let scrolledBack = GlucoseChartScrollCoordinator(endDate: past, visibleTimeInterval: 3600)
        XCTAssertFalse(scrolledBack.refreshCurrentTimeRangeIfNeeded())
        XCTAssertEqual(scrolledBack.endDate, past)
        let current = GlucoseChartScrollCoordinator(endDate: Date().addingTimeInterval(-30), visibleTimeInterval: 3600)
        XCTAssertTrue(current.isShowingCurrentTimeRange)
        XCTAssertTrue(current.refreshCurrentTimeRangeIfNeeded())
        XCTAssertEqual(current.endDate.timeIntervalSinceNow, 0, accuracy: 1)
    }

    func testResetToNowReturnsAScrolledChart() {
        let coordinator = GlucoseChartScrollCoordinator(endDate: Date().addingTimeInterval(-86_400), visibleTimeInterval: 3600)
        coordinator.stopDeceleration()
        coordinator.resetToNow()
        XCTAssertTrue(coordinator.isShowingCurrentTimeRange)
        XCTAssertEqual(coordinator.endDate.timeIntervalSinceNow, 0, accuracy: 1)
    }
}

@MainActor
final class AppCoverageChartStateTests: XCTestCase {
    private var core: CoreDataManager!
    private var chart: GlucoseChartStateManager!

    override func setUp() async throws {
        try await super.setUp()
        appCoverageIsolateDefaults()
        let defaults = UserDefaults.standard
        // A master without a pump data source, whatever the simulator's stored settings are: the
        // chart reserves basal space below zero when the data flow policy shows pump data.
        defaults.isMaster = true
        defaults.nightscoutEnabled = false
        // No real site: the sync manager checks the credentials when a test enables Nightscout.
        defaults.nightscoutUrl = nil
        defaults.nightscoutAPIKey = nil
        defaults.nightscoutToken = nil
        defaults.showOriginalBGReadings = false
        defaults.enableSmoothing = false
        defaults.enableAdjustment = false
        core = AppCoverageFactory.coreData()
        chart = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: NightscoutSyncManager(coreDataManager: core, messageHandler: nil))
        // Teardown blocks run last-in, first-out: the chart and its sync manager are released before
        // the defaults are restored, so they cannot react to the restore.
        addTeardownBlock { [unowned self] in self.chart = nil }
    }

    private func state(start: Date, end: Date = Date(), treatments: Bool = true, originalOnly: Bool = false, refresh: Bool = false, reset: Bool = true) async -> GlucoseChartState {
        await withCheckedContinuation { continuation in
            chart.updateState(endDate: end, startDate: start, forceReset: reset, refreshCachedData: refresh, showTreatments: treatments, showOriginalReadingsOnly: originalOnly) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func treatment(_ type: TreatmentType, value: Double, at date: Date, secondary: Double = 0, notes: String? = nil) {
        _ = TreatmentEntry(date: date, value: value, valueSecondary: secondary, treatmentType: type, nightscoutEventType: nil, enteredBy: "Test", notes: notes, nsManagedObjectContext: core.mainManagedObjectContext)
    }

    func testReadingsAndCalibrationsArePublishedWithoutZeroValues() async {
        let now = Date()
        AppCoverageFactory.reading(110, at: now.addingTimeInterval(-600), in: core)
        AppCoverageFactory.reading(0, at: now.addingTimeInterval(-300), in: core)
        AppCoverageFactory.reading(130, at: now.addingTimeInterval(-60), in: core)
        let sensor = Sensor(startDate: now.addingTimeInterval(-86_400), nsManagedObjectContext: core.mainManagedObjectContext)
        _ = AppCoverageFactory.calibration(at: now.addingTimeInterval(-120), sensor: sensor, core: core)
        XCTAssertTrue(core.saveChanges())
        let result = await state(start: now.addingTimeInterval(-3600))
        XCTAssertEqual(result.bgReadingValues.sorted(), [110, 130])
        XCTAssertEqual(result.bgReadingDates.count, 2)
        XCTAssertEqual(result.calibrationPoints.map(\.value), [100])
        XCTAssertTrue(result.additionalBgReadingDataSets.isEmpty)
        XCTAssertEqual(result.minimumChartValueInMgDl, ConstantsGlucoseChart.absoluteMinimumChartValueInMgdl)
        XCTAssertNil(result.backgroundBands)
        XCTAssertEqual(chart.state.endDate, result.endDate)
    }

    func testOriginalReadingsPeekReplacesProcessedSeries() async throws {
        let now = Date()
        AppCoverageFactory.reading(120, at: now.addingTimeInterval(-60), in: core)
        XCTAssertTrue(core.saveChanges())
        let peek = await state(start: now.addingTimeInterval(-3600), originalOnly: true)
        XCTAssertTrue(peek.bgReadingValues.isEmpty)
        let original = try XCTUnwrap(peek.additionalBgReadingDataSets.first)
        XCTAssertEqual(original.seriesIdentifier, "original")
        XCTAssertEqual(original.bgReadingValues, [120])
    }

    func testOriginalSeriesIsShownOnlyWhenProcessingIsEnabled() async {
        let now = Date()
        AppCoverageFactory.reading(120, at: now.addingTimeInterval(-60), in: core)
        XCTAssertTrue(core.saveChanges())
        UserDefaults.standard.showOriginalBGReadings = true
        let unprocessed = await state(start: now.addingTimeInterval(-3600))
        XCTAssertTrue(unprocessed.additionalBgReadingDataSets.isEmpty)
        UserDefaults.standard.enableSmoothing = true
        let processed = await state(start: now.addingTimeInterval(-3600))
        XCTAssertEqual(processed.additionalBgReadingDataSets.count, 1)
        XCTAssertEqual(processed.bgReadingValues, [120])
    }

    func testTreatmentsArePlacedAroundInterpolatedGlucose() async throws {
        let now = Date()
        let start = now.addingTimeInterval(-1800)
        AppCoverageFactory.reading(100, at: start, in: core)
        AppCoverageFactory.reading(200, at: start.addingTimeInterval(600), in: core)
        treatment(.Insulin, value: 3, at: start.addingTimeInterval(300))
        treatment(.Carbs, value: 45, at: start.addingTimeInterval(300))
        treatment(.BgCheck, value: 140, at: start.addingTimeInterval(300))
        treatment(.Note, value: 0, at: start.addingTimeInterval(300), notes: "  walk   in park ")
        XCTAssertTrue(core.saveChanges())
        let result = await state(start: start.addingTimeInterval(-600))
        let offset = (ConstantsGlucoseChart.defaultOffsetTreatmentPositionFromBgMarker + 5) * ConstantsGlucoseChart.doseTreatmentOffsetMultiplier
        let bolus = try XCTUnwrap(result.treatmentPoints.boluses.first)
        let carbs = try XCTUnwrap(result.treatmentPoints.carbs.first)
        XCTAssertEqual(bolus.yValue, 150 - offset, accuracy: 0.01)
        XCTAssertEqual(carbs.yValue, 150 + offset, accuracy: 0.01)
        XCTAssertEqual(bolus.label, "3")
        XCTAssertEqual(carbs.label, "45")
        XCTAssertEqual(result.treatmentPoints.bgChecks.first?.yValue, 140)
        XCTAssertNil(result.treatmentPoints.bgChecks.first?.label)
        XCTAssertEqual(result.treatmentPoints.notes.first?.label, GlucoseChartTreatmentStyle.noteLabel("walk in park"))
        XCTAssertTrue(result.treatmentPoints.basalRates.isEmpty, "Basal needs pump data")
    }

    func testTreatmentsOutsideReadingsClampToNearestOrDefaultValue() async throws {
        let now = Date()
        treatment(.Carbs, value: 20, at: now.addingTimeInterval(-900))
        XCTAssertTrue(core.saveChanges())
        let empty = await state(start: now.addingTimeInterval(-3600))
        let offset = ConstantsGlucoseChart.defaultOffsetTreatmentPositionFromBgMarker * ConstantsGlucoseChart.doseTreatmentOffsetMultiplier
        XCTAssertEqual(try XCTUnwrap(empty.treatmentPoints.carbs.first).yValue, 120 + offset, accuracy: 0.01)
        AppCoverageFactory.reading(300, at: now.addingTimeInterval(-1800), in: core)
        XCTAssertTrue(core.saveChanges())
        let afterLast = await state(start: now.addingTimeInterval(-3600))
        let highOffset = (ConstantsGlucoseChart.defaultOffsetTreatmentPositionFromBgMarker + 15) * ConstantsGlucoseChart.doseTreatmentOffsetMultiplier
        XCTAssertEqual(try XCTUnwrap(afterLast.treatmentPoints.carbs.first).yValue, 300 + highOffset, accuracy: 0.01)
    }

    func testHiddenTreatmentsProduceNoPoints() async {
        let now = Date()
        treatment(.Insulin, value: 2, at: now.addingTimeInterval(-300))
        XCTAssertTrue(core.saveChanges())
        let result = await state(start: now.addingTimeInterval(-3600), treatments: false)
        XCTAssertTrue(result.treatmentPoints.boluses.isEmpty)
        XCTAssertEqual(result.minimumChartValueInMgDl, ConstantsGlucoseChart.absoluteMinimumChartValueInMgdl)
    }

    func testPumpDataReservesBasalSpaceAndDrawsTempBasal() async throws {
        let defaults = UserDefaults.standard
        defaults.nightscoutEnabled = true
        defaults.therapyDataSourceType = .nightscout
        defaults.nightscoutFollowType = .loop
        let now = Date()
        treatment(.Basal, value: 1.5, at: now.addingTimeInterval(-1800), secondary: 30)
        XCTAssertTrue(core.saveChanges())
        let result = await state(start: now.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(result.minimumChartValueInMgDl, ConstantsGlucoseChartSwiftUI.minimumChartValueWithBottomSpace(hours: 3))
        let basal = result.treatmentPoints.basalRates
        XCTAssertGreaterThanOrEqual(basal.count, 3)
        XCTAssertEqual(basal.count, result.treatmentPoints.basalRateFill.count)
        XCTAssertNotEqual(basal[0].value, basal[1].value, "The rate steps up from zero at the treatment start")
        XCTAssertTrue(result.treatmentPoints.scheduledBasalRates.isEmpty, "No Nightscout profile is loaded")
        let day = await state(start: now.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(day.minimumChartValueInMgDl, ConstantsGlucoseChartSwiftUI.minimumChartValueWithBasal24Hours)
    }

    func testScrollingMergesAndRefreshLoadsNewTailReadings() async {
        let now = Date()
        AppCoverageFactory.reading(100, at: now.addingTimeInterval(-10 * 3600), in: core)
        AppCoverageFactory.reading(120, at: now.addingTimeInterval(-600), in: core)
        XCTAssertTrue(core.saveChanges())
        let recent = await state(start: now.addingTimeInterval(-3600), end: now)
        XCTAssertTrue(recent.bgReadingValues.contains(120))
        let wider = await state(start: now.addingTimeInterval(-12 * 3600), end: now, reset: false)
        XCTAssertEqual(Set(wider.bgReadingValues), [100, 120])
        AppCoverageFactory.reading(140, at: now.addingTimeInterval(-300), in: core)
        XCTAssertTrue(core.saveChanges())
        let stale = await state(start: now.addingTimeInterval(-12 * 3600), end: now, reset: false)
        XCTAssertFalse(stale.bgReadingValues.contains(140), "Already cached ranges are not reloaded")
        let refreshed = await state(start: now.addingTimeInterval(-12 * 3600), end: now, refresh: true, reset: false)
        XCTAssertTrue(refreshed.bgReadingValues.contains(140))
        XCTAssertTrue(refreshed.bgReadingValues.contains(100), "Older cached data survives the tail refresh")
    }

    func testDisjointJumpReplacesCache() async {
        let now = Date()
        AppCoverageFactory.reading(90, at: now.addingTimeInterval(-5 * 86_400), in: core)
        AppCoverageFactory.reading(120, at: now.addingTimeInterval(-600), in: core)
        XCTAssertTrue(core.saveChanges())
        _ = await state(start: now.addingTimeInterval(-3600), end: now)
        let old = await state(start: now.addingTimeInterval(-5 * 86_400 - 1800), end: now.addingTimeInterval(-5 * 86_400 + 1800), reset: false)
        XCTAssertEqual(old.bgReadingValues, [90])
        XCTAssertLessThan(old.dataEndDate, now.addingTimeInterval(-86_400))
    }
}
