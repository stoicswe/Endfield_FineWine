/* A window with one text field that has the keyboard. After a few seconds it writes what the
 * field holds to paste.txt beside the program. Usage: paste.exe [seconds]. Used to check that
 * the Mac's Command-V reaches a Windows text field as a paste. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    WNDCLASSA cls = { 0 };
    DWORD end = GetTickCount() + (cmd && atoi(cmd) > 0 ? atoi(cmd) : 8) * 1000;
    char text[256] = "", path[MAX_PATH], *p;
    HWND hwnd, edit;
    FILE *f;
    MSG msg;

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = inst;
    cls.lpszClassName = "FineWinePasteTest";
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&cls);
    hwnd = CreateWindowA(cls.lpszClassName, "Paste test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 220, 220, 360, 120, NULL, NULL, inst, NULL);
    edit = CreateWindowA("EDIT", "", WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL, 10, 10, 320, 26, hwnd, NULL, inst, NULL);
    SetFocus(edit);
    while (GetTickCount() < end)
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        Sleep(30);
    }
    GetWindowTextA(edit, text, sizeof(text));
    GetModuleFileNameA(NULL, path, MAX_PATH);
    if ((p = strrchr(path, '\\'))) strcpy(p + 1, "paste.txt");
    if ((f = fopen(path, "w"))) { fputs(text, f); fclose(f); }
    return 0;
}
