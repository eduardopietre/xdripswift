//
//  SwiftUI.swift
//  xdrip Linux shim modules
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
// SwiftUI on iOS makes UIKit visible too, so files importing only SwiftUI can use UIColor.
@_exported import UIKit

// Minimal stand-in for SwiftUI on Linux: only the value types that app models and constants
// hold (`Color`), never views. Files that use views cannot be compiled on Linux at all.

/// Minimal stand-in for SwiftUI's `Color`, which does not exist on Linux.
///
/// It only stores its components so that models holding a colour (report buckets, constants)
/// compile and can be compared in tests. Nothing is ever rendered on Linux, so no colour space logic
/// is needed.
public struct Color: Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double
    /// Name of an asset catalog colour; its real value is only known on Apple platforms.
    public let assetName: String?

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
        assetName = nil
    }

    /// An asset catalog colour, e.g. `Color("colorSecondary")`. Equal to any other use of the same name.
    public init(_ assetName: String) {
        red = 0
        green = 0
        blue = 0
        opacity = 1
        self.assetName = assetName
    }

    private init(red: Double, green: Double, blue: Double, opacity: Double, assetName: String?) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
        self.assetName = assetName
    }

    public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    public init(_ uiColor: UIColor) {
        self.init(red: uiColor.red, green: uiColor.green, blue: uiColor.blue, opacity: uiColor.alpha)
    }

    public func opacity(_ opacity: Double) -> Color {
        Color(red: red, green: green, blue: blue, opacity: self.opacity * opacity, assetName: assetName)
    }

    // MARK: - system colours (approximate sRGB values, only identity matters on Linux)

    public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    public static let black = Color(white: 0)
    public static let white = Color(white: 1)
    public static let gray = Color(red: 0.56, green: 0.56, blue: 0.58)
    public static let red = Color(red: 1, green: 0.23, blue: 0.19)
    public static let orange = Color(red: 1, green: 0.58, blue: 0)
    public static let yellow = Color(red: 1, green: 0.8, blue: 0)
    public static let green = Color(red: 0.2, green: 0.78, blue: 0.35)
    public static let mint = Color(red: 0, green: 0.78, blue: 0.75)
    public static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    public static let cyan = Color(red: 0.2, green: 0.68, blue: 0.9)
    public static let blue = Color(red: 0, green: 0.48, blue: 1)
    public static let indigo = Color(red: 0.35, green: 0.34, blue: 0.84)
    public static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    public static let pink = Color(red: 1, green: 0.18, blue: 0.33)
    public static let brown = Color(red: 0.64, green: 0.52, blue: 0.37)
    public static let primary = Color(white: 0)
    public static let secondary = Color(white: 0.24, opacity: 0.6)
}


/// Minimal stand-in for SwiftUI's `Font`: only the weights, which some models choose for symbols.
public struct Font: Equatable, Hashable {
    public struct Weight: Equatable, Hashable {
        private let value: Int

        public static let ultraLight = Weight(value: 1)
        public static let thin = Weight(value: 2)
        public static let light = Weight(value: 3)
        public static let regular = Weight(value: 4)
        public static let medium = Weight(value: 5)
        public static let semibold = Weight(value: 6)
        public static let bold = Weight(value: 7)
        public static let heavy = Weight(value: 8)
        public static let black = Weight(value: 9)
    }
}
