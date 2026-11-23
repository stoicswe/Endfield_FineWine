/* One of the single-game cases taken over from Proton's Wine (runtime patch 0059), as a check
 * that they are keyed on the Steam app id and nothing else: with SteamGameId=882710 (TouHou
 * Makuka Sai) GDI+ measures a lone line break as a space wide, because the game makes a bitmap
 * of that size; for any other program it measures as before, narrower.
 *
 * Prints "game-cases: width=<n>"; the test script compares a run with the id and one without. */
#include <windows.h>
#include <stdio.h>

typedef struct { float X, Y, Width, Height; } RectF;
typedef struct { UINT32 version; void *callback; BOOL no_thread; BOOL no_codecs; } StartupInput;
int WINAPI GdiplusStartup(ULONG_PTR *token, const StartupInput *input, void *output);
int WINAPI GdipCreateFromHDC(HDC hdc, void **graphics);
int WINAPI GdipCreateFontFamilyFromName(const WCHAR *name, void *collection, void **family);
int WINAPI GdipCreateFont(void *family, float size, int style, int unit, void **font);
int WINAPI GdipMeasureString(void *graphics, const WCHAR *string, int length, void *font, const RectF *layout,
                             void *format, RectF *bounds, int *codepoints, int *lines);

int main(void)
{
    StartupInput input = { 1 };
    ULONG_PTR token;
    void *graphics = NULL, *family = NULL, *font = NULL;
    RectF layout = { 0, 0, 1000, 1000 }, bounds = { 0 };
    HDC dc = CreateCompatibleDC(NULL);

    if (GdiplusStartup(&token, &input, NULL) || GdipCreateFromHDC(dc, &graphics)
        || GdipCreateFontFamilyFromName(L"Arial", NULL, &family) || GdipCreateFont(family, 24, 0, 2, &font))
    {
        printf("game-cases: FAILED to set up GDI+\n");
        return 1;
    }
    GdipMeasureString(graphics, L"\n", 1, font, &layout, NULL, &bounds, NULL, NULL);
    printf("game-cases: width=%d\n", bounds.Width > 0.5f ? (int)(bounds.Width + 0.5f) : 0);
    return 0;
}
