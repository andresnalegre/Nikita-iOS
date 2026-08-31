import SwiftUI

public extension Color {

    // MARK: Main

    // Nikita-qflipper palette: dark purple base, magenta brand accent, neon
    // green secondary. These replace the stock Flipper orange/light theme.
    // Deep purple-black, like nikita-qflipper's window background (#0b0410).
    static var background: Color {
        .init(red: 0.043, green: 0.016, blue: 0.063)
    }

    // Card / grouped surface (#160a1c).
    static var groupedBackground: Color {
        .init(red: 0.086, green: 0.039, blue: 0.110)
    }

    // Raised surface (#1d101d).
    static var secondaryGroupedBackground: Color {
        .init(red: 0.114, green: 0.063, blue: 0.114)
    }

    static var shadow: Color {
        .init(UIColor.clear)
    }

    // MARK: Accent

    // Brand accent -- magenta (#ff2fb0), replacing the Flipper orange.
    static var a1: Color {
        .init(red: 1.0, green: 0.184, blue: 0.690)
    }

    // Secondary accent -- neon green (#39ff14).
    static var a2: Color {
        .init(red: 0.224, green: 1.0, blue: 0.078)
    }

    // MARK: Black

    // Grays inverted for the dark theme: the "stronger" levels (black88/black60,
    // used for prominent text) become light, the "weaker" ones (black4/black8,
    // used for dividers/subtle fills) stay close to the dark background. This
    // preserves each level's role -- subtle vs. prominent -- on a dark base.
    static var black4: Color {
        .init(red: 0.12, green: 0.12, blue: 0.14)
    }

    static var black8: Color {
        .init(red: 0.16, green: 0.15, blue: 0.18)
    }

    static var black12: Color {
        .init(red: 0.20, green: 0.18, blue: 0.22)
    }

    static var black16: Color {
        .init(red: 0.24, green: 0.22, blue: 0.26)
    }

    static var black20: Color {
        .init(red: 0.28, green: 0.26, blue: 0.30)
    }

    static var black30: Color {
        .init(red: 0.42, green: 0.40, blue: 0.44)
    }

    static var black40: Color {
        .init(red: 0.52, green: 0.50, blue: 0.54)
    }

    static var black60: Color {
        .init(red: 0.66, green: 0.64, blue: 0.68)
    }

    static var black80: Color {
        .init(red: 0.82, green: 0.80, blue: 0.84)
    }

    static var black88: Color {
        .init(red: 0.90, green: 0.89, blue: 0.92)
    }

    // MARK: Statuses

    static var sGreen: Color {
        .init(red: 0.2, green: 0.78, blue: 0.64)
    }

    static var sRed: Color {
        .init(red: 0.96, green: 0.25, blue: 0.25)
    }

    static var sYellow: Color {
        .init(red: 1.0, green: 0.81, blue: 0.37)
    }

    static var sGreenUpdate: Color {
        .init(red: 0.18, green: 0.85, blue: 0.2)
    }

    // MARK: Update channels

    static var development: Color {
        .init(red: 0.96, green: 0.25, blue: 0.25)
    }

    static var candidate: Color {
        .init(red: 0.54, green: 0.17, blue: 0.89)
    }

    static var release: Color {
        .init(red: 0.18, green: 0.85, blue: 0.2)
    }

    static var custom: Color {
        .black40
    }

    // MARK: Keys

    static var iButton: Color {
        .init(red: 0.88, green: 0.73, blue: 0.65)
    }

    static var rfid125: Color {
        .init(red: 1.0, green: 0.96, blue: 0.58)
    }

    static var nfc: Color {
        .init(red: 0.6, green: 0.81, blue: 1.0)
    }

    static var subGHz: Color {
        .init(red: 0.65, green: 0.96, blue: 0.75)
    }

    static var infrared: Color {
        .init(red: 1.0, green: 0.57, blue: 0.55)
    }

    static var badUSB: Color {
        .init(red: 1.0, green: 0.75, blue: 0.91)
    }
}
