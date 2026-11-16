/* Direct3D 11 drawing into a window through a swap chain, the way every game does it: create
 * the window, device and swap chain, clear to a colour, present a few frames, and read the
 * back buffer to see the colour is there. Prints "d3d11-window: ok" or what went wrong.
 * Usage: d3d11-window.exe [x y [width height [seconds]]]  (the window's position, the size of
 * the swap chain's buffers when it is not to be the window's, and how long to keep presenting). */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    WNDCLASSA cls = { 0 };
    DXGI_SWAP_CHAIN_DESC desc = { 0 };
    D3D11_TEXTURE2D_DESC tex_desc;
    D3D11_MAPPED_SUBRESOURCE map;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *swap = NULL;
    ID3D11Texture2D *back = NULL, *copy = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    const float colour[4] = { 0.0f, 0.5f, 1.0f, 1.0f };
    int x = argc > 2 ? atoi(argv[1]) : 120, y = argc > 2 ? atoi(argv[2]) : 120, i, ok = 0;
    unsigned char *p;
    HRESULT hr;
    HWND hwnd;
    MSG msg;

    cls.lpfnWndProc = DefWindowProcA;
    cls.hInstance = GetModuleHandleA(NULL);
    cls.lpszClassName = "FineWineD3D11Window";
    RegisterClassA(&cls);
    hwnd = CreateWindowA(cls.lpszClassName, "Direct3D 11 window", WS_OVERLAPPEDWINDOW | WS_VISIBLE, x, y, 480, 320, NULL, NULL, cls.hInstance, NULL);

    desc.BufferCount = 2;
    desc.BufferDesc.Width = argc > 4 ? atoi(argv[3]) : 480;
    desc.BufferDesc.Height = argc > 4 ? atoi(argv[4]) : 320;
    desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.OutputWindow = hwnd;
    desc.SampleDesc.Count = 1;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &desc, &swap, &device, NULL, &ctx);
    if (FAILED(hr)) { printf("d3d11-window: no device and swap chain (%#lx)\n", hr); return 1; }
    if (FAILED(hr = IDXGISwapChain_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back))) { printf("d3d11-window: no back buffer (%#lx)\n", hr); return 1; }
    if (FAILED(hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &rtv))) { printf("d3d11-window: no render target (%#lx)\n", hr); return 1; }

    for (i = 0; i < 20; i++)
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, colour);
        if (i == 19)
        {
            ID3D11Texture2D_GetDesc(back, &tex_desc);
            tex_desc.Usage = D3D11_USAGE_STAGING; tex_desc.BindFlags = 0; tex_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ; tex_desc.MiscFlags = 0;
            if (SUCCEEDED(ID3D11Device_CreateTexture2D(device, &tex_desc, NULL, &copy)))
            {
                ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)copy, (ID3D11Resource *)back);
                if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)copy, 0, D3D11_MAP_READ, 0, &map)))
                {
                    p = map.pData;
                    ok = p[0] == 0 && p[1] >= 126 && p[1] <= 129 && p[2] == 255;
                    if (!ok) printf("d3d11-window: back buffer is %u,%u,%u\n", p[0], p[1], p[2]);
                    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)copy, 0);
                }
            }
        }
        if (FAILED(hr = IDXGISwapChain_Present(swap, 1, 0))) { printf("d3d11-window: present failed (%#lx)\n", hr); return 1; }
    }
    /* stays up long enough to be looked at, still presenting when asked to for longer */
    if (argc > 5)
    {
        DWORD end = GetTickCount() + atoi(argv[5]) * 1000;
        while (GetTickCount() < end)
        {
            while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
            ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, colour);
            if (FAILED(hr = IDXGISwapChain_Present(swap, 1, 0))) { printf("d3d11-window: present failed (%#lx)\n", hr); return 1; }
        }
    }
    else Sleep(1500);
    printf(ok ? "d3d11-window: ok\n" : "d3d11-window: FAILED\n");
    return !ok;
}
