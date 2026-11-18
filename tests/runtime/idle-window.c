/* A small window that pumps messages for a number of seconds (default 10), then exits.
 *
 * Used to check what Wine does when a program is switched to: tests/runtime/activate.swift
 * activates it and the app that was in front, back and forth, while WINEDEBUG=trace+display
 * shows whether Wine read the displays again each time (it should not, when nothing changed).
 *
 * Prints "idle-window: ready" once the window is up.
 * Build: x86_64-w64-mingw32-clang -O1 -o idle-window.exe idle-window.c -luser32 -lgdi32 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main( int argc, char **argv )
{
    DWORD end = GetTickCount() + (argc > 1 ? atoi( argv[1] ) : 10) * 1000;
    WNDCLASSA wc = {0};
    HWND hwnd;
    MSG msg;

    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA( NULL );
    wc.lpszClassName = "finewine-idle";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA( &wc );
    hwnd = CreateWindowA( "finewine-idle", "idle", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 60, 60, 240, 120,
                          NULL, NULL, wc.hInstance, NULL );
    if (!hwnd) { printf( "idle-window: FAILED to create a window\n" ); return 1; }
    printf( "idle-window: ready\n" );
    fflush( stdout );
    while ((int)(end - GetTickCount()) > 0)
    {
        while (PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
        Sleep( 10 );
    }
    return 0;
}
