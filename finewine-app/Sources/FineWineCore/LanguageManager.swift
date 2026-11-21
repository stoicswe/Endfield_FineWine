import Foundation
import Combine

/// Supported languages for FineWine.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ko = "ko"
    case ja = "ja"
    case ar = "ar"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            return "System Default / 系统默认"
        case .en:
            return "English"
        case .zhHans:
            return "简体中文"
        case .zhHant:
            return "繁體中文"
        case .ko:
            return "한국어"
        case .ja:
            return "日本語"
        case .ar:
            return "العربية"
        }
    }
}

/// Global observable manager for app-wide localization and dynamic language switching.
public final class LanguageManager: ObservableObject, @unchecked Sendable {
    public static let shared = LanguageManager()

    private let storageKey = "finewine_language"
    private let lock = NSLock()

    @Published public var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: storageKey)
            updateActiveBundle()
        }
    }

    @Published public private(set) var activeLanguageCode: String = "en"
    private var _activeBundle: Bundle = Bundle.main
    private var _englishBundle: Bundle = Bundle.main

    public init() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        let initialLang = AppLanguage(rawValue: saved) ?? .system
        self.selectedLanguage = initialLang
        updateActiveBundle()
    }

    /// Automatically detects the user's preferred system language, falling back to English.
    public static func detectSystemLanguageCode() -> String {
        let preferred = Locale.preferredLanguages
        for lang in preferred {
            let lower = lang.lowercased()
            if lower.hasPrefix("zh-hans") || lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") {
                return "zh-Hans"
            }
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return "zh-Hant"
            }
            if lower.hasPrefix("ko") {
                return "ko"
            }
            if lower.hasPrefix("ja") {
                return "ja"
            }
            if lower.hasPrefix("ar") {
                return "ar"
            }
            if lower.hasPrefix("en") {
                return "en"
            }
        }
        return "en"
    }

    private func updateActiveBundle() {
        let code: String
        if selectedLanguage == .system {
            code = Self.detectSystemLanguageCode()
        } else {
            code = selectedLanguage.rawValue
        }

        let bundle = Self.bundle(for: code) ?? Bundle.main
        let enBundle = Self.bundle(for: "en") ?? Bundle.main

        lock.lock()
        self._activeBundle = bundle
        self._englishBundle = enBundle
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.activeLanguageCode = code
        }
    }

    private static func bundle(for code: String) -> Bundle? {
        // 1. Try Bundle.main
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        // 2. Try Bundle.module (SwiftPM target resources)
        #if SWIFT_PACKAGE
        if let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        #endif
        // 3. Fallback inside Resources directory
        if let resURL = Bundle.main.resourceURL {
            let direct = resURL.appendingPathComponent("\(code).lproj")
            if let b = Bundle(url: direct) {
                return b
            }
        }
        return nil
    }

    /// Translates the given key with optional format arguments.
    public func tr(_ key: String, args: [CVarArg]) -> String {
        lock.lock()
        let bundle = _activeBundle
        let fallback = _englishBundle
        let code = selectedLanguage == .system ? Self.detectSystemLanguageCode() : selectedLanguage.rawValue
        lock.unlock()

        var str = bundle.localizedString(forKey: key, value: nil, table: nil)
        if str == key {
            str = fallback.localizedString(forKey: key, value: key, table: nil)
        }
        if args.isEmpty {
            return str
        }
        return String(format: str, locale: Locale(identifier: code), arguments: args)
    }

    public func tr(_ key: String, _ args: CVarArg...) -> String {
        tr(key, args: args)
    }

    /// Whether the currently active language requires a Right-to-Left (RTL) layout direction (e.g. Arabic).
    public var isRTL: Bool {
        let code = selectedLanguage == .system ? Self.detectSystemLanguageCode() : selectedLanguage.rawValue
        return Self.isRightToLeft(languageCode: code)
    }

    /// Determines whether a language code represents a Right-to-Left script direction.
    public static func isRightToLeft(languageCode: String) -> Bool {
        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            return Locale.Language(identifier: languageCode).characterDirection == .rightToLeft
        } else {
            return Locale.characterDirection(forLanguage: languageCode) == .rightToLeft
        }
    }

    /// Wraps intrinsically LTR text (paths, URLs, commands, code) in Unicode Left-to-Right Isolates (LRI...PDI)
    /// to avoid bidirectional reordering artifacts in RTL text, per Apple HIG.
    public static func bidiIsolated(_ string: String) -> String {
        "\u{2066}\(string)\u{2069}"
    }
}

/// Convenience global translation function.
public func tr(_ key: String, _ args: CVarArg...) -> String {
    LanguageManager.shared.tr(key, args: args)
}

#if canImport(SwiftUI)
import SwiftUI

extension LanguageManager {
    /// SwiftUI LayoutDirection matching the active language's script direction per Apple HIG.
    public var layoutDirection: LayoutDirection {
        isRTL ? .rightToLeft : .leftToRight
    }
}
#endif


