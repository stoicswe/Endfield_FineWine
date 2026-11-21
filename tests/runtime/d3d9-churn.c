/* Direct3D 9 under load, the way a game is while it loads a level: every frame big textures
 * and buffers are made, filled, drawn from and released, so that graphics memory is given
 * back while what was drawn with it may still be on its way to the GPU.
 *
 * Build: i686-w64-mingw32-clang -O1 -o d3d9-churn.exe d3d9-churn.c -ld3d9
 * Prints "d3d9-churn: ok" when every frame was presented and the device is still there. */
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <string.h>

struct vertex { float x, y, z, rhw; float u, v; };
#define FVF (D3DFVF_XYZRHW | D3DFVF_TEX1)

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 300, failures = 0;
    setvbuf(stdout, NULL, _IONBF, 0);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D9Churn";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"FineWine Direct3D 9 load", WS_OVERLAPPEDWINDOW, 80, 80, 300, 300, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = pp.BackBufferHeight = 256; pp.hDeviceWindow = window;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *device = NULL;
    if (!d3d || FAILED(IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device))) {
        printf("d3d9-churn: no device\n"); return 1; }

    for (int frame = 0; frame < frames && !failures; frame++) {
        MSG msg; while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        IDirect3DTexture9 *tex[3] = {0}; IDirect3DVertexBuffer9 *vb = NULL; D3DLOCKED_RECT lr; void *data;
        static const int sizes[3] = { 1024, 512, 256 };
        static const D3DFORMAT formats[3] = { D3DFMT_A8R8G8B8, D3DFMT_DXT5, D3DFMT_A8R8G8B8 };
        for (int t = 0; t < 3; t++) {
            if (FAILED(IDirect3DDevice9_CreateTexture(device, sizes[t], sizes[t], 0, 0, formats[t], D3DPOOL_MANAGED, &tex[t], NULL))) { failures++; break; }
            DWORD levels = IDirect3DTexture9_GetLevelCount(tex[t]);
            for (DWORD l = 0; l < levels; l++) if (SUCCEEDED(IDirect3DTexture9_LockRect(tex[t], l, &lr, NULL, 0))) {
                int size = sizes[t] >> l; if (size < 1) size = 1;
                int rows = formats[t] == D3DFMT_DXT5 ? (size + 3) / 4 : size;
                int bytes = formats[t] == D3DFMT_DXT5 ? ((size + 3) / 4) * 16 : size * 4;
                for (int y = 0; y < rows; y++) memset((BYTE *)lr.pBits + y * lr.Pitch, (frame + y) & 0xff, bytes);
                IDirect3DTexture9_UnlockRect(tex[t], l);
            }
        }
        /* a vertex buffer of 1 MB, of which the last four vertices are drawn */
        enum { COUNT = 1024 * 1024 / sizeof(struct vertex) };
        if (FAILED(IDirect3DDevice9_CreateVertexBuffer(device, COUNT * sizeof(struct vertex), D3DUSAGE_WRITEONLY, FVF, D3DPOOL_DEFAULT, &vb, NULL))) failures++;
        else if (SUCCEEDED(IDirect3DVertexBuffer9_Lock(vb, 0, 0, &data, 0))) {
            struct vertex quad[4] = { { 0, 0, 0.5f, 1, 0, 0 }, { 256, 0, 0.5f, 1, 1, 0 }, { 0, 256, 0.5f, 1, 0, 1 }, { 256, 256, 0.5f, 1, 1, 1 } };
            memset(data, 0, COUNT * sizeof(struct vertex));
            memcpy((struct vertex *)data + COUNT - 4, quad, sizeof(quad));
            IDirect3DVertexBuffer9_Unlock(vb);
        }
        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, 0xff102030, 1.0f, 0);
        if (SUCCEEDED(IDirect3DDevice9_BeginScene(device))) {
            IDirect3DDevice9_SetFVF(device, FVF);
            IDirect3DDevice9_SetRenderState(device, D3DRS_LIGHTING, FALSE);
            IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
            IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
            for (int t = 0; t < 3 && vb; t++) {
                IDirect3DDevice9_SetTexture(device, 0, (IDirect3DBaseTexture9 *)tex[t]);
                IDirect3DDevice9_SetStreamSource(device, 0, vb, 0, sizeof(struct vertex));
                if (FAILED(IDirect3DDevice9_DrawPrimitive(device, D3DPT_TRIANGLESTRIP, COUNT - 4, 2))) failures++;
            }
            IDirect3DDevice9_EndScene(device);
        }
        IDirect3DDevice9_SetTexture(device, 0, NULL);
        IDirect3DDevice9_SetStreamSource(device, 0, NULL, 0, 0);
        /* given back at once, before the frame is presented */
        for (int t = 0; t < 3; t++) if (tex[t]) IDirect3DTexture9_Release(tex[t]);
        if (vb) IDirect3DVertexBuffer9_Release(vb);
        HRESULT hr = IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
        Sleep(4);   /* a game does other work between frames; without it the renderer is only ever behind */
        if (FAILED(hr)) { printf("FAIL present, frame %d: 0x%08lx\n", frame, (unsigned long)hr); failures++; }
        if (argc > 2 && frame % 20 == 0) {
            MEMORYSTATUSEX ms = { sizeof(ms) }; GlobalMemoryStatusEx(&ms);
            printf("frame %d: %lu MB of address space free\n", frame, (unsigned long)(ms.ullAvailVirtual >> 20));
        }
        if (FAILED(IDirect3DDevice9_TestCooperativeLevel(device))) { printf("FAIL device lost at frame %d\n", frame); failures++; }
    }
    IDirect3DDevice9_Release(device); IDirect3D9_Release(d3d);
    DestroyWindow(window);
    if (failures) { printf("d3d9-churn: %d failure(s)\n", failures); return 1; }
    printf("d3d9-churn: ok\n");
    return 0;
}
