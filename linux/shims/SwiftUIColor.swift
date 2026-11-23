//
//  SwiftUIColor.swift
//  xdrip Linux shims
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

/// Minimal stand-in for SwiftUI's `Color`, which does not exist on Linux.
///
/// Only stores its components so that models holding a colour (report buckets, constants) compile
/// and can be compared in tests. Nothing is ever rendered on Linux, so no colour space logic is needed.
struct Color: Equatable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    func opacity(_ opacity: Double) -> Color {
        Color(red: red, green: green, blue: blue, opacity: self.opacity * opacity)
    }

    // MARK: - system colours (approximate sRGB values, only identity matters on Linux)

    static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    static let black = Color(white: 0)
    static let white = Color(white: 1)
    static let gray = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let red = Color(red: 1, green: 0.23, blue: 0.19)
    static let orange = Color(red: 1, green: 0.58, blue: 0)
    static let yellow = Color(red: 1, green: 0.8, blue: 0)
    static let green = Color(red: 0.2, green: 0.78, blue: 0.35)
    static let mint = Color(red: 0, green: 0.78, blue: 0.75)
    static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    static let cyan = Color(red: 0.2, green: 0.68, blue: 0.9)
    static let blue = Color(red: 0, green: 0.48, blue: 1)
    static let indigo = Color(red: 0.35, green: 0.34, blue: 0.84)
    static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    static let pink = Color(red: 1, green: 0.18, blue: 0.33)
    static let brown = Color(red: 0.64, green: 0.52, blue: 0.37)
    static let primary = Color(white: 0)
    static let secondary = Color(white: 0.24, opacity: 0.6)
}
