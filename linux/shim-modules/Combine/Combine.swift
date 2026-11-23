//
//  Combine.swift
//  xdrip Linux shim modules
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

// Minimal stand-in for Combine on Linux: `ObservableObject` and `@Published` as plain storage, so
// state classes compile and their logic can be tested. Nothing is published to subscribers, so code
// that observes changes (sink, assign, onReceive) cannot be tested with this shim.

/// Stand-in for Combine's `ObservableObject`.
public protocol ObservableObject: AnyObject {}

/// Stand-in for Combine's `@Published`: stores the value without publishing changes.
@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Published<Value> {
        get { self }
        set { self = newValue }
    }
}
