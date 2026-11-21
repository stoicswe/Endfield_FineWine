/* Direct3D 9 texture formats: for each format and way of filling a texture, draws it and prints
 * what reaches the render target. The output of two renderers (WineD3D on OpenGL and on Vulkan)
 * is compared line by line: a format one of them gets wrong shows as a differing line.
 *
 * Build: i686-w64-mingw32-clang -O1 -o d3d9-formats.exe d3d9-formats.c -ld3d9
 * Prints one line per case and "d3d9-formats: done". */
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <string.h>

struct vertex { float x, y, z, rhw; float u, v; };
#define FVF (D3DFVF_XYZRHW | D3DFVF_TEX1)

static const struct { D3DFORMAT format; const char *name; int bytes; int block; } formats[] = {
    { D3DFMT_A8R8G8B8, "A8R8G8B8", 4, 0 }, { D3DFMT_X8R8G8B8, "X8R8G8B8", 4, 0 },
    { D3DFMT_R5G6B5, "R5G6B5", 2, 0 }, { D3DFMT_A1R5G5B5, "A1R5G5B5", 2, 0 }, { D3DFMT_X1R5G5B5, "X1R5G5B5", 2, 0 },
    { D3DFMT_A4R4G4B4, "A4R4G4B4", 2, 0 }, { D3DFMT_R8G8B8, "R8G8B8", 3, 0 },
    { D3DFMT_L8, "L8", 1, 0 }, { D3DFMT_A8L8, "A8L8", 2, 0 }, { D3DFMT_A8, "A8", 1, 0 }, { D3DFMT_L16, "L16", 2, 0 },
    { D3DFMT_V8U8, "V8U8", 2, 0 }, { D3DFMT_A8B8G8R8, "A8B8G8R8", 4, 0 }, { D3DFMT_A2R10G10B10, "A2R10G10B10", 4, 0 },
    { D3DFMT_DXT1, "DXT1", 8, 1 }, { D3DFMT_DXT3, "DXT3", 16, 2 }, { D3DFMT_DXT5, "DXT5", 16, 2 },
    { D3DFMT_YUY2, "YUY2", 2, 0 }, { D3DFMT_UYVY, "UYVY", 2, 0 },
    { MAKEFOURCC('A','T','I','2'), "ATI2", 16, 4 }, { MAKEFOURCC('A','T','I','1'), "ATI1", 8, 3 },
    { D3DFMT_A16B16G16R16F, "RGBA16F", 8, 0 }, { D3DFMT_A16B16G16R16, "RGBA16", 8, 0 }, { D3DFMT_A32B32G32R32F, "RGBA32F", 16, 0 },
    { D3DFMT_R32F, "R32F", 4, 0 }, { D3DFMT_G16R16F, "G16R16F", 4, 0 }, { D3DFMT_G16R16, "G16R16", 4, 0 }, { D3DFMT_R16F, "R16F", 2, 0 },
    { D3DFMT_Q8W8V8U8, "Q8W8V8U8", 4, 0 }, { D3DFMT_X8B8G8R8, "X8B8G8R8", 4, 0 }, { D3DFMT_A4L4, "A4L4", 1, 0 },
    { D3DFMT_X4R4G4B4, "X4R4G4B4", 2, 0 }, { D3DFMT_L6V5U5, "L6V5U5", 2, 0 }, { D3DFMT_X8L8V8U8, "X8L8V8U8", 4, 0 },
};

/* The bytes of one texel, or of one block of a compressed format, for value q (0..3). Texels
 * differ in every byte so that a wrong pitch, size or byte order shows; blocks are one flat
 * colour each, so that where in the block a pixel is sampled does not matter. */
static const BYTE *texel(int q, int block)
{
    static const BYTE seed[4][16] = {
        { 0x10, 0x80, 0xf0, 0xff, 0x24, 0x48, 0x92, 0xa5, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
        { 0xe0, 0x07, 0x1f, 0xf8, 0xaa, 0xaa, 0x55, 0x55, 0xff, 0x00, 0xff, 0x00, 0x0f, 0xf0, 0x0f, 0xf0 },
        { 0x7f, 0x3f, 0xbf, 0x80, 0x00, 0xff, 0x00, 0xff, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 },
        { 0xff, 0xff, 0x00, 0x00, 0x1b, 0x1b, 0x1b, 0x1b, 0xc0, 0x30, 0x0c, 0x03, 0xc0, 0x30, 0x0c, 0x03 } };
    static const BYTE colour[4][2] = { { 0x00, 0xf8 }, { 0xe0, 0x07 }, { 0x1f, 0x00 }, { 0xff, 0xff } };
    static const BYTE level[4] = { 0x20, 0x60, 0xa0, 0xe0 };
    static BYTE out[16];
    if (!block) return seed[q];
    memset(out, 0, sizeof(out));
    if (block == 1) { memcpy(out, colour[q], 2); memcpy(out + 2, colour[q], 2); }
    else if (block == 2) { memset(out, 0xff, 8); memcpy(out + 8, colour[q], 2); memcpy(out + 10, colour[q], 2); }
    else { out[0] = out[1] = level[q]; if (block == 4) out[8] = out[9] = level[3 - q]; }
    return out;
}

/* One texel (or block) value per call: the whole of a locked area gets seed q. */
static void fill_one(BYTE *bits, int pitch, int w, int h, int bytes, int q, int block)
{
    const BYTE *value = texel(q, block);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) memcpy(bits + y * pitch + x * bytes, value, bytes);
}

/* Value q in quadrant q. */
static void fill(BYTE *bits, int pitch, int size, int bytes, int block)
{
    int cells = block ? (size + 3) / 4 : size;
    if (cells < 2) { memcpy(bits, texel(0, block), bytes); return; }
    for (int y = 0; y < cells; y++) for (int x = 0; x < cells; x++) {
        int q = (y >= cells / 2) * 2 + (x >= cells / 2);
        memcpy(bits + y * pitch + x * bytes, texel(q, block), bytes);
    }
}

static IDirect3DDevice9 *device;
static DWORD mip_filter = D3DTEXF_NONE;
static float quad_size = 128;
static IDirect3DSurface9 *target, *copy;

static void draw_and_print(IDirect3DBaseTexture9 *tex, const char *name, const char *how)
{
    float e = quad_size;
    struct vertex quad[4] = { { 0, 0, 0.5f, 1, 0, 0 }, { e, 0, 0.5f, 1, 1, 0 }, { 0, e, 0.5f, 1, 0, 1 }, { e, e, 0.5f, 1, 1, 1 } };
    DWORD px[4] = { 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef };
    D3DLOCKED_RECT lr;
    for (int i = 0; i < 4; i++) { quad[i].x -= 0.5f; quad[i].y -= 0.5f; }
    IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, 0xff203040, 1.0f, 0);
    IDirect3DDevice9_BeginScene(device);
    IDirect3DDevice9_SetFVF(device, FVF);
    IDirect3DDevice9_SetTexture(device, 0, tex);
    IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
    IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MIPFILTER, mip_filter);
    IDirect3DDevice9_SetRenderState(device, D3DRS_LIGHTING, FALSE);
    IDirect3DDevice9_SetRenderState(device, D3DRS_ALPHABLENDENABLE, FALSE);
    IDirect3DDevice9_DrawPrimitiveUP(device, D3DPT_TRIANGLESTRIP, 2, quad, sizeof(quad[0]));
    IDirect3DDevice9_EndScene(device);
    if (SUCCEEDED(IDirect3DDevice9_GetRenderTargetData(device, target, copy))
        && SUCCEEDED(IDirect3DSurface9_LockRect(copy, &lr, NULL, D3DLOCK_READONLY))) {
        static const int at[4][2] = { { 32, 30 }, { 96, 30 }, { 34, 94 }, { 98, 96 } };
        for (int i = 0; i < 4; i++) {
            int x = (int)(at[i][0] * quad_size / 128), y = (int)(at[i][1] * quad_size / 128);
            px[i] = *(DWORD *)((BYTE *)lr.pBits + y * lr.Pitch + x * 4) & 0xffffff;
        }
        IDirect3DSurface9_UnlockRect(copy);
    }
    IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
    printf("%-12s %-10s %06lx %06lx %06lx %06lx\n", name, how, (unsigned long)px[0], (unsigned long)px[1], (unsigned long)px[2], (unsigned long)px[3]);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D9Formats";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"FineWine Direct3D 9 formats", WS_OVERLAPPEDWINDOW, 80, 80, 200, 200, NULL, NULL, wc.hInstance, NULL);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = pp.BackBufferHeight = 128; pp.hDeviceWindow = window;
    if (!d3d || FAILED(IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device))) {
        printf("d3d9-formats: no device\n"); return 1; }
    IDirect3DDevice9_GetRenderTarget(device, 0, &target);
    IDirect3DDevice9_CreateOffscreenPlainSurface(device, 128, 128, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL);

    for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        D3DFORMAT f = formats[i].format; D3DLOCKED_RECT lr;
        static const struct { DWORD usage; D3DPOOL pool; int size; int levels; const char *how; } ways[] = {
            { 0, D3DPOOL_MANAGED, 64, 1, "managed" }, { D3DUSAGE_DYNAMIC, D3DPOOL_DEFAULT, 64, 1, "dynamic" },
            { 0, D3DPOOL_MANAGED, 256, 0, "mipped" }, { 0, D3DPOOL_MANAGED, 1024, 1, "large" } };
        if (FAILED(IDirect3D9_CheckDeviceFormat(d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, 0, D3DRTYPE_TEXTURE, f))) {
            printf("%-12s unsupported\n", formats[i].name); continue; }
        for (unsigned w = 0; w < sizeof(ways) / sizeof(ways[0]); w++) {
            IDirect3DTexture9 *tex = NULL;
            if (FAILED(IDirect3DDevice9_CreateTexture(device, ways[w].size, ways[w].size, ways[w].levels, ways[w].usage, f, ways[w].pool, &tex, NULL))) {
                printf("%-12s %-10s create failed\n", formats[i].name, ways[w].how); continue; }
            DWORD levels = IDirect3DTexture9_GetLevelCount(tex);
            for (DWORD l = 0; l < levels; l++) {
                int size = ways[w].size >> l; if (size < 1) size = 1;
                if (SUCCEEDED(IDirect3DTexture9_LockRect(tex, l, &lr, NULL, 0))) {
                    fill(lr.pBits, lr.Pitch, size, formats[i].bytes, formats[i].block);
                    IDirect3DTexture9_UnlockRect(tex, l);
                }
            }
            draw_and_print((IDirect3DBaseTexture9 *)tex, formats[i].name, ways[w].how);
            /* filled a second time, as a video or an animated texture is every frame */
            if (ways[w].usage & D3DUSAGE_DYNAMIC) {
                if (SUCCEEDED(IDirect3DTexture9_LockRect(tex, 0, &lr, NULL, D3DLOCK_DISCARD))) {
                    fill(lr.pBits, lr.Pitch, 64, formats[i].bytes, formats[i].block);
                    IDirect3DTexture9_UnlockRect(tex, 0);
                }
                draw_and_print((IDirect3DBaseTexture9 *)tex, formats[i].name, "refilled");
            }
            if (w == 0 && !(f == MAKEFOURCC('A','T','I','1') || f == MAKEFOURCC('A','T','I','2'))) {
                /* Filled a part at a time, as a lightmap page is: each quarter through its own
                 * locked rectangle, in a 256 texture so that the rectangles sit at offsets. */
                IDirect3DTexture9 *part = NULL; int cell = formats[i].block ? 4 : 1;
                for (int dyn = 0; dyn < 2; dyn++) {
                    if (SUCCEEDED(IDirect3DDevice9_CreateTexture(device, 256, 256, 1, dyn ? D3DUSAGE_DYNAMIC : 0, f, dyn ? D3DPOOL_DEFAULT : D3DPOOL_MANAGED, &part, NULL))) {
                        for (int q = 0; q < 4; q++) {
                            RECT r = { (q & 1) * 128, (q >> 1) * 128, (q & 1) * 128 + 128, (q >> 1) * 128 + 128 };
                            if (SUCCEEDED(IDirect3DTexture9_LockRect(part, 0, &lr, &r, 0))) {
                                fill_one(lr.pBits, lr.Pitch, 128 / cell, 128 / cell, formats[i].bytes, 3 - q, formats[i].block);
                                IDirect3DTexture9_UnlockRect(part, 0);
                            }
                        }
                        draw_and_print((IDirect3DBaseTexture9 *)part, formats[i].name, dyn ? "parts-dyn" : "parts");
                        /* and one quarter again after it was drawn */
                        RECT r = { 128, 0, 256, 128 };
                        if (SUCCEEDED(IDirect3DTexture9_LockRect(part, 0, &lr, &r, 0))) {
                            fill_one(lr.pBits, lr.Pitch, 128 / cell, 128 / cell, formats[i].bytes, 0, formats[i].block);
                            IDirect3DTexture9_UnlockRect(part, 0);
                        }
                        draw_and_print((IDirect3DBaseTexture9 *)part, formats[i].name, dyn ? "repart-dyn" : "repart");
                        IDirect3DTexture9_Release(part); part = NULL;
                    }
                }
                /* Every mip level its own value, drawn at each level in turn. */
                IDirect3DTexture9 *mips = NULL;
                if (SUCCEEDED(IDirect3DDevice9_CreateTexture(device, 64, 64, 4, 0, f, D3DPOOL_MANAGED, &mips, NULL))) {
                    for (int l = 0; l < 4; l++) if (SUCCEEDED(IDirect3DTexture9_LockRect(mips, l, &lr, NULL, 0))) {
                        fill_one(lr.pBits, lr.Pitch, (64 >> l) / cell, (64 >> l) / cell, formats[i].bytes, l, formats[i].block);
                        IDirect3DTexture9_UnlockRect(mips, l);
                    }
                    for (int l = 0; l < 4; l++) {
                        /* drawn at the size of the level, which is how a game gets one */
                        char how[16]; sprintf(how, "level%d", l);
                        mip_filter = D3DTEXF_POINT; quad_size = 64 >> l;
                        draw_and_print((IDirect3DBaseTexture9 *)mips, formats[i].name, how);
                        quad_size = 128;
                        /* and picked by the sampler's largest level */
                        if (l) {
                            sprintf(how, "maxlevel%d", l);
                            IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAXMIPLEVEL, l);
                            draw_and_print((IDirect3DBaseTexture9 *)mips, formats[i].name, how);
                            IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAXMIPLEVEL, 0);
                        }
                        mip_filter = D3DTEXF_NONE;
                    }
                    IDirect3DTexture9_Release(mips);
                }
            }
            /* Gamma: read as sRGB, written as sRGB, and both, which is how games draw colour
             * textures (read) into the picture (write). */
            if (w == 0 && SUCCEEDED(IDirect3D9_CheckDeviceFormat(d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, D3DUSAGE_QUERY_SRGBREAD, D3DRTYPE_TEXTURE, f))) {
                static const struct { DWORD read, write; const char *how; } gamma[] = { { 1, 0, "srgb-read" }, { 0, 1, "srgb-write" }, { 1, 1, "srgb-both" } };
                for (unsigned g = 0; g < 3; g++) {
                    IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_SRGBTEXTURE, gamma[g].read);
                    IDirect3DDevice9_SetRenderState(device, D3DRS_SRGBWRITEENABLE, gamma[g].write);
                    draw_and_print((IDirect3DBaseTexture9 *)tex, formats[i].name, gamma[g].how);
                }
                IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_SRGBTEXTURE, 0);
                IDirect3DDevice9_SetRenderState(device, D3DRS_SRGBWRITEENABLE, 0);
            }
            /* a system-memory texture copied in, the other way games upload */
            if (w == 0) {
                IDirect3DTexture9 *sys = NULL, *dst = NULL;
                if (SUCCEEDED(IDirect3DDevice9_CreateTexture(device, 64, 64, 1, 0, f, D3DPOOL_SYSTEMMEM, &sys, NULL))
                    && SUCCEEDED(IDirect3DDevice9_CreateTexture(device, 64, 64, 1, 0, f, D3DPOOL_DEFAULT, &dst, NULL))
                    && SUCCEEDED(IDirect3DTexture9_LockRect(sys, 0, &lr, NULL, 0))) {
                    fill(lr.pBits, lr.Pitch, 64, formats[i].bytes, formats[i].block);
                    IDirect3DTexture9_UnlockRect(sys, 0);
                    IDirect3DDevice9_UpdateTexture(device, (IDirect3DBaseTexture9 *)sys, (IDirect3DBaseTexture9 *)dst);
                    draw_and_print((IDirect3DBaseTexture9 *)dst, formats[i].name, "updated");
                }
                if (sys) IDirect3DTexture9_Release(sys);
                if (dst) IDirect3DTexture9_Release(dst);
            }
            IDirect3DTexture9_Release(tex);
        }
    }
    printf("d3d9-formats: done\n");
    return 0;
}
