/* How long Direct3D 9 takes to lock a small part of a big dynamic vertex buffer, write to it
 * and draw from it, many times a frame: what a game's renderer does for everything it builds
 * on the fly (Source fills one 4 MB buffer a few hundred bytes at a time).
 *
 * Build: i686-w64-mingw32-clang -O1 -o bench-d3d9-locks.exe bench-d3d9-locks.c -ld3d9
 * Prints the time per lock-write-draw in microseconds. */
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <string.h>

struct vertex { float x, y, z, rhw; DWORD colour; };
#define FVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 120, per_frame = 400;
    setvbuf(stdout, NULL, _IONBF, 0);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D9Locks";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"FineWine Direct3D 9 locks", WS_OVERLAPPEDWINDOW, 80, 80, 300, 300, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = pp.BackBufferHeight = 256; pp.hDeviceWindow = window;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *device = NULL;
    if (!d3d || FAILED(IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device))) {
        printf("bench-d3d9-locks: no device\n"); return 1; }

    enum { BYTES = 4 * 1024 * 1024, COUNT = BYTES / sizeof(struct vertex), BATCH = 24 };
    IDirect3DVertexBuffer9 *vb = NULL;
    if (FAILED(IDirect3DDevice9_CreateVertexBuffer(device, BYTES, D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY, FVF, D3DPOOL_DEFAULT, &vb, NULL))) {
        printf("bench-d3d9-locks: no buffer\n"); return 1; }

    LARGE_INTEGER freq, t0, t1; QueryPerformanceFrequency(&freq);
    unsigned at = COUNT; long long locks = 0;
    for (int frame = -10; frame < frames; frame++) {
        if (frame == 0) QueryPerformanceCounter(&t0);
        MSG msg; while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, 0xff102030, 1.0f, 0);
        IDirect3DDevice9_BeginScene(device);
        IDirect3DDevice9_SetFVF(device, FVF);
        IDirect3DDevice9_SetRenderState(device, D3DRS_LIGHTING, FALSE);
        IDirect3DDevice9_SetStreamSource(device, 0, vb, 0, sizeof(struct vertex));
        for (int i = 0; i < per_frame; i++) {
            struct vertex *v; DWORD flags = D3DLOCK_NOOVERWRITE;
            if (at + BATCH > COUNT) { at = 0; flags = D3DLOCK_DISCARD; }
            if (FAILED(IDirect3DVertexBuffer9_Lock(vb, at * sizeof(struct vertex), BATCH * sizeof(struct vertex), (void **)&v, flags))) { printf("bench-d3d9-locks: lock failed\n"); return 1; }
            for (int k = 0; k < BATCH; k++) { v[k].x = (float)((i * 7 + k * 3) % 256); v[k].y = (float)((i * 13 + k * 5) % 256); v[k].z = 0.5f; v[k].rhw = 1; v[k].colour = 0xff00ff00; }
            IDirect3DVertexBuffer9_Unlock(vb);
            IDirect3DDevice9_DrawPrimitive(device, D3DPT_TRIANGLELIST, at, BATCH / 3);
            at += BATCH; if (frame >= 0) locks++;
        }
        IDirect3DDevice9_EndScene(device);
        IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
    }
    QueryPerformanceCounter(&t1);
    double seconds = (double)(t1.QuadPart - t0.QuadPart) / freq.QuadPart;
    printf("bench-d3d9-locks: %.1f us per lock, write and draw (%lld of them, %.1f frames a second)\n",
           seconds * 1e6 / locks, locks, frames / seconds);
    return 0;
}
