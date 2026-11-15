/* fullscreen.c: a program that goes full screen the way a game does, for checking how the
 * runtime presents it (see FINEWINE_FULLSCREEN in the Mac driver).
 *
 * Shows a borderless black window covering the primary display for a few seconds, then makes
 * it a small window for a moment, then exits. It prints a line at each step so that a script
 * can look at the window from outside in between. This one does appear on screen.
 * Usage: fullscreen.exe [seconds full screen, default 3] */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms; MSG msg;
    while (GetTickCount() < end) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        Sleep(10);
    }
}

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 3;
    setvbuf(stdout, NULL, _IONBF, 0);
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH); wc.lpszClassName = L"FineWineFullscreenTest";
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    RegisterClassW(&wc);
    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"FineWine full-screen test", WS_POPUP, 0, 0, w, h, NULL, NULL, wc.hInstance, NULL);
    if (!window) { printf("fullscreen: CreateWindow failed %lu\n", GetLastError()); return 1; }
    ShowWindow(window, SW_SHOW); SetForegroundWindow(window);
    printf("fullscreen: covering %dx%d\n", w, h);
    pump(seconds * 1000);
    RECT r; GetWindowRect(window, &r);
    printf("fullscreen: still %ldx%ld, minimised %d\n", r.right - r.left, r.bottom - r.top, IsIconic(window));
    SetWindowLongW(window, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
    SetWindowPos(window, NULL, 100, 100, 640, 480, SWP_NOZORDER | SWP_FRAMECHANGED);
    printf("fullscreen: windowed\n");
    pump(2500);
    GetWindowRect(window, &r);
    printf("fullscreen: window is %ldx%ld\n", r.right - r.left, r.bottom - r.top);
    DestroyWindow(window);
    printf("fullscreen: ok\n");
    return 0;
}
