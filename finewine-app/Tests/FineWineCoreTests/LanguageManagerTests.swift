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
    }

    func testSystemDetectionFallbackToEnglish() {
        let detected = LanguageManager.detectSystemLanguageCode()
        XCTAssertTrue(["en", "zh-Hans", "zh-Hant", "ko", "ja"].contains(detected))
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

    func testMissingKeyFallback() {
        let manager = LanguageManager.shared
        let nonExistent = manager.tr("non_existent_key_12345")
        XCTAssertEqual(nonExistent, "non_existent_key_12345")
    }
}

