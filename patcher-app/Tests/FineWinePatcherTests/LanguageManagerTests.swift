import XCTest
@testable import FineWinePatcher

final class LanguageManagerTests: XCTestCase {

    func testSupportedLanguagesAreDefined() {
        let cases = AppLanguage.allCases
        XCTAssertTrue(cases.contains(.system))
        XCTAssertTrue(cases.contains(.en))
        XCTAssertTrue(cases.contains(.zhHans))
        XCTAssertTrue(cases.contains(.zhHant))
        XCTAssertTrue(cases.contains(.ja))
        XCTAssertTrue(cases.contains(.ko))
    }

    func testSystemDetectionFallbackToEnglish() {
        // If system language is English or any unsupported language, fallback should be "en"
        let detected = LanguageManager.detectSystemLanguageCode()
        XCTAssertTrue(["en", "zh-Hans", "zh-Hant", "ja", "ko"].contains(detected))
    }

    func testEnglishTranslationKeys() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .en

        let title = manager.tr("app.title")
        XCTAssertEqual(title, "FineWine Patcher")

        let subtitle = manager.tr("app.subtitle", "26.3")
        XCTAssertTrue(subtitle.contains("CrossOver 26.3"))
        XCTAssertTrue(subtitle.contains("Arknights: Endfield"))
    }

    func testSimplifiedChineseTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .zhHans

        let title = manager.tr("app.title")
        XCTAssertEqual(title, "FineWine 补丁工具")

        let subtitle = manager.tr("app.subtitle", "26.3")
        XCTAssertTrue(subtitle.contains("明日方舟：终末地"))
        XCTAssertTrue(subtitle.contains("Apple 芯片 (Apple Silicon)"))
    }

    func testTraditionalChineseTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .zhHant

        let title = manager.tr("app.title")
        XCTAssertEqual(title, "FineWine 補丁工具")

        let subtitle = manager.tr("app.subtitle", "26.3")
        XCTAssertTrue(subtitle.contains("明日方舟：終末地"))
        XCTAssertTrue(subtitle.contains("Apple 晶片 (Apple Silicon)"))
    }

    func testJapaneseTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .ja

        let title = manager.tr("app.title")
        XCTAssertEqual(title, "FineWine パッチャー")

        let subtitle = manager.tr("app.subtitle", "26.3")
        XCTAssertTrue(subtitle.contains("アークナイツ：エンドフィールド"))
    }

    func testKoreanTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .ko

        let title = manager.tr("app.title")
        XCTAssertEqual(title, "FineWine 패처")

        let subtitle = manager.tr("app.subtitle", "26.3")
        XCTAssertTrue(subtitle.contains("명일방주: 엔드필드"))
    }

    func testMissingKeyFallback() {
        let manager = LanguageManager.shared
        let nonExistent = manager.tr("non_existent_key_12345")
        XCTAssertEqual(nonExistent, "non_existent_key_12345")
    }
}

