//
//  OSLog.swift
//  xdrip Linux shim modules
//
//  Created by Eduardo Pietre on 25/11/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

// Minimal stand-in for Apple's OSLog on Linux, so files that only create a logger (for example
// PreLibre2) keep their `import OSLog` and compile. Nothing is logged: tests must not depend on
// log output.

/// Stand-in for `OSLog`: remembers its subsystem and category, logs nothing.
public final class OSLog {
    public let subsystem: String
    public let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public static let `default` = OSLog(subsystem: "", category: "")
}

/// Stand-in for `OSLogType`.
public struct OSLogType: Equatable {
    private let rawValue: UInt8
    public static let `default` = OSLogType(rawValue: 0)
    public static let info = OSLogType(rawValue: 1)
    public static let debug = OSLogType(rawValue: 2)
    public static let error = OSLogType(rawValue: 16)
    public static let fault = OSLogType(rawValue: 17)
}

/// Stand-in for `os_log`: discards the message.
public func os_log(_ message: StaticString, log: OSLog = .default, type: OSLogType = .default, _ arguments: CVarArg...) {}
