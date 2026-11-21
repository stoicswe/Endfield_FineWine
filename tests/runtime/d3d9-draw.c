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

static IDirect3DSurface9 *resolved;

static DWORD pixel(IDirect3DDevice9 *device, IDirect3DSurface9 *target, IDirect3DSurface9 *copy, int x, int y)
{
    D3DLOCKED_RECT lr; DWORD value = 0xdeadbeef;
    /* a multisampled target cannot be read back; its samples are resolved into a plain one first */
    if (resolved) {
        if (FAILED(IDirect3DDevice9_StretchRect(device, target, NULL, resolved, NULL, D3DTEXF_NONE))) return value;
        target = resolved;
    }
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

int main(int argc, char **argv)
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
    /* "msaa": a multisampled back buffer, which is what a game with antialiasing on presents. */
    if (argc > 1 && !strcmp(argv[1], "msaa")) pp.MultiSampleType = D3DMULTISAMPLE_4_SAMPLES;
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
    if (pp.MultiSampleType != D3DMULTISAMPLE_NONE)
        check(SUCCEEDED(IDirect3DDevice9_CreateRenderTarget(device, 256, 256, D3DFMT_X8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE, &resolved, NULL)), "create resolve target");
    check(SUCCEEDED(IDirect3DDevice9_CreateOffscreenPlainSurface(device, 256, 256, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL)), "create read-back surface");

    /* A vertex shader fed whole numbers: UBYTE4 and SHORT4 elements, which a Direct3D 9 shader
     * reads as floats (64 arrives as 64.0). Skinned models carry their bone indices this way.
     *   vs_1_1; dcl_position v0; dcl_texcoord0 v1; dcl_texcoord1 v2
     *   mov oPos, v0; mul r0, v1, c0; mad oD0, v2, c0, r0 */
    static const DWORD shader_code[] = {
        0xfffe0101,
        0x0000001f, 0x80000000, 0x900f0000,
        0x0000001f, 0x80000005, 0x900f0001,
        0x0000001f, 0x80010005, 0x900f0002,
        0x00000001, 0xc00f0000, 0x90e40000,
        0x00000005, 0x800f0000, 0x90e40001, 0xa0e40000,
        0x00000004, 0xd00f0000, 0x90e40002, 0xa0e40000, 0x80e40000,
        0x0000ffff };
    static const D3DVERTEXELEMENT9 int_elements[] = {
        { 0, 0, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0 },
        { 0, 12, D3DDECLTYPE_UBYTE4, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0 },
        { 0, 16, D3DDECLTYPE_SHORT4, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 1 },
        D3DDECL_END() };
    struct int_vertex { float x, y, z; BYTE b[4]; short s[4]; };
    /* pixels 136..184 by 8..40; colour (64 + 51, 128, 255) / 255 */
    static const struct int_vertex int_quad[4] = {
        { 0.0625f, 0.9375f, 0.5f, { 64, 128, 255, 255 }, { 51, 0, 0, 0 } }, { 0.4375f, 0.9375f, 0.5f, { 64, 128, 255, 255 }, { 51, 0, 0, 0 } },
        { 0.0625f, 0.6875f, 0.5f, { 64, 128, 255, 255 }, { 51, 0, 0, 0 } }, { 0.4375f, 0.6875f, 0.5f, { 64, 128, 255, 255 }, { 51, 0, 0, 0 } } };
    static const float per_255[4] = { 1.0f / 255, 1.0f / 255, 1.0f / 255, 1.0f / 255 };
    /* A pixel shader that samples a texture, which is what nearly every draw of a game is:
     *   ps_2_0; dcl t0.xy; dcl_2d s0; texld r0, t0, s0; mov oC0, r0 */
    static const DWORD pixel_shader_code[] = {
        0xffff0200,
        0x0200001f, 0x80000000, 0xb0030000,
        0x0200001f, 0x90000000, 0xa00f0800,
        0x03000042, 0x800f0000, 0xb0e40000, 0xa0e40800,
        0x02000001, 0x800f0800, 0x80e40000,
        0x0000ffff };
    IDirect3DPixelShader9 *pixel_shader = NULL;
    check(SUCCEEDED(IDirect3DDevice9_CreatePixelShader(device, pixel_shader_code, &pixel_shader)), "create pixel shader");
    IDirect3DVertexShader9 *shader = NULL; IDirect3DVertexDeclaration9 *int_decl = NULL;
    check(SUCCEEDED(IDirect3DDevice9_CreateVertexShader(device, shader_code, &shader)), "create vertex shader");
    check(SUCCEEDED(IDirect3DDevice9_CreateVertexDeclaration(device, int_elements, &int_decl)), "create vertex declaration");

    DWORD top = 0, bottom = 0, right = 0, clear = 0, ints = 0;
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
        IDirect3DDevice9_SetPixelShader(device, pixel_shader);
        /* with the alpha test, which a pixel shader gets from Direct3D's render states and
         * games use for anything with holes in it (the texture is opaque: nothing is cut) */
        IDirect3DDevice9_SetRenderState(device, D3DRS_ALPHATESTENABLE, TRUE);
        IDirect3DDevice9_SetRenderState(device, D3DRS_ALPHAREF, 0x40);
        IDirect3DDevice9_SetRenderState(device, D3DRS_ALPHAFUNC, D3DCMP_GREATEREQUAL);
        check(SUCCEEDED(IDirect3DDevice9_DrawIndexedPrimitive(device, D3DPT_TRIANGLELIST, 0, 0, 4, FILLER * 5, 2)), "draw from buffers");
        IDirect3DDevice9_SetRenderState(device, D3DRS_ALPHATESTENABLE, FALSE);
        IDirect3DDevice9_SetPixelShader(device, NULL);
        /* a green triangle strip from the program's own memory, lower right quarter */
        struct vertex up[4] = {
            { 128, 128, 0.5f, 1, 0xff00ff00, 0, 0 }, { 256, 128, 0.5f, 1, 0xff00ff00, 0, 0 },
            { 128, 256, 0.5f, 1, 0xff00ff00, 0, 0 }, { 256, 256, 0.5f, 1, 0xff00ff00, 0, 0 } };
        IDirect3DDevice9_SetTexture(device, 0, NULL);
        IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG1, D3DTA_DIFFUSE);
        check(SUCCEEDED(IDirect3DDevice9_DrawPrimitiveUP(device, D3DPT_TRIANGLESTRIP, 2, up, sizeof(up[0]))), "draw from memory");
        if (shader && int_decl) {
            IDirect3DDevice9_SetVertexDeclaration(device, int_decl);
            IDirect3DDevice9_SetVertexShader(device, shader);
            IDirect3DDevice9_SetVertexShaderConstantF(device, 0, per_255, 1);
            IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG1, D3DTA_DIFFUSE);
            check(SUCCEEDED(IDirect3DDevice9_DrawPrimitiveUP(device, D3DPT_TRIANGLESTRIP, 2, int_quad, sizeof(int_quad[0]))), "draw with whole-number vertex elements");
            IDirect3DDevice9_SetVertexShader(device, NULL);
        }
        IDirect3DDevice9_EndScene(device);
        if (frame == 29) {
            ints = pixel(device, target, copy, 160, 24);
            top = pixel(device, target, copy, 64, 60); bottom = pixel(device, target, copy, 64, 200);
            right = pixel(device, target, copy, 200, 200); clear = pixel(device, target, copy, 200, 60);
        }
        check(SUCCEEDED(IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL)), "present");
    }
    check(close_to(top, 0x2060c0), "textured quad, top half of the texture");
    check(close_to(bottom, 0xc06020), "textured quad, bottom half of the texture");
    check(close_to(right, 0x00ff00), "triangle strip drawn from memory");
    check(close_to(clear, 0x102030), "cleared area");
    check(close_to(ints, 0x7380ff), "vertex shader with UBYTE4 and SHORT4 elements");
    if (failures) printf("pixels: %06lx %06lx %06lx %06lx %06lx\n", (unsigned long)top, (unsigned long)bottom, (unsigned long)right, (unsigned long)clear, (unsigned long)ints);
    if (pixel_shader) IDirect3DPixelShader9_Release(pixel_shader);
    if (shader) IDirect3DVertexShader9_Release(shader);
    if (int_decl) IDirect3DVertexDeclaration9_Release(int_decl);

    IDirect3DSurface9_Release(copy); IDirect3DSurface9_Release(target);
    IDirect3DTexture9_Release(tex); IDirect3DIndexBuffer9_Release(ib); IDirect3DVertexBuffer9_Release(vb);
    IDirect3DDevice9_Release(device); IDirect3D9_Release(d3d);
    DestroyWindow(window);
    if (failures) { printf("d3d9-draw: %d failure(s)\n", failures); return 1; }
    printf("d3d9-draw: ok\n");
    return 0;
}
