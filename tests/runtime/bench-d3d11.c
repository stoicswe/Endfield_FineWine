/* bench-d3d11.c: what a Direct3D 11 draw call costs in the FineWine stack.
 *
 * Draws small triangles off screen the way an engine does: for each one, new values in a
 * dynamic constant buffer, then a draw. The GPU work is trivial, so the time is the CPU cost
 * of the path from the game to Metal: the game's own code (translated by FEX when it is x64),
 * the Direct3D layer, and Metal. Prints milliseconds per frame of 10,000 draws.
 * Run by scripts/bench-finewine-runtime.sh. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>

static const char shader[] =
    "cbuffer C : register(b0) { float4 offset; float4 colour; };\n"
    "float4 vs(float2 p : POSITION) : SV_Position { return float4(p * 0.02 + offset.xy, 0.0, 1.0); }\n"
    "float4 ps() : SV_Target { return colour; }\n";

static double now_ms(void) { LARGE_INTEGER c, f; QueryPerformanceCounter(&c); QueryPerformanceFrequency(&f); return 1000.0 * (double)c.QuadPart / (double)f.QuadPart; }
#define CHECK(hr, what) do { if (FAILED(hr)) { printf("bench-d3d11: %s failed 0x%08lx\n", what, (unsigned long)(hr)); return 1; } } while (0)

int main(void)
{
    enum { SIZE = 1024, DRAWS = 10000, FRAMES = 30 };
    static const D3D_FEATURE_LEVEL wanted[] = { D3D_FEATURE_LEVEL_11_0 };
    static const float verts[6] = { -1, -1, 1, -1, 0, 1 }, clear[4] = { 0, 0, 0, 1 };
    ID3D11Device *device; ID3D11DeviceContext *ctx; ID3D11Texture2D *target, *staging; ID3D11RenderTargetView *view;
    ID3DBlob *vsb = NULL, *psb = NULL, *err = NULL; ID3D11VertexShader *vs; ID3D11PixelShader *ps; ID3D11InputLayout *layout;
    ID3D11Buffer *vb, *cb; D3D11_MAPPED_SUBRESOURCE map; HRESULT hr;
    setvbuf(stdout, NULL, _IONBF, 0);

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, wanted, 1, D3D11_SDK_VERSION, &device, NULL, &ctx); CHECK(hr, "D3D11CreateDevice");
    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = td.Height = SIZE; td.MipLevels = td.ArraySize = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    hr = ID3D11Device_CreateTexture2D(device, &td, NULL, &target); CHECK(hr, "CreateTexture2D");
    hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &view); CHECK(hr, "CreateRenderTargetView");
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = ID3D11Device_CreateTexture2D(device, &td, NULL, &staging); CHECK(hr, "CreateTexture2D (staging)");

    hr = D3DCompile(shader, sizeof(shader) - 1, "bench", NULL, NULL, "vs", "vs_4_0", 0, 0, &vsb, &err);
    if (FAILED(hr)) { printf("bench-d3d11: vertex shader: %s\n", err ? (char *)ID3D10Blob_GetBufferPointer(err) : "?"); return 1; }
    hr = D3DCompile(shader, sizeof(shader) - 1, "bench", NULL, NULL, "ps", "ps_4_0", 0, 0, &psb, &err);
    if (FAILED(hr)) { printf("bench-d3d11: pixel shader: %s\n", err ? (char *)ID3D10Blob_GetBufferPointer(err) : "?"); return 1; }
    hr = ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), NULL, &vs); CHECK(hr, "CreateVertexShader");
    hr = ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(psb), ID3D10Blob_GetBufferSize(psb), NULL, &ps); CHECK(hr, "CreatePixelShader");
    D3D11_INPUT_ELEMENT_DESC il = { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 };
    hr = ID3D11Device_CreateInputLayout(device, &il, 1, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), &layout); CHECK(hr, "CreateInputLayout");
    D3D11_BUFFER_DESC bd = { sizeof(verts), D3D11_USAGE_IMMUTABLE, D3D11_BIND_VERTEX_BUFFER }; D3D11_SUBRESOURCE_DATA init = { verts };
    hr = ID3D11Device_CreateBuffer(device, &bd, &init, &vb); CHECK(hr, "CreateBuffer (vertices)");
    D3D11_BUFFER_DESC cd = { 32, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE };
    hr = ID3D11Device_CreateBuffer(device, &cd, NULL, &cb); CHECK(hr, "CreateBuffer (constants)");

    D3D11_RASTERIZER_DESC rsd = { D3D11_FILL_SOLID, D3D11_CULL_NONE }; rsd.DepthClipEnable = TRUE; ID3D11RasterizerState *rs;
    hr = ID3D11Device_CreateRasterizerState(device, &rsd, &rs); CHECK(hr, "CreateRasterizerState");
    D3D11_VIEWPORT vp = { 0, 0, SIZE, SIZE, 0, 1 }; UINT stride = 8, offset = 0;
    double total[2] = { 0, 0 }, worst[2] = { 0, 0 };
    for (int mode = 0; mode < 2; mode++) {            /* 0: constants change every draw; 1: draws only */
        for (int f = 0; f < FRAMES + 5; f++) {
            double t0 = now_ms();
            ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &view, NULL);
            ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
            ID3D11DeviceContext_RSSetState(ctx, rs);
            ID3D11DeviceContext_ClearRenderTargetView(ctx, view, clear);
            ID3D11DeviceContext_IASetInputLayout(ctx, layout);
            ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb, &stride, &offset);
            ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0); ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
            ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &cb); ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &cb);
            for (int d = 0; d < DRAWS; d++) {
                if (mode == 0 || d == 0) {
                    hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &map); CHECK(hr, "Map (constants)");
                    float v[8] = { (d % 100) * 0.02f - 0.99f, (d / 100) * 0.02f - 0.99f, 0, 0, 1.0f, (d % 7) / 7.0f, (f % 5) / 5.0f, 1.0f };
                    memcpy(map.pData, v, sizeof(v));
                    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)cb, 0);
                }
                ID3D11DeviceContext_Draw(ctx, 3, 0);
            }
            /* The frame is over when the GPU has it: read one pixel back. */
            D3D11_BOX box = { SIZE / 2, SIZE / 2, 0, SIZE / 2 + 1, SIZE / 2 + 1, 1 };
            ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource *)staging, 0, 0, 0, 0, (ID3D11Resource *)target, 0, &box);
            hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map); CHECK(hr, "Map (read back)");
            unsigned char red = *(unsigned char *)map.pData;
            ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
            if (mode == 0 && !red) { printf("bench-d3d11: nothing was drawn\n"); return 1; }
            double ms = now_ms() - t0;
            if (f >= 5) { total[mode] += ms; if (ms > worst[mode]) worst[mode] = ms; }     /* the first frames warm up */
        }
    }
    printf("%-34s %9.2f ms per frame (worst %.2f), %.0f draws per ms\n", "D3D11 10k draws, new constants", total[0] / FRAMES, worst[0], DRAWS / (total[0] / FRAMES));
    printf("%-34s %9.2f ms per frame (worst %.2f), %.0f draws per ms\n", "D3D11 10k draws, nothing changes", total[1] / FRAMES, worst[1], DRAWS / (total[1] / FRAMES));
    return 0;
}
