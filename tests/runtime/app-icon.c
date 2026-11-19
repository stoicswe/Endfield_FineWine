/* app-icon.c — shows a window for two seconds, so that the program appears in the Dock with an
 * icon, set one of the ways Windows programs set it:
 *
 *   app-icon.exe own            the program's own icon resource only (built in with windres)
 *   app-icon.exe file <x.ico>   a 256-pixel icon loaded from a file at run time and given to the
 *                               window (WM_SETICON), as launchers do
 *   app-icon.exe module         a 32-pixel icon loaded from another module's icon group (shell32)
 *                               and given to the window; the Dock should get the whole group
 *
 * Run with FINEWINE_APP_ICON_DUMP=<file.png> to have the Mac driver write the Dock icon it made.
 * Prints "app-icon: ok" once the window has been shown.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "own";
    HWND hwnd;
    HICON icon = NULL;
    MSG msg;
    DWORD end;

    hwnd = CreateWindowExA(0, "STATIC", "FineWine icon test", WS_OVERLAPPEDWINDOW,
                           40, 40, 240, 120, NULL, NULL, GetModuleHandleA(NULL), NULL);
    if (!hwnd)
    {
        printf("app-icon: no window\n");
        return 1;
    }
    if (!strcmp(mode, "file") && argc > 2)
        icon = LoadImageA(NULL, argv[2], IMAGE_ICON, 256, 256, LR_LOADFROMFILE);
    else if (!strcmp(mode, "module"))
        icon = LoadImageA(LoadLibraryA(argc > 2 ? argv[2] : "shell32.dll"),
                          MAKEINTRESOURCEA(1), IMAGE_ICON, 32, 32, 0);
    if (strcmp(mode, "own") && !icon)
    {
        printf("app-icon: could not load the icon\n");
        return 1;
    }
    if (icon) SendMessageA(hwnd, WM_SETICON, ICON_BIG, (LPARAM)icon);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);

    end = GetTickCount() + 2000;
    while (GetTickCount() < end)
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        Sleep(20);
    }
    printf("app-icon: ok\n");
    return 0;
}
