//
//  AppCoverageTestSupport.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 21/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import UserNotifications
import XCTest
@testable import xdrip

/// Restores every key of the standard defaults domain that a test changes, including keys it removes.
final class AppCoverageDefaultsSnapshot {
    private let saved: [String: Any]
    private let domainName: String

    init() {
        domainName = Bundle.main.bundleIdentifier ?? ""
        saved = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
    }

    func restore() {
        let standard = UserDefaults.standard
        let current = standard.persistentDomain(forName: domainName) ?? [:]
        for key in current.keys where saved[key] == nil {
            standard.removeObject(forKey: key)
        }
        for (key, value) in saved {
            if let currentValue = current[key], (currentValue as AnyObject).isEqual(value) { continue }
            standard.set(value, forKey: key)
        }
    }
}

extension XCTestCase {
    /// Snapshots the standard defaults and restores them when the test finishes.
    func appCoverageIsolateDefaults() {
        let snapshot = AppCoverageDefaultsSnapshot()
        addTeardownBlock { snapshot.restore() }
    }
}

enum AppCoverageFactory {
    static func coreData() -> CoreDataManager {
        CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    }

    @discardableResult
    static func reading(_ value: Double, at date: Date, in core: CoreDataManager, slope: Double = 0, hideSlope: Bool = false, sensor: Sensor? = nil) -> BgReading {
        let reading = BgReading(timeStamp: date, sensor: sensor, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        reading.calculatedValue = value
        reading.calculatedValueSlope = slope
        reading.hideSlope = hideSlope
        return reading
    }

    static func alertType(_ core: CoreDataManager, enabled: Bool = true, overrideMute: Bool = false, snooze: Bool = true, snoozePeriod: Int = 30, vibrate: Bool = false, sound: String? = "") -> AlertType {
        AlertType(enabled: enabled, name: "Test-\(UUID().uuidString)", overrideMute: overrideMute, snooze: snooze, snoozePeriod: snoozePeriod, vibrate: vibrate, soundName: sound, alertEntries: nil, nsManagedObjectContext: core.mainManagedObjectContext)
    }

    static func alertEntry(_ kind: AlertKind, value: Int, trigger: Int = 0, start: Int = 0, type: AlertType, core: CoreDataManager, disabled: Bool = false) -> AlertEntry {
        AlertEntry(isDisabled: disabled, value: value, triggerValue: trigger, alertKind: kind, start: start, alertType: type, nsManagedObjectContext: core.mainManagedObjectContext)
    }

    static func calibration(at date: Date, sensor: Sensor, core: CoreDataManager) -> Calibration {
        Calibration(timeStamp: date, sensor: sensor, bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: date, slope: 1, intercept: 0, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
    }
}

/// Captures alert notifications without requiring simulator notification permission.
final class AppCoverageNotificationCenter: AlertNotificationScheduling {
    private(set) var requests = [String: UNNotificationRequest]()
    private(set) var removedPending = [String]()
    private(set) var removedDelivered = [String]()
    var failure: Error?

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        if failure == nil { requests[request.identifier] = request }
        completionHandler?(failure)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered += identifiers
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending += identifiers
        for identifier in identifiers { requests.removeValue(forKey: identifier) }
    }

    private(set) var categories = Set<UNNotificationCategory>()

    func getNotificationCategories(completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void) {
        completionHandler(categories)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func request(for kind: AlertKind) -> UNNotificationRequest? {
        requests[kind.notificationIdentifier()]
    }
}
