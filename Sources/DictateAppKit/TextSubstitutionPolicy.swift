import Foundation
import CoreFoundation

/// Dictate 1.18 (decision D15): automatic text substitution policy.
/// Evaluates whether the frontmost/target app's text system might rewrite typed keystrokes.
public struct TextSubstitutionPolicy: Sendable {
    /// terminals do not run the AppKit text-substitution system
    public static let nonRewritingBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
    ]

    public static let substitutionKeys: [String] = [
        "NSAutomaticSpellingCorrectionEnabled",
        "NSAutomaticQuoteSubstitutionEnabled",
        "NSAutomaticDashSubstitutionEnabled",
        "NSAutomaticTextReplacementEnabled",
        "NSAutomaticPeriodSubstitutionEnabled",
        "NSAutomaticCapitalizationEnabled",
        "WebAutomaticSpellingCorrectionEnabled",
        "WebAutomaticQuoteSubstitutionEnabled",
        "WebAutomaticDashSubstitutionEnabled",
        "WebAutomaticTextReplacementEnabled",
    ]

    public typealias PreferencesReader = @Sendable (_ key: String, _ bundleID: String) -> Bool?

    private let reader: PreferencesReader

    public init(reader: @escaping PreferencesReader = Self.systemReader) {
        self.reader = reader
    }

    public static let systemReader: PreferencesReader = { key, bundleID in
        guard let value = CFPreferencesCopyAppValue(key as CFString, bundleID as CFString) else {
            return nil
        }
        if let bool = value as? Bool {
            return bool
        }
        if let num = value as? NSNumber {
            return num.boolValue
        }
        return nil
    }

    /// Evaluates whether typing is allowed without substitution rewriting risk.
    /// Returns true if typing is permitted; false if substitution risk requires paste.
    public func allowsTyping(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else {
            return false
        }
        if Self.nonRewritingBundleIDs.contains(bundleID) {
            return true
        }
        for key in Self.substitutionKeys {
            let isOn = reader(key, bundleID) ?? true
            if isOn {
                return false
            }
        }
        return true
    }
}
