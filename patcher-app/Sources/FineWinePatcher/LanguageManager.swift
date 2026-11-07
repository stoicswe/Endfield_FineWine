import Foundation
import SwiftUI

/// Supported languages for FineWine Patcher.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja = "ja"
    case ko = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "System Default / 系统默认"
        case .en:
            return "English"
        case .zhHans:
            return "简体中文"
        case .zhHant:
            return "繁體中文"
        case .ja:
            return "日本語"
        case .ko:
            return "한국어"
        }
    }
}

/// Global observable manager for app-wide localization and dynamic language switching.
final class LanguageManager: ObservableObject, @unchecked Sendable {
    static let shared = LanguageManager()

    private let storageKey = "finewine_patcher_language"
    private let lock = NSLock()

    @Published var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: storageKey)
            updateActiveBundle()
        }
    }

    @Published private(set) var activeLanguageCode: String = "en"
    private var _activeBundle: Bundle = Bundle.main
    private var _englishBundle: Bundle = Bundle.main

    init() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        let initialLang = AppLanguage(rawValue: saved) ?? .system
        self.selectedLanguage = initialLang
        updateActiveBundle()
    }

    /// Automatically detects user's preferred system language, falling back to English.
    static func detectSystemLanguageCode() -> String {
        let preferred = Locale.preferredLanguages
        for lang in preferred {
            let lower = lang.lowercased()
            if lower.hasPrefix("zh-hans") || lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") {
                return "zh-Hans"
            }
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return "zh-Hant"
            }
            if lower.hasPrefix("ja") {
                return "ja"
            }
            if lower.hasPrefix("ko") {
                return "ko"
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
    nonisolated func tr(_ key: String, args: [CVarArg]) -> String {
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

    nonisolated func tr(_ key: String, _ args: CVarArg...) -> String {
        tr(key, args: args)
    }
}

/// Convenience global translation function.
nonisolated func tr(_ key: String, _ args: CVarArg...) -> String {
    LanguageManager.shared.tr(key, args: args)
}
