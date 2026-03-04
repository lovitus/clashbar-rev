import AppKit
import SwiftUI

extension Font {
    static func appSystem(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: weight.nsFontWeight))
    }

    static func appMonospaced(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsFontWeight))
    }
}

extension Font.Weight {
    fileprivate var nsFontWeight: NSFont.Weight {
        switch self {
        case .ultraLight:
            .ultraLight
        case .thin:
            .thin
        case .light:
            .light
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        case .heavy:
            .heavy
        case .black:
            .black
        default:
            .regular
        }
    }
}
