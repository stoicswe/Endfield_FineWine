/* d3d9-fullscreen.c: Direct3D 9 in exclusive full screen at a resolution smaller than the
 * display, the way an older game starts (Portal: 960x600). Draws four coloured quarters
 * (red, green / blue, yellow) so that a look at the window from outside shows whether the
 * picture fills it. Covers the display for the given number of seconds.
 * Usage: d3d9-fullscreen.exe [width] [height] [seconds] [windowed: 0|1]
 * Prints what Windows reports at each step and "d3d9-fullscreen: ok". */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    int width = argc > 1 ? atoi(argv[1]) : 960, height = argc > 2 ? atoi(argv[2]) : 600;
    int seconds = argc > 3 ? atoi(argv[3]) : 5, windowed = argc > 4 ? atoi(argv[4]) : 0;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("screen before: %dx%d\n", GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("d3d9-fullscreen: Direct3DCreate9 failed\n"); return 1; }
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D9Fullscreen";
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"FineWine Direct3D 9 full screen", windowed ? WS_OVERLAPPEDWINDOW : WS_POPUP,
                                  windowed ? 100 : 0, windowed ? 100 : 0, width, height, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(window, SW_SHOW);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = windowed; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = width; pp.BackBufferHeight = height; pp.hDeviceWindow = window;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_ONE;
    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr)) { printf("d3d9-fullscreen: CreateDevice failed 0x%08lx\n", (unsigned long)hr); return 1; }

    DWORD end = GetTickCount() + seconds * 1000, reported = 0;
    while (GetTickCount() < end) {
        MSG msg; while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        D3DRECT q[4] = { {0, 0, width / 2, height / 2}, {width / 2, 0, width, height / 2},
                         {0, height / 2, width / 2, height}, {width / 2, height / 2, width, height} };
        D3DCOLOR c[4] = { 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffff00 };
        for (int i = 0; i < 4; i++) IDirect3DDevice9_Clear(device, 1, &q[i], D3DCLEAR_TARGET, c[i], 1.0f, 0);
        IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
        if (!reported && GetTickCount() + (seconds * 1000 - 1500) > end) {
            RECT wr, cr; DEVMODEW dm = {0}; dm.dmSize = sizeof(dm);
            GetWindowRect(window, &wr); GetClientRect(window, &cr); EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &dm);
            printf("state: window %ld,%ld-%ld,%ld client %ldx%ld mode %lux%lu screen %dx%d\n", wr.left, wr.top, wr.right, wr.bottom,
                   cr.right, cr.bottom, (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight,
                   GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
            {
                /* The pointer: put it in the middle of the screen as this program sees it, and
                 * say where that was and what comes back. A script compares the Mac's own
                 * pointer position at that moment with the middle of the window. */
                POINT before, mid = { GetSystemMetrics(SM_CXSCREEN) / 2, GetSystemMetrics(SM_CYSCREEN) / 2 }, got = {0, 0};
                GetCursorPos(&before);
                SetCursorPos(mid.x, mid.y);
                Sleep(300);
                GetCursorPos(&got);
                printf("pointer: set %ld,%ld got %ld,%ld client middle %ld,%ld\n", mid.x, mid.y, got.x, got.y, cr.right / 2, cr.bottom / 2);
                Sleep(700);
                SetCursorPos(before.x, before.y);
            }
            printf("ready\n");
            reported = 1;
        }
    }
    IDirect3DDevice9_Release(device); IDirect3D9_Release(d3d); DestroyWindow(window);
    printf("d3d9-fullscreen: ok\n");
    return 0;
}
