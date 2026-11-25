//
//  UserDefaultsSandboxTests.swift
//  xdripTests
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import XCTest

/// Guards the defaults sandbox that tests use instead of saving and restoring keys by hand: if it
/// leaked a value, every later test in the process would run with another test's settings.
final class UserDefaultsSandboxTests: XCTestCase {

    private let prefix = "UserDefaultsSandboxTests."
    private var defaults: UserDefaults { .standard }

    override func setUp() {
        super.setUp()
        // Applies a journal a crashed earlier run may have left, instead of discarding it.
        UserDefaultsSandbox().restore()
        for key in ["added", "changed", "removed", "untouched"] {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    override func tearDown() {
        for key in ["added", "changed", "removed", "untouched"] {
            defaults.removeObject(forKey: prefix + key)
        }
        super.tearDown()
    }

    func testRestoreUndoesAddedChangedAndRemovedKeys() {
        defaults.set("old", forKey: prefix + "changed")
        defaults.set(42, forKey: prefix + "removed")
        defaults.set(true, forKey: prefix + "untouched")

        let sandbox = UserDefaultsSandbox()
        defaults.set("new", forKey: prefix + "added")
        defaults.set("other", forKey: prefix + "changed")
        defaults.removeObject(forKey: prefix + "removed")
        sandbox.restore()

        XCTAssertNil(defaults.object(forKey: prefix + "added"))
        XCTAssertEqual(defaults.string(forKey: prefix + "changed"), "old")
        XCTAssertEqual(defaults.integer(forKey: prefix + "removed"), 42)
        XCTAssertTrue(defaults.bool(forKey: prefix + "untouched"))
    }

    func testRestoreTwiceIsHarmless() {
        let sandbox = UserDefaultsSandbox()
        defaults.set("value", forKey: prefix + "added")
        sandbox.restore()
        defaults.set("after", forKey: prefix + "added")
        sandbox.restore()

        XCTAssertEqual(defaults.string(forKey: prefix + "added"), "after", "a second restore must not undo later changes")
    }

    func testJournalExistsOnlyWhileTheSandboxIsActive() {
        let sandbox = UserDefaultsSandbox()
        XCTAssertTrue(FileManager.default.fileExists(atPath: UserDefaultsSandbox.journalURL.path))
        sandbox.restore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: UserDefaultsSandbox.journalURL.path))
    }

    /// A test that crashes never restores its sandbox; the next sandbox must undo its changes.
    func testNextSandboxRecoversWhatACrashedTestLeftBehind() throws {
        defaults.set("before crash", forKey: prefix + "changed")
        let domain = UserDefaultsSandbox.standardDomainName
        let snapshot = try XCTUnwrap(defaults.persistentDomain(forName: domain))
        let journal = try PropertyListSerialization.data(fromPropertyList: [domain: snapshot], format: .binary, options: 0)
        try journal.write(to: UserDefaultsSandbox.journalURL)
        // What the crashed test changed and never put back.
        defaults.set("left by crash", forKey: prefix + "changed")
        defaults.set("left by crash", forKey: prefix + "added")

        let sandbox = UserDefaultsSandbox()
        XCTAssertEqual(defaults.string(forKey: prefix + "changed"), "before crash")
        XCTAssertNil(defaults.object(forKey: prefix + "added"))
        sandbox.restore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: UserDefaultsSandbox.journalURL.path))
    }

    func testNestedSandboxesRestoreInOrder() {
        defaults.set("outer", forKey: prefix + "changed")
        let outer = UserDefaultsSandbox()
        defaults.set("inner", forKey: prefix + "changed")
        let inner = UserDefaultsSandbox()
        defaults.set("test", forKey: prefix + "changed")

        inner.restore()
        XCTAssertEqual(defaults.string(forKey: prefix + "changed"), "inner")
        XCTAssertTrue(FileManager.default.fileExists(atPath: UserDefaultsSandbox.journalURL.path), "the outer sandbox still owns the journal")
        outer.restore()
        XCTAssertEqual(defaults.string(forKey: prefix + "changed"), "outer")
    }

    func testSuitesAreProtectedToo() throws {
        let suiteName = "xdripTests.UserDefaultsSandboxTests.suite"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        suite.set(1, forKey: "kept")

        let sandbox = UserDefaultsSandbox(domains: [UserDefaultsSandbox.standardDomainName, suiteName])
        suite.set(2, forKey: "kept")
        suite.set(3, forKey: "added")
        sandbox.restore()

        XCTAssertEqual(suite.integer(forKey: "kept"), 1)
        XCTAssertNil(suite.object(forKey: "added"))
        suite.removePersistentDomain(forName: suiteName)
    }

    /// The helper registers the restore as a teardown block, which also runs when assertions fail.
    func testIsolateUserDefaultsRestoresInTeardown() {
        isolateUserDefaults()
        defaults.set("from test", forKey: prefix + "untouched")
        addTeardownBlock { [prefix] in
            // Teardown blocks run last-in first-out, so this runs before the sandbox restores.
            XCTAssertEqual(UserDefaults.standard.string(forKey: prefix + "untouched"), "from test")
        }
    }
}
