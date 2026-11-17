# Chinese, Japanese and Korean text

FineWine's runtime shows Chinese, Japanese and Korean text in every Windows program, in any
prefix, with nothing to install. This page covers what was broken, what the runtime does now
(`patches/runtime/0029`), the per-prefix "Language for non-Unicode programs", and what is still
untested.

## What was wrong

Measured on 2026-11-17 with `tests/runtime/cjk.c` in a new prefix, before the change:

- **The code pages were fine.** Shift-JIS (932), GBK (936), Korean (949) and Big5 (950) convert
  both ways, and the ANSI code page follows the locale Wine is started with.
- **The fonts were not.** Every one of 27 fonts that programs ask for drew all seven sample
  characters (kana, kanji, simplified and traditional Han, Hangul) as empty boxes. That covers
  Wine's dialog fonts, Arial, and the Windows East Asian fonts themselves: "MS Gothic",
  "Microsoft YaHei", "PMingLiU", "Malgun Gothic" and the rest.

The Mac has the fonts, and Wine loads all 887 families. Nothing points at them:

- Programs ask for Windows' East Asian fonts by name. A Mac does not have them, so Wine
  substitutes Arial.
- Wine's GDI font links name those same Windows fonts. Its links are what lets a font with no
  glyph for a character borrow one from another font.
- DirectWrite's fallback, which Chromium-based launchers draw text with, names Linux's Noto CJK
  fonts.

## What the runtime does

**Windows names for the Mac's fonts.** `wine.inf` writes `HKCU\Software\Wine\Fonts\Replacements`.
GDI and DirectWrite both read this key, and each entry makes a Windows font name an alias of a
Mac font. Each entry is a list, and the first font in it that is installed is used. A real font
of the Windows name, installed in the prefix, always wins.

| Windows fonts | Mac font used |
|---|---|
| MS UI Gothic, MS Gothic, MS PGothic, Meiryo (UI), Yu Gothic (UI) | Hiragino Sans W3 (Hiragino Kaku Gothic ProN) |
| MS Mincho, MS PMincho, Yu Mincho | Hiragino Mincho ProN W3 |
| Microsoft YaHei (UI), SimHei, DengXian | PingFang SC if downloaded, else Hiragino Sans GB W3, Heiti SC |
| SimSun, NSimSun | Songti SC (STSong), then the above |
| KaiTi, FangSong | Kaiti SC or STFangsong if downloaded, else Songti SC |
| Microsoft JhengHei (UI) | PingFang TC if downloaded, else Heiti TC |
| PMingLiU, MingLiU (and the HKSCS and ExtB variants) | Songti TC, then Heiti TC |
| DFKai-SB | Kaiti TC or BiauKai if downloaded, else Songti TC |
| Malgun Gothic, Gulim, Dotum (and -Che) | Apple SD Gothic Neo, then AppleGothic |
| Batang, Gungsuh (and -Che) | AppleMyungjo if present, else Apple SD Gothic Neo |

Arial Unicode MS comes last in every list. Every other font in the table except PingFang and
the Kaiti fonts lives in `/System/Library/Fonts` and ships with macOS. PingFang and Kaiti are
downloadable fonts.

**Font links for every font.** Once the Windows names exist, Wine's own font links resolve, so
any font falls back to the East Asian fonts for characters it lacks. On Windows the link order
follows the system locale, and so it does here. The order decides which language's forms shared
Han characters take.

Wine picks its link lists by whichever font "MS Shell Dlg" is substituted to. With "Mac
appearance" on, FineWine sets that substitute to Helvetica Neue, which no list is keyed on.
When nothing matches, the runtime now picks the list by the ANSI code page. Before, it picked
nothing.

**DirectWrite.** After each Noto font, the system fallback now lists the font Windows itself
falls back to:

- Yu Gothic UI for Japanese
- Microsoft YaHei for Simplified Chinese
- Microsoft JhengHei for Traditional Chinese
- Malgun Gothic for Korean

The replacements above make each of these a Mac font. The fallback also matches a region locale
such as "zh-CN" or "ko-KR" to the mappings made for its script or language ("zh-Hans", "ko").
Before, only exact names matched, so Chinese and Korean text got Japanese forms.

After the change, the same test passes in full:

- GDI draws every font, with Wine's default dialog font and with FineWine's.
- The DirectWrite fallback finds a font for each script in each locale, and follows the locale:
  Simplified forms for zh-CN, Traditional for zh-TW, Hangul first for ko-KR.

## Language for non-Unicode programs

Unicode programs, most games among them, show every language whatever this is set to.
Programs that are not Unicode, older installers among them, read and write text in the ANSI
code page. Windows sets that code page through "Language for non-Unicode programs", and a
FineWine prefix has the same setting under **Configuration → Windows**:

| Choice | Code page | What FineWine sets |
|---|---|---|
| Automatic | what Wine derives from the Mac's language and region | nothing |
| English | 1252 | `LC_CTYPE=en_US.UTF-8` |
| 日本語 | 932 | `LC_CTYPE=ja_JP.UTF-8` |
| 简体中文 | 936 | `LC_CTYPE=zh_CN.UTF-8` |
| 繁體中文 | 950 | `LC_CTYPE=zh_TW.UTF-8` |
| 한국어 | 949 | `LC_CTYPE=ko_KR.UTF-8` |

Wine takes the ANSI code page from `LC_CTYPE`. An inherited `LC_ALL` would override that, so
FineWine drops it when a language is chosen.

Wine's interface language follows `LC_MESSAGES` or `LANG`, or the Mac's language when neither is
set, so it stays the Mac's. The region formats (dates, numbers) follow the chosen language, as
they did in the test.

A Mac set to English with the region Japan gets code page 1252 on Automatic, because Wine needs
both the language and the region. Choose 日本語 for 932.

## Not yet checked

- **Typing.** The Mac driver passes macOS input methods through to Windows programs. Nothing
  here has tested typing Chinese, Japanese or Korean, because the tests don't drive the
  keyboard.
- **Console windows** (`cmd`, a program's console) draw with GDI fonts and should get the same
  fallback. Nothing has looked at one.
- **Real programs.** Nothing here has opened a Chinese, Japanese or Korean installer or
  launcher yet. Arknights: Endfield's CN launcher would be a good first test.

The checks run as part of `scripts/test-finewine-runtime.sh` (step 6a).
