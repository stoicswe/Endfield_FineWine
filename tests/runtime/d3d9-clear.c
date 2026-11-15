/* d3d9-clear.c: Direct3D 9 on a window that is never shown: creates a device, clears the back
 * buffer and reads a pixel back. Direct3D 9 and older are not covered by DXMT and go through
 * WineD3D. Prints the adapter and "d3d9-clear: ok" on success. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("d3d9-clear: Direct3DCreate9 failed\n"); return 1; }
    D3DADAPTER_IDENTIFIER9 id;
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, 0, 0, &id)))
        printf("adapter: %s, vendor %04lx\n", id.Description, (unsigned long)id.VendorId);

    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D9Test";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW, 0, 0, 256, 256, NULL, NULL, wc.hInstance, NULL);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = pp.BackBufferHeight = 64; pp.hDeviceWindow = window;
    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr)) { printf("d3d9-clear: CreateDevice failed 0x%08lx\n", (unsigned long)hr); return 1; }

    IDirect3DSurface9 *back = NULL, *copy = NULL;
    IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0xff, 0x80, 0x40), 1.0f, 0);
    hr = IDirect3DDevice9_GetBackBuffer(device, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back);
    if (SUCCEEDED(hr)) hr = IDirect3DDevice9_CreateOffscreenPlainSurface(device, 64, 64, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL);
    if (SUCCEEDED(hr)) hr = IDirect3DDevice9_GetRenderTargetData(device, back, copy);
    D3DLOCKED_RECT rect;
    if (SUCCEEDED(hr)) hr = IDirect3DSurface9_LockRect(copy, &rect, NULL, D3DLOCK_READONLY);
    if (FAILED(hr)) { printf("d3d9-clear: reading the back buffer failed 0x%08lx\n", (unsigned long)hr); return 1; }
    const unsigned char *px = (const unsigned char *)rect.pBits + 32 * rect.Pitch + 32 * 4;   /* B G R X */
    printf("pixel: %02x %02x %02x\n", px[2], px[1], px[0]);
    int ok = px[2] == 0xff && px[1] == 0x80 && px[0] == 0x40;
    printf(ok ? "d3d9-clear: ok\n" : "d3d9-clear: FAILED (wrong pixel)\n");
    return !ok;
}
