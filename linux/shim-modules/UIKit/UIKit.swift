//
//  UIKit.swift
//  xdrip Linux shim modules
//
//  Created by eduardopietre on 23/11/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

// Minimal stand-in for UIKit on Linux: only `UIColor`, for models and constants that hold colours.

/// Minimal stand-in for UIKit's `UIColor`. Stores components only; nothing is rendered on Linux.
public struct UIColor: Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public func withAlphaComponent(_ alpha: Double) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    // MARK: - system colours (approximate sRGB values, only identity matters on Linux)

    public static let clear = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = UIColor(white: 0, alpha: 1)
    public static let white = UIColor(white: 1, alpha: 1)
    public static let gray = UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1)
    public static let red = UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    public static let orange = UIColor(red: 1, green: 0.58, blue: 0, alpha: 1)
    public static let yellow = UIColor(red: 1, green: 0.8, blue: 0, alpha: 1)
    public static let green = UIColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
    public static let blue = UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)
    public static let systemGray = gray
    public static let systemRed = red
    public static let systemOrange = orange
    public static let systemYellow = yellow
    public static let systemGreen = green
    public static let systemMint = UIColor(red: 0, green: 0.78, blue: 0.75, alpha: 1)
    public static let systemTeal = UIColor(red: 0.19, green: 0.69, blue: 0.78, alpha: 1)
    public static let systemCyan = UIColor(red: 0.2, green: 0.68, blue: 0.9, alpha: 1)
    public static let systemBlue = blue
    public static let systemIndigo = UIColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1)
    public static let systemPurple = UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)
    public static let systemPink = UIColor(red: 1, green: 0.18, blue: 0.33, alpha: 1)
    public static let systemBrown = UIColor(red: 0.64, green: 0.52, blue: 0.37, alpha: 1)
    public static let label = black
    public static let secondaryLabel = UIColor(white: 0.24, alpha: 0.6)
    public static let separator = UIColor(white: 0.24, alpha: 0.29)
    public static let systemBackground = white
    public static let secondarySystemBackground = UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
}
