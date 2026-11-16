/* Shows a small window and a notification-area ("tray") icon for a few seconds.
 * Usage: tray.exe [seconds]. Used to check what macOS calls the program and that the tray
 * icon becomes a menu bar item. */
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    WNDCLASSA cls = { 0 };
    NOTIFYICONDATAA nid = { sizeof(nid) };
    DWORD end = GetTickCount() + (cmd && atoi(cmd) > 0 ? atoi(cmd) : 8) * 1000;
    HWND hwnd;
    MSG msg;

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = inst;
    cls.lpszClassName = "FineWineTrayTest";
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&cls);
    hwnd = CreateWindowA(cls.lpszClassName, "Tray test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 200, 200, 320, 160, NULL, NULL, inst, NULL);

    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP + 1;
    nid.hIcon = LoadIconA(NULL, (LPCSTR)IDI_INFORMATION);
    lstrcpyA(nid.szTip, "FineWine tray test");
    if (!Shell_NotifyIconA(NIM_ADD, &nid)) return 3;

    while (GetTickCount() < end)
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        Sleep(50);
    }
    Shell_NotifyIconA(NIM_DELETE, &nid);
    return 0;
}
