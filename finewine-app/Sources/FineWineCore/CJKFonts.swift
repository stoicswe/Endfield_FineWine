import Foundation

/// Windows' Chinese, Japanese and Korean fonts, which a Mac does not have, mapped to the Mac's
/// own fonts under the Windows names (`HKCU\Software\Wine\Fonts\Replacements`, read by GDI and
/// DirectWrite alike). For each name the first Mac font of its list that is installed is used; a
/// real font of the Windows name, if installed, wins. See
/// docs/project-information/26-chinese-japanese-and-korean-text.md.
///
/// The runtime's `wine.inf` (patches/runtime/0029) sets the English names. `wine.inf` is read in
/// the system code page, so it cannot carry the names programs written for those languages ask
/// for (宋体, ＭＳ ゴシック, 맑은 고딕, ...): FineWine writes those into each prefix from here
/// (`registryEdits(localizedOnly: true)`).
///
/// The tests check the English names against patches/runtime/0029. This is FineWine's only: the
/// patcher's CrossOver bottles are left with CrossOver's own list (the user's decision, 2026-11-17).
public enum CJKFonts {
    public struct Group: Equatable, Sendable {
        public let title: String
        public let windowsNames: [String]
        public let localizedNames: [String]
        public let macFonts: [String]
    }

    static let japaneseGothic = ["Hiragino Sans W3", "Hiragino Sans", "Hiragino Kaku Gothic ProN W3",
                                 "Hiragino Kaku Gothic ProN", "Arial Unicode MS"]
    static let simplifiedSans = ["PingFang SC", "Hiragino Sans GB W3", "Hiragino Sans GB", "Heiti SC", "STHeiti",
                                 "Arial Unicode MS"]
    static let simplifiedSerif = ["Songti SC", "STSong"] + simplifiedSans
    static let traditionalSerif = ["Songti TC", "Heiti TC", "Arial Unicode MS"]

    public static let groups: [Group] = [
        Group(title: "Japanese, gothic",
              windowsNames: ["MS UI Gothic", "MS Gothic", "MS PGothic", "Meiryo", "Meiryo UI", "Yu Gothic",
                             "Yu Gothic UI", "Yu Gothic Medium"],
              localizedNames: ["ＭＳ ゴシック", "ＭＳ Ｐゴシック", "メイリオ", "游ゴシック"],
              macFonts: japaneseGothic),
        Group(title: "Japanese, mincho",
              windowsNames: ["MS Mincho", "MS PMincho", "Yu Mincho"],
              localizedNames: ["ＭＳ 明朝", "ＭＳ Ｐ明朝", "游明朝"],
              macFonts: ["Hiragino Mincho ProN W3", "Hiragino Mincho ProN", "Hiragino Mincho Pro W3"] + japaneseGothic),
        Group(title: "Simplified Chinese, sans-serif",
              windowsNames: ["Microsoft YaHei", "Microsoft YaHei UI", "SimHei", "DengXian"],
              localizedNames: ["微软雅黑", "黑体", "等线"],
              macFonts: simplifiedSans),
        Group(title: "Simplified Chinese, serif",
              windowsNames: ["SimSun", "NSimSun", "SimSun-ExtB"],
              localizedNames: ["宋体", "新宋体"],
              macFonts: simplifiedSerif),
        Group(title: "Simplified Chinese, kai and fangsong",
              windowsNames: ["KaiTi", "FangSong"],
              localizedNames: ["楷体", "仿宋"],
              macFonts: ["Kaiti SC", "STKaiti", "STFangsong"] + simplifiedSerif),
        Group(title: "Traditional Chinese, sans-serif",
              windowsNames: ["Microsoft JhengHei", "Microsoft JhengHei UI"],
              localizedNames: ["微軟正黑體"],
              macFonts: ["PingFang TC", "Heiti TC", "Arial Unicode MS"]),
        Group(title: "Traditional Chinese, serif",
              windowsNames: ["PMingLiU", "MingLiU", "MingLiU_HKSCS", "PMingLiU-ExtB", "MingLiU-ExtB", "MingLiU_HKSCS-ExtB"],
              localizedNames: ["新細明體", "細明體"],
              macFonts: traditionalSerif),
        Group(title: "Traditional Chinese, kai",
              windowsNames: ["DFKai-SB"],
              localizedNames: ["標楷體"],
              macFonts: ["Kaiti TC", "BiauKai"] + traditionalSerif),
        Group(title: "Korean, sans-serif",
              windowsNames: ["Malgun Gothic", "Gulim", "GulimChe", "Dotum", "DotumChe"],
              localizedNames: ["맑은 고딕", "굴림", "굴림체", "돋움", "돋움체"],
              macFonts: ["Apple SD Gothic Neo", "AppleGothic", "Arial Unicode MS"]),
        Group(title: "Korean, serif",
              windowsNames: ["Batang", "BatangChe", "Gungsuh", "GungsuhChe"],
              localizedNames: ["바탕", "바탕체", "궁서", "궁서체"],
              macFonts: ["AppleMyungjo", "Apple SD Gothic Neo", "AppleGothic", "Arial Unicode MS"]),
    ]

    public static let replacementsKey = #"HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements"#

    /// Every name with the Mac fonts it stands for, English names first.
    public static var replacements: [(name: String, macFonts: [String])] {
        groups.flatMap { g in g.windowsNames.map { ($0, g.macFonts) } }
            + groups.flatMap { g in g.localizedNames.map { ($0, g.macFonts) } }
    }

    /// The registry values. `localizedOnly` leaves out the English names, which the runtime's
    /// own `wine.inf` already sets.
    public static func registryEdits(localizedOnly: Bool = false) -> [RegistryEdit] {
        let names = localizedOnly
            ? groups.flatMap { g in g.localizedNames.map { ($0, g.macFonts) } }
            : replacements.map { ($0.name, $0.macFonts) }
        return names.map { RegistryEdit.multiString(replacementsKey, $0.0, $0.1) }
    }
}
