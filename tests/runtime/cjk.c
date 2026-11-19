/* cjk.c — checks that Chinese, Japanese and Korean text works the way it does on Windows.
 *
 * Prints, one result per line ("ok ..." or "FAIL ..."):
 *   - the ANSI and OEM code pages and the locale Wine picked (from LANG / LC_ALL);
 *   - that the East Asian code pages (932 Shift-JIS, 936 GBK, 949 Korean, 950 Big5) turn their
 *     bytes into the right characters and back, and that the ANSI code page does too when it is
 *     one of them (the "-A" functions of programs that are not Unicode go through it);
 *   - for a set of fonts programs ask for (Windows' own dialog and East Asian font names), whether
 *     each sample character draws as a real glyph rather than the empty box drawn for a character
 *     no font has (GDI);
 *   - which font DirectWrite's system fallback (what Chromium-based launchers draw text with)
 *     picks for each script in each East Asian locale, and that it picks one.
 *
 * Usage: cjk.exe [expected ANSI code page] [more GDI font names to check...]
 * Built with -municode: the names may be in any language.
 * The code page is 0 to check nothing about it.
 * Exit status 0 when every check passes. Draws into memory only; it opens no window.
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <dwrite_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void result(int ok, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    printf(ok ? "ok   " : "FAIL ");
    vprintf(fmt, args);
    printf("\n");
    va_end(args);
    if (!ok) failures++;
}

/* Each code page with a short sample in its own encoding and the characters it stands for. */
static const struct
{
    UINT cp;
    const char *bytes;
    const WCHAR *text;
} samples[] =
{
    { 932, "\x93\xfa\x96\x7b\x8c\xea", L"\x65e5\x672c\x8a9e" },               /* 日本語 */
    { 936, "\xbc\xf2\xcc\xe5\xd6\xd0\xce\xc4", L"\x7b80\x4f53\x4e2d\x6587" }, /* 简体中文 */
    { 949, "\xc7\xd1\xb1\xb9\xbe\xee", L"\xd55c\xad6d\xc5b4" },               /* 한국어 */
    { 950, "\xc1\x63\xc5\xe9\xa4\xa4\xa4\xe5", L"\x7e41\x9ad4\x4e2d\x6587" }, /* 繁體中文 */
};

static int convert_check(UINT cp, const char *bytes, const WCHAR *text)
{
    WCHAR wide[64];
    char back[64];
    int n = MultiByteToWideChar(cp, MB_ERR_INVALID_CHARS, bytes, -1, wide, 64);
    if (n <= 0 || wcscmp(wide, text)) return 0;
    n = WideCharToMultiByte(cp, 0, text, -1, back, sizeof(back), NULL, NULL);
    return n > 0 && !strcmp(back, bytes);
}

/* Draws one character in black on a white 64×64 bitmap; returns a hash of the pixels and the
 * number of pixels drawn. */
static DWORD draw(HDC dc, DWORD *bits, WCHAR ch, int *inked)
{
    RECT all = { 0, 0, 64, 64 };
    DWORD hash = 2166136261u;
    int i, set = 0;
    FillRect(dc, &all, GetStockObject(WHITE_BRUSH));
    TextOutW(dc, 4, 4, &ch, 1);
    GdiFlush();
    for (i = 0; i < 64 * 64; i++)
    {
        int ink = (bits[i] & 0xffffff) != 0xffffff;
        hash = (hash ^ ink) * 16777619u;
        set += ink;
    }
    *inked = set;
    return hash;
}

/* A text source for IDWriteFontFallback::MapCharacters: one string in one locale. */
struct source
{
    IDWriteTextAnalysisSource iface;
    const WCHAR *text;
    const WCHAR *locale;
};

static HRESULT WINAPI source_QueryInterface(IDWriteTextAnalysisSource *iface, REFIID riid, void **out)
{
    if (IsEqualIID(riid, &IID_IDWriteTextAnalysisSource) || IsEqualIID(riid, &IID_IUnknown))
    {
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG WINAPI source_AddRef(IDWriteTextAnalysisSource *iface) { return 2; }
static ULONG WINAPI source_Release(IDWriteTextAnalysisSource *iface) { return 1; }
static HRESULT WINAPI source_GetTextAtPosition(IDWriteTextAnalysisSource *iface, UINT32 pos,
                                               const WCHAR **text, UINT32 *len)
{
    struct source *s = (struct source *)iface;
    UINT32 n = (UINT32)wcslen(s->text);
    *text = pos < n ? s->text + pos : NULL;
    *len = pos < n ? n - pos : 0;
    return S_OK;
}
static HRESULT WINAPI source_GetTextBeforePosition(IDWriteTextAnalysisSource *iface, UINT32 pos,
                                                   const WCHAR **text, UINT32 *len)
{
    struct source *s = (struct source *)iface;
    *text = pos ? s->text : NULL;
    *len = pos;
    return S_OK;
}
static DWRITE_READING_DIRECTION WINAPI source_GetParagraphReadingDirection(IDWriteTextAnalysisSource *iface)
{
    return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
}
static HRESULT WINAPI source_GetLocaleName(IDWriteTextAnalysisSource *iface, UINT32 pos, UINT32 *len,
                                           const WCHAR **locale)
{
    struct source *s = (struct source *)iface;
    *len = (UINT32)wcslen(s->text) - pos;
    *locale = s->locale;
    return S_OK;
}
static HRESULT WINAPI source_GetNumberSubstitution(IDWriteTextAnalysisSource *iface, UINT32 pos, UINT32 *len,
                                                   IDWriteNumberSubstitution **sub)
{
    *len = 0;
    *sub = NULL;
    return S_OK;
}
static IDWriteTextAnalysisSourceVtbl source_vtbl =
{
    source_QueryInterface, source_AddRef, source_Release, source_GetTextAtPosition,
    source_GetTextBeforePosition, source_GetParagraphReadingDirection, source_GetLocaleName,
    source_GetNumberSubstitution,
};

static void check_directwrite(void)
{
    static const struct { const WCHAR *what; const WCHAR *text; } scripts[] =
    {
        { L"kana", L"\x3042\x30ab" }, { L"kanji", L"\x65e5\x672c" }, { L"simplified", L"\x7b80\x4f53" },
        { L"traditional", L"\x7e41\x9ad4" }, { L"hangul", L"\xd55c\xad6d" },
    };
    static const WCHAR *const locales[] = { L"", L"ja-JP", L"zh-CN", L"zh-TW", L"ko-KR" };
    IDWriteFactory2 *factory;
    IDWriteFontFallback *fallback;
    unsigned i, j;

    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory2, (IUnknown **)&factory)))
    {
        result(0, "DirectWrite: no IDWriteFactory2");
        return;
    }
    if (FAILED(IDWriteFactory2_GetSystemFontFallback(factory, &fallback)))
    {
        result(0, "DirectWrite: no system font fallback");
        IDWriteFactory2_Release(factory);
        return;
    }
    for (i = 0; i < ARRAYSIZE(locales); i++)
    {
        char line[512];
        int ok = 1;
        sprintf(line, "DirectWrite fallback, locale %-6ls", locales[i][0] ? locales[i] : L"(none)");
        for (j = 0; j < ARRAYSIZE(scripts); j++)
        {
            struct source src = { { &source_vtbl }, scripts[j].text, locales[i] };
            UINT32 mapped = 0, len = (UINT32)wcslen(scripts[j].text);
            IDWriteFont *font = NULL;
            float scale;
            WCHAR name[64] = L"none";

            IDWriteFontFallback_MapCharacters(fallback, &src.iface, 0, len, NULL, L"Segoe UI",
                    DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                    &mapped, &font, &scale);
            if (font)
            {
                IDWriteFontFamily *family;
                IDWriteLocalizedStrings *names;
                if (SUCCEEDED(IDWriteFont_GetFontFamily(font, &family)))
                {
                    if (SUCCEEDED(IDWriteFontFamily_GetFamilyNames(family, &names)))
                    {
                        IDWriteLocalizedStrings_GetString(names, 0, name, ARRAYSIZE(name));
                        IDWriteLocalizedStrings_Release(names);
                    }
                    IDWriteFontFamily_Release(family);
                }
                IDWriteFont_Release(font);
            }
            if (!font || mapped != len) ok = 0;
            sprintf(line + strlen(line), " %ls=%ls", scripts[j].what, name);
        }
        result(ok, "%s", line);
    }
    IDWriteFontFallback_Release(fallback);
    IDWriteFactory2_Release(factory);
}

static const WCHAR *const fonts[] =
{
    L"MS Shell Dlg", L"MS Shell Dlg 2", L"Tahoma", L"Arial", L"Segoe UI", L"System",
    L"MS UI Gothic", L"MS Gothic", L"MS PGothic", L"Meiryo", L"Meiryo UI", L"Yu Gothic UI", L"MS Mincho",
    L"SimSun", L"NSimSun", L"SimHei", L"Microsoft YaHei", L"Microsoft YaHei UI", L"DengXian",
    L"PMingLiU", L"MingLiU", L"Microsoft JhengHei", L"Microsoft JhengHei UI",
    L"Gulim", L"Dotum", L"Batang", L"Malgun Gothic",
};

/* One character from each script: Japanese kana and kanji, simplified and traditional Han,
 * and Hangul. */
static const WCHAR chars[] = { 0x3042, 0x30ab, 0x65e5, 0x7b80, 0x9ad4, 0xd55c, 0xae00, 0 };

int wmain(int argc, WCHAR **argv)
{
    UINT expected = argc > 1 ? (UINT)_wtoi(argv[1]) : 0;
    WCHAR locale[LOCALE_NAME_MAX_LENGTH] = L"";
    BITMAPINFO info = { { sizeof(BITMAPINFOHEADER), 64, -64, 1, 32, BI_RGB } };
    HDC dc;
    HBITMAP bitmap;
    DWORD *bits;
    unsigned i, j;
    int none_inked;
    DWORD none;

    GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH);
    printf("info ANSI code page %u, OEM code page %u, locale %ls\n", GetACP(), GetOEMCP(), locale);
    if (expected) result(GetACP() == expected, "ANSI code page is %u (wanted %u)", GetACP(), expected);

    for (i = 0; i < ARRAYSIZE(samples); i++)
    {
        result(convert_check(samples[i].cp, samples[i].bytes, samples[i].text),
               "code page %u converts both ways", samples[i].cp);
        if (GetACP() == samples[i].cp)
            result(convert_check(CP_ACP, samples[i].bytes, samples[i].text),
                   "the ANSI code page (%u) converts both ways", samples[i].cp);
    }

    dc = CreateCompatibleDC(NULL);
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, (void **)&bits, NULL, 0);
    SelectObject(dc, bitmap);
    SetBkMode(dc, TRANSPARENT);

    for (i = 0; i < ARRAYSIZE(fonts) + (argc > 2 ? argc - 2 : 0); i++)
    {
        WCHAR name[LF_FACESIZE];
        HFONT font;
        if (i < ARRAYSIZE(fonts)) lstrcpynW(name, fonts[i], LF_FACESIZE);
        else lstrcpynW(name, argv[i - ARRAYSIZE(fonts) + 2], LF_FACESIZE);
        font = CreateFontW(-32, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
                           NONANTIALIASED_QUALITY, 0, name);
        HGDIOBJ old = SelectObject(dc, font);
        WCHAR face[LF_FACESIZE] = L"";
        char missing[64] = "";
        int inked;

        GetTextFaceW(dc, LF_FACESIZE, face);
        /* An unassigned character draws as whatever this font draws for "no glyph". */
        none = draw(dc, bits, 0x0378, &none_inked);
        for (j = 0; chars[j]; j++)
        {
            DWORD hash = draw(dc, bits, chars[j], &inked);
            if (!inked || (hash == none && inked == none_inked))
                sprintf(missing + strlen(missing), " U+%04X", chars[j]);
        }
        result(!missing[0], "%-22ls (drawn with %ls)%s%s", name, face,
               missing[0] ? " has no glyph for" : " draws Japanese, Chinese and Korean", missing);
        SelectObject(dc, old);
        DeleteObject(font);
    }
    DeleteDC(dc);
    DeleteObject(bitmap);

    check_directwrite();
    printf("%s\n", failures ? "cjk: some checks failed" : "cjk: all checks passed");
    return failures ? 1 : 0;
}
