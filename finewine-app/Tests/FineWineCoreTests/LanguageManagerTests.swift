import XCTest
@testable import FineWineCore

final class LanguageManagerTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        LanguageManager.shared.selectedLanguage = .en
    }

    func testSupportedLanguagesAreDefined() {
        let cases = AppLanguage.allCases
        XCTAssertTrue(cases.contains(.system))
        XCTAssertTrue(cases.contains(.en))
        XCTAssertTrue(cases.contains(.zhHans))
        XCTAssertTrue(cases.contains(.zhHant))
        XCTAssertTrue(cases.contains(.ko))
        XCTAssertTrue(cases.contains(.ja))
        XCTAssertTrue(cases.contains(.ar))
    }

    func testSystemDetectionFallbackToEnglish() {
        let detected = LanguageManager.detectSystemLanguageCode()
        XCTAssertTrue(["en", "zh-Hans", "zh-Hant", "ko", "ja", "ar"].contains(detected))
    }

    func testEnglishTranslationKeys() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .en

        let name = manager.tr("app.name")
        XCTAssertEqual(name, "FineWine")

        let manage = manager.tr("menu.manage_prefixes")
        XCTAssertEqual(manage, "Manage Prefixes")

        let count = manager.tr("main.program_count_multiple", 5)
        XCTAssertEqual(count, "5 programs")
    }

    func testSimplifiedChineseTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .zhHans

        let name = manager.tr("app.name")
        XCTAssertEqual(name, "FineWine")

        let manage = manager.tr("menu.manage_prefixes")
        XCTAssertEqual(manage, "管理容器")

        let count = manager.tr("main.program_count_multiple", 5)
        XCTAssertEqual(count, "5 个程序")
    }

    func testTraditionalChineseTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .zhHant

        let name = manager.tr("app.name")
        XCTAssertEqual(name, "FineWine")

        let manage = manager.tr("menu.manage_prefixes")
        XCTAssertEqual(manage, "管理容器")

        let count = manager.tr("main.program_count_multiple", 5)
        XCTAssertEqual(count, "5 個程式")
    }

    func testKoreanTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .ko

        let name = manager.tr("app.name")
        XCTAssertEqual(name, "FineWine")

        let manage = manager.tr("menu.manage_prefixes")
        XCTAssertEqual(manage, "프리픽스 관리")

        let count = manager.tr("main.program_count_multiple", 5)
        XCTAssertEqual(count, "프로그램 5개")
    }

    func testJapaneseTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .ja

        let name = manager.tr("app.name")
        XCTAssertEqual(name, "FineWine")

        let manage = manager.tr("menu.manage_prefixes")
        XCTAssertEqual(manage, "プレフィックスを管理")

        let count = manager.tr("main.program_count_multiple", 5)
        XCTAssertEqual(count, "5 個のアプリ")
    }

    func testArabicTranslation() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .ar

        let name = manager.tr("app.name")
        XCTAssertEqual(name, "FineWine")

        let manage = manager.tr("menu.manage_prefixes")
        XCTAssertEqual(manage, "إدارة الحاويات")

        let count = manager.tr("main.program_count_multiple", 5)
        XCTAssertTrue(count.contains("5") || count.contains("٥"))
        XCTAssertTrue(count.contains("برامج"))
    }

    func testRTLSupport() {
        let manager = LanguageManager.shared
        manager.selectedLanguage = .ar
        XCTAssertTrue(manager.isRTL)
        XCTAssertEqual(LanguageManager.isRightToLeft(languageCode: "ar"), true)
        XCTAssertEqual(LanguageManager.isRightToLeft(languageCode: "en"), false)
        XCTAssertEqual(LanguageManager.isRightToLeft(languageCode: "ja"), false)

        let isolated = LanguageManager.bidiIsolated("C:\\Program Files\\Game")
        XCTAssertTrue(isolated.hasPrefix("\u{2066}"))
        XCTAssertTrue(isolated.hasSuffix("\u{2069}"))
    }

    func testMissingKeyFallback() {
        let manager = LanguageManager.shared
        let nonExistent = manager.tr("non_existent_key_12345")
        XCTAssertEqual(nonExistent, "non_existent_key_12345")
    }
}

