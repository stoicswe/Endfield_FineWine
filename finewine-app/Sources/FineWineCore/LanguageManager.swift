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
}

/// Convenience global translation function.
public func tr(_ key: String, _ args: CVarArg...) -> String {
    LanguageManager.shared.tr(key, args: args)
}

