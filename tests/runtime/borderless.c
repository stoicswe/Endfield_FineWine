/* A window with no title bar or frame, as launchers and games make them, shown for a few
 * seconds. Usage: borderless.exe [width height [seconds]]. Used to check its corners. */
#include <windows.h>
#include <stdlib.h>

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    WNDCLASSA cls = { 0 };
    int w = 800, h = 500, seconds = 8;
    DWORD end;
    MSG msg;

    if (__argc > 2) { w = atoi(__argv[1]); h = atoi(__argv[2]); }
    if (__argc > 3) seconds = atoi(__argv[3]);
    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = inst;
    cls.lpszClassName = "FineWineBorderless";
    cls.hbrBackground = CreateSolidBrush(RGB(200, 40, 40));
    RegisterClassA(&cls);
    CreateWindowExA(WS_EX_APPWINDOW, cls.lpszClassName, "Borderless", WS_POPUP | WS_VISIBLE, 150, 150, w, h, NULL, NULL, inst, NULL);
    end = GetTickCount() + seconds * 1000;
    while (GetTickCount() < end)
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        Sleep(50);
    }
    return 0;
}
