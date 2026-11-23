//
//  ActivityKit.swift
//  xdrip Linux shim modules
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

// Minimal stand-in for ActivityKit on Linux: only the protocol that Live Activity payload models
// conform to, so their encoding, decoding and comparison logic can be tested. No activity is ever
// started on Linux.

/// Stand-in for ActivityKit's `ActivityAttributes`.
public protocol ActivityAttributes {
    associatedtype ContentState: Codable & Hashable
}
