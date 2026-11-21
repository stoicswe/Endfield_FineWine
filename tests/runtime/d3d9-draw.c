/* d3d9-draw.c: Direct3D 9 drawing, through WineD3D: a vertex buffer and an index buffer, a
 * texture filled through LockRect, a draw from the program's own memory (DrawPrimitiveUP), a
 * read-back of what was drawn, and presenting into a window (a small one appears for a
 * moment). Built for x64 and for 32-bit x86: in a 32-bit program every one of these passes
 * pointers, or offsets that look like pointers, through Wine's 32-bit call layer.
 * Prints "d3d9-draw: ok" on success. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <string.h>

struct vertex { float x, y, z, rhw; DWORD color; float u, v; };
#define FVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_TEX1)

static int failures;
static void check(int ok, const char *what) { if (!ok) { failures++; printf("FAIL %s\n", what); } }

static DWORD pixel(IDirect3DDevice9 *device, IDirect3DSurface9 *target, IDirect3DSurface9 *copy, int x, int y)
{
    D3DLOCKED_RECT lr; DWORD value = 0xdeadbeef;
    if (FAILED(IDirect3DDevice9_GetRenderTargetData(device, target, copy))) return value;
    if (SUCCEEDED(IDirect3DSurface9_LockRect(copy, &lr, NULL, D3DLOCK_READONLY))) {
        value = *(DWORD *)((BYTE *)lr.pBits + y * lr.Pitch + x * 4) & 0x00ffffff;
        IDirect3DSurface9_UnlockRect(copy);
    }
    return value;
}

static int close_to(DWORD a, DWORD b)
{
    for (int s = 0; s < 24; s += 8) { int d = (int)((a >> s) & 0xff) - (int)((b >> s) & 0xff); if (d < -6 || d > 6) return 0; }
    return 1;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("d3d9-draw: Direct3DCreate9 failed\n"); return 1; }

    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D9Draw";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"FineWine Direct3D 9 check", WS_OVERLAPPEDWINDOW, 80, 80, 300, 300, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(window, SW_SHOWNOACTIVATE);

    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = pp.BackBufferHeight = 256; pp.hDeviceWindow = window;
    pp.EnableAutoDepthStencil = TRUE; pp.AutoDepthStencilFormat = D3DFMT_D24S8;
    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr)) { printf("d3d9-draw: CreateDevice failed 0x%08lx\n", (unsigned long)hr); return 1; }

    /* Big buffers, so that the quad's vertices and its indices sit at offsets above 64 KB:
     * in a 32-bit program an offset that large looks like an address. */
    enum { FILLER = 4096 };
    IDirect3DVertexBuffer9 *vb = NULL; IDirect3DIndexBuffer9 *ib = NULL; IDirect3DTexture9 *tex = NULL;
    check(SUCCEEDED(IDirect3DDevice9_CreateVertexBuffer(device, (FILLER + 4) * sizeof(struct vertex), D3DUSAGE_WRITEONLY, FVF, D3DPOOL_DEFAULT, &vb, NULL)), "create vertex buffer");
    check(SUCCEEDED(IDirect3DDevice9_CreateIndexBuffer(device, (FILLER * 6 + 6) * sizeof(WORD) * 2, D3DUSAGE_WRITEONLY, D3DFMT_INDEX32, D3DPOOL_DEFAULT, &ib, NULL)), "create index buffer");
    check(SUCCEEDED(IDirect3DDevice9_CreateTexture(device, 64, 64, 1, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &tex, NULL)), "create texture");
    if (failures) { printf("d3d9-draw: %d failure(s)\n", failures); return 1; }

    void *data = NULL;
    check(SUCCEEDED(IDirect3DVertexBuffer9_Lock(vb, 0, 0, &data, 0)) && data, "lock vertex buffer");
    if (data) {
        struct vertex *v = (struct vertex *)data + FILLER;
        memset(data, 0, FILLER * sizeof(struct vertex));
        /* left half of the target, white, textured */
        v[0] = (struct vertex){   0,   0, 0.5f, 1, 0xffffffff, 0, 0 };
        v[1] = (struct vertex){ 128,   0, 0.5f, 1, 0xffffffff, 1, 0 };
        v[2] = (struct vertex){   0, 256, 0.5f, 1, 0xffffffff, 0, 1 };
        v[3] = (struct vertex){ 128, 256, 0.5f, 1, 0xffffffff, 1, 1 };
        IDirect3DVertexBuffer9_Unlock(vb);
    }
    data = NULL;
    check(SUCCEEDED(IDirect3DIndexBuffer9_Lock(ib, 0, 0, &data, 0)) && data, "lock index buffer");
    if (data) {
        DWORD *i = (DWORD *)data + FILLER * 5;      /* 80 KB into the buffer */
        memset(data, 0, FILLER * 5 * sizeof(DWORD));
        i[0] = 0; i[1] = 1; i[2] = 2; i[3] = 2; i[4] = 1; i[5] = 3;
        IDirect3DIndexBuffer9_Unlock(ib);
    }
    D3DLOCKED_RECT lr;
    check(SUCCEEDED(IDirect3DTexture9_LockRect(tex, 0, &lr, NULL, 0)), "lock texture");
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++)
        *(DWORD *)((BYTE *)lr.pBits + y * lr.Pitch + x * 4) = y < 32 ? 0xff2060c0 : 0xffc06020;   /* blue-ish over orange-ish */
    IDirect3DTexture9_UnlockRect(tex, 0);

    IDirect3DSurface9 *target = NULL, *copy = NULL;
    IDirect3DDevice9_GetRenderTarget(device, 0, &target);
    check(SUCCEEDED(IDirect3DDevice9_CreateOffscreenPlainSurface(device, 256, 256, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL)), "create read-back surface");

    DWORD top = 0, bottom = 0, right = 0, clear = 0;
    for (int frame = 0; frame < 30; frame++) {
        MSG msg; while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, 0xff102030, 1.0f, 0);
        check(SUCCEEDED(IDirect3DDevice9_BeginScene(device)), "begin scene");
        IDirect3DDevice9_SetRenderState(device, D3DRS_LIGHTING, FALSE);
        IDirect3DDevice9_SetRenderState(device, D3DRS_CULLMODE, D3DCULL_NONE);
        IDirect3DDevice9_SetFVF(device, FVF);
        /* the quad from the buffers */
        IDirect3DDevice9_SetTexture(device, 0, (IDirect3DBaseTexture9 *)tex);
        IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
        IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
        IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
        IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
        IDirect3DDevice9_SetStreamSource(device, 0, vb, FILLER * sizeof(struct vertex), sizeof(struct vertex));
        IDirect3DDevice9_SetIndices(device, ib);
        check(SUCCEEDED(IDirect3DDevice9_DrawIndexedPrimitive(device, D3DPT_TRIANGLELIST, 0, 0, 4, FILLER * 5, 2)), "draw from buffers");
        /* a green triangle strip from the program's own memory, lower right quarter */
        struct vertex up[4] = {
            { 128, 128, 0.5f, 1, 0xff00ff00, 0, 0 }, { 256, 128, 0.5f, 1, 0xff00ff00, 0, 0 },
            { 128, 256, 0.5f, 1, 0xff00ff00, 0, 0 }, { 256, 256, 0.5f, 1, 0xff00ff00, 0, 0 } };
        IDirect3DDevice9_SetTexture(device, 0, NULL);
        IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG1, D3DTA_DIFFUSE);
        check(SUCCEEDED(IDirect3DDevice9_DrawPrimitiveUP(device, D3DPT_TRIANGLESTRIP, 2, up, sizeof(up[0]))), "draw from memory");
        IDirect3DDevice9_EndScene(device);
        if (frame == 29) {
            top = pixel(device, target, copy, 64, 60); bottom = pixel(device, target, copy, 64, 200);
            right = pixel(device, target, copy, 200, 200); clear = pixel(device, target, copy, 200, 60);
        }
        check(SUCCEEDED(IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL)), "present");
    }
    check(close_to(top, 0x2060c0), "textured quad, top half of the texture");
    check(close_to(bottom, 0xc06020), "textured quad, bottom half of the texture");
    check(close_to(right, 0x00ff00), "triangle strip drawn from memory");
    check(close_to(clear, 0x102030), "cleared area");
    if (failures) printf("pixels: %06lx %06lx %06lx %06lx\n", (unsigned long)top, (unsigned long)bottom, (unsigned long)right, (unsigned long)clear);

    IDirect3DSurface9_Release(copy); IDirect3DSurface9_Release(target);
    IDirect3DTexture9_Release(tex); IDirect3DIndexBuffer9_Release(ib); IDirect3DVertexBuffer9_Release(vb);
    IDirect3DDevice9_Release(device); IDirect3D9_Release(d3d);
    DestroyWindow(window);
    if (failures) { printf("d3d9-draw: %d failure(s)\n", failures); return 1; }
    printf("d3d9-draw: ok\n");
    return 0;
}
