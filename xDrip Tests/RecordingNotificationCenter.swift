//
//  RecordingNotificationCenter.swift
//  xdripTests
//
//  Created by eduardopietre on 26/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import UserNotifications
@testable import xdrip

/// Keeps the notification requests and categories of one test in memory, instead of the simulator's notification
/// center. The real center is shared by every test of the run and needs a permission the simulator
/// may not have granted, so tests that use it can fail or see requests left by another test.
final class RecordingNotificationCenter: AlertNotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = [String: UNNotificationRequest]()
    private var categories = Set<UNNotificationCategory>()

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.withLock { requests[request.identifier] = request }
        completionHandler?(nil)
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { requests[request.identifier] = request }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        lock.withLock { Array(requests.values) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

    func getNotificationCategories(completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void) {
        completionHandler(lock.withLock { categories })
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        lock.withLock { self.categories = categories }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        lock.withLock { for identifier in identifiers { requests.removeValue(forKey: identifier) } }
    }
}
