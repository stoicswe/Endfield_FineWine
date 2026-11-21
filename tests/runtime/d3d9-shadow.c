/* Direct3D 9 shadow mapping the hardware way: a depth texture is rendered into, then sampled
 * by a pixel shader, where Direct3D 9 compares the depth with the third texture coordinate and
 * gives 1 (lit) or 0 (in shadow). Games draw their shadows like this.
 *
 * The depth texture is cleared to 0.5. A quad sampled with a reference depth of 0.25 is in
 * front of what the depth texture holds (lit, white); one with 0.75 is behind it (black).
 *
 * Build: i686-w64-mingw32-clang -O1 -o d3d9-shadow.exe d3d9-shadow.c -ld3d9
 * Prints the two colours and "d3d9-shadow: ok" when they are white and black. */
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

struct vertex { float x, y, z, rhw; float u, v, w, q; };
#define FVF (D3DFVF_XYZRHW | D3DFVF_TEX1 | D3DFVF_TEXCOORDSIZE4(0))

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D9Shadow";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"FineWine Direct3D 9 shadow", WS_OVERLAPPEDWINDOW, 80, 80, 300, 300, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = pp.BackBufferHeight = 256; pp.hDeviceWindow = window;
    pp.EnableAutoDepthStencil = TRUE; pp.AutoDepthStencilFormat = D3DFMT_D24S8;
    IDirect3DDevice9 *device = NULL;
    if (!d3d || FAILED(IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device))) {
        printf("d3d9-shadow: no device\n"); return 1; }

    D3DFORMAT format = D3DFMT_D24X8;
    if (FAILED(IDirect3D9_CheckDeviceFormat(d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, D3DUSAGE_DEPTHSTENCIL, D3DRTYPE_TEXTURE, format))) format = D3DFMT_D16;
    IDirect3DTexture9 *shadow = NULL; IDirect3DSurface9 *shadow_surface = NULL, *back = NULL, *old_depth = NULL, *colour = NULL, *copy = NULL;
    if (FAILED(IDirect3DDevice9_CreateTexture(device, 256, 256, 1, D3DUSAGE_DEPTHSTENCIL, format, D3DPOOL_DEFAULT, &shadow, NULL))) {
        printf("d3d9-shadow: no depth texture (format %d)\n", (int)format); return 1; }
    IDirect3DTexture9_GetSurfaceLevel(shadow, 0, &shadow_surface);
    IDirect3DDevice9_GetRenderTarget(device, 0, &back);
    IDirect3DDevice9_GetDepthStencilSurface(device, &old_depth);
    IDirect3DDevice9_CreateRenderTarget(device, 256, 256, D3DFMT_X8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE, &colour, NULL);
    IDirect3DDevice9_CreateOffscreenPlainSurface(device, 256, 256, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL);

    /* ps_2_0; dcl t0; dcl_2d s0; texldp r0, t0, s0; mov oC0, r0 */
    static const DWORD code[] = {
        0xffff0200,
        0x0200001f, 0x80000000, 0xb00f0000,
        0x0200001f, 0x90000000, 0xa00f0800,
        0x03010042, 0x800f0000, 0xb0e40000, 0xa0e40800,
        0x02000001, 0x800f0800, 0x80e40000,
        0x0000ffff };
    IDirect3DPixelShader9 *ps = NULL;
    IDirect3DDevice9_CreatePixelShader(device, code, &ps);

    DWORD lit = 0xdeadbeef, dark = 0xdeadbeef;
    for (int frame = 0; frame < 20; frame++) {
        MSG msg; while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        /* the depth texture: everything at 0.5 */
        IDirect3DDevice9_SetRenderTarget(device, 0, colour);
        IDirect3DDevice9_SetDepthStencilSurface(device, shadow_surface);
        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, 0xff000000, 0.5f, 0);
        /* the picture, sampling it */
        IDirect3DDevice9_SetRenderTarget(device, 0, back);
        IDirect3DDevice9_SetDepthStencilSurface(device, old_depth);
        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, 0xff102030, 1.0f, 0);
        if (SUCCEEDED(IDirect3DDevice9_BeginScene(device))) {
            struct vertex quads[2][4] = {
                { { 0, 0, 0.5f, 1, 0, 0, 0.25f, 1 }, { 128, 0, 0.5f, 1, 1, 0, 0.25f, 1 }, { 0, 256, 0.5f, 1, 0, 1, 0.25f, 1 }, { 128, 256, 0.5f, 1, 1, 1, 0.25f, 1 } },
                { { 128, 0, 0.5f, 1, 0, 0, 0.75f, 1 }, { 256, 0, 0.5f, 1, 1, 0, 0.75f, 1 }, { 128, 256, 0.5f, 1, 0, 1, 0.75f, 1 }, { 256, 256, 0.5f, 1, 1, 1, 0.75f, 1 } } };
            IDirect3DDevice9_SetFVF(device, FVF);
            IDirect3DDevice9_SetRenderState(device, D3DRS_ZENABLE, FALSE);
            IDirect3DDevice9_SetTexture(device, 0, (IDirect3DBaseTexture9 *)shadow);
            IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
            IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
            IDirect3DDevice9_SetPixelShader(device, ps);
            IDirect3DDevice9_DrawPrimitiveUP(device, D3DPT_TRIANGLESTRIP, 2, quads[0], sizeof(struct vertex));
            IDirect3DDevice9_DrawPrimitiveUP(device, D3DPT_TRIANGLESTRIP, 2, quads[1], sizeof(struct vertex));
            IDirect3DDevice9_SetPixelShader(device, NULL);
            IDirect3DDevice9_SetTexture(device, 0, NULL);
            IDirect3DDevice9_EndScene(device);
        }
        if (frame == 19 && SUCCEEDED(IDirect3DDevice9_GetRenderTargetData(device, back, copy))) {
            D3DLOCKED_RECT lr;
            if (SUCCEEDED(IDirect3DSurface9_LockRect(copy, &lr, NULL, D3DLOCK_READONLY))) {
                lit = *(DWORD *)((BYTE *)lr.pBits + 128 * lr.Pitch + 64 * 4) & 0xffffff;
                dark = *(DWORD *)((BYTE *)lr.pBits + 128 * lr.Pitch + 192 * 4) & 0xffffff;
                IDirect3DSurface9_UnlockRect(copy);
            }
        }
        if (FAILED(IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL))) { printf("FAIL present\n"); break; }
    }
    printf("in front of the depth: %06lx, behind it: %06lx\n", (unsigned long)lit, (unsigned long)dark);
    if (lit == 0xffffff && dark == 0x000000) { printf("d3d9-shadow: ok\n"); return 0; }
    printf("d3d9-shadow: 1 failure(s)\n");
    return 1;
}
