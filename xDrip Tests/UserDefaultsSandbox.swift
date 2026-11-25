//
//  UserDefaultsSandbox.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import XCTest

/// Gives a test a private copy of the app's `UserDefaults` without changing any app code.
///
/// The app reads `UserDefaults.standard` directly in more than a hundred files, so the defaults
/// cannot be injected. Instead the sandbox snapshots whole persistent domains when it is created
/// and puts them back, key by key, when it is restored: keys the test added are removed, changed or
/// removed keys get their old value back. Restoring key by key (instead of replacing the domain)
/// sends the same KVO notifications as a normal change, so observers see consistent values.
///
/// A test that crashes or is killed by a timeout never reaches its teardown, and the simulator
/// keeps its defaults between runs, so the next run would start from the crashed test's settings.
/// To prevent that, the outermost sandbox writes its snapshot to a journal file in the temporary
/// directory and deletes it after restoring. A journal left behind is applied by the next sandbox
/// before it takes its own snapshot.
///
/// Usage: call `isolateUserDefaults()` at the start of a test or in `setUp`; there is no need to
/// list the keys the test touches.
final class UserDefaultsSandbox {

    // MARK: - static properties

    /// Name of the persistent domain behind `UserDefaults.standard`: the bundle identifier of the
    /// test host on Apple platforms. swift-corelibs-foundation (Linux) has no bundle identifier for
    /// a test binary and files the standard defaults under this CFPreferences name instead.
    static var standardDomainName: String {
        Bundle.main.bundleIdentifier ?? "kCFPreferencesCurrentApplication"
    }

    /// Where the outermost sandbox keeps its snapshot until it is restored.
    ///
    /// The name depends on the test executable, so test processes that share a temporary
    /// directory (parallel Linux suites) never apply each other's journal, while the next run of
    /// the same tests finds it. `hashValue` is not used because it changes on every launch.
    static var journalURL: URL {
        let executable = Bundle.main.executablePath ?? ProcessInfo.processInfo.processName
        let hash = executable.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("xdripTests-UserDefaultsSandbox-\(String(hash, radix: 16)).plist")
    }

    private static let lock = NSLock()

    /// Number of sandboxes currently active in this process; only the outermost one owns the journal.
    private static var activeCount = 0

    // MARK: - private properties

    /// Persistent domain name -> its contents when the sandbox was created.
    private let snapshots: [String: [String: Any]]

    private let ownsJournal: Bool

    private var isRestored = false

    // MARK: - initialization

    /// - Parameter domains: persistent domains to protect. Defaults to the standard domain; pass
    ///   suite names too (e.g. the app group) when the code under test writes to them.
    init(domains: [String] = [UserDefaultsSandbox.standardDomainName]) {
        Self.lock.lock()
        let isOutermost = Self.activeCount == 0
        Self.activeCount += 1
        Self.lock.unlock()

        if isOutermost {
            Self.recoverFromJournal()
        }

        var snapshots = [String: [String: Any]]()
        for domain in domains {
            snapshots[domain] = Self.defaults(for: domain).persistentDomain(forName: domain) ?? [:]
        }
        self.snapshots = snapshots

        ownsJournal = isOutermost && Self.writeJournal(snapshots)
    }

    deinit {
        restore()
    }

    // MARK: - public functions

    /// Puts every protected domain back as it was when the sandbox was created. Safe to call twice.
    func restore() {
        guard !isRestored else { return }
        isRestored = true

        for (domain, snapshot) in snapshots {
            Self.apply(snapshot, to: domain)
        }
        if ownsJournal {
            try? FileManager.default.removeItem(at: Self.journalURL)
        }

        Self.lock.lock()
        Self.activeCount -= 1
        Self.lock.unlock()
    }

    // MARK: - private functions

    /// The `UserDefaults` object that writes to the given persistent domain.
    private static func defaults(for domain: String) -> UserDefaults {
        if domain == standardDomainName {
            return .standard
        }
        return UserDefaults(suiteName: domain) ?? .standard
    }

    /// Makes the domain equal to `snapshot`, touching only keys whose value differs.
    private static func apply(_ snapshot: [String: Any], to domain: String) {
        let defaults = defaults(for: domain)
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        for key in current.keys where snapshot[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in snapshot {
            if let currentValue = current[key], isEqual(currentValue, value) {
                continue
            }
            defaults.set(value, forKey: key)
        }
    }

    /// Property list values compared as Foundation objects, so `1` and `NSNumber(1)` are equal.
    /// Wrapped in dictionaries because swift-corelibs-foundation cannot bridge `Any` to `AnyObject`.
    private static func isEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
    }

    /// Stores the snapshots so a later process can undo a crashed test. Returns false when they
    /// cannot be written, in which case the sandbox still works but cannot recover from crashes.
    private static func writeJournal(_ snapshots: [String: [String: Any]]) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: snapshots, format: .binary, options: 0) else {
            return false
        }
        return (try? data.write(to: journalURL, options: .atomic)) != nil
    }

    /// Applies and deletes a journal left behind by a test that never restored its sandbox.
    private static func recoverFromJournal() {
        guard let data = try? Data(contentsOf: journalURL) else { return }
        if let snapshots = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: [String: Any]] {
            for (domain, snapshot) in snapshots {
                apply(snapshot, to: domain)
            }
        }
        try? FileManager.default.removeItem(at: journalURL)
    }
}

extension XCTestCase {

    /// Protects the app's defaults for the rest of the test: everything the test (or the code it
    /// calls) writes to them is undone in teardown, even when assertions fail.
    ///
    /// - Parameter suites: extra persistent domains to protect, e.g. the app group suite.
    @discardableResult
    func isolateUserDefaults(alsoSuites suites: [String] = []) -> UserDefaultsSandbox {
        let sandbox = UserDefaultsSandbox(domains: [UserDefaultsSandbox.standardDomainName] + suites)
        addTeardownBlock { sandbox.restore() }
        return sandbox
    }
}
