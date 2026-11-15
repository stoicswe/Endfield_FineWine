/* d3d11-clear.c: creates a Direct3D 11 device, clears an off-screen render target to a known
 * colour and reads a pixel back from the GPU. No window is shown. Built for ARM64 and for x64
 * by scripts/test-finewine-runtime.sh; the x64 build runs the whole stack: FEX, the Direct3D
 * layer and Metal. Prints the adapter and "d3d11-clear: ok" on success. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

int main(void)
{
    static const D3D_FEATURE_LEVEL wanted[] = { D3D_FEATURE_LEVEL_11_0 };
    static const float colour[4] = { 1.0f, 0.5f, 0.25f, 1.0f };   /* reads back as ff 80 40 ff */
    ID3D11Device *device = NULL; ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *target = NULL, *staging = NULL; ID3D11RenderTargetView *view = NULL;
    IDXGIDevice *dxgi = NULL; IDXGIAdapter *adapter = NULL;
    D3D_FEATURE_LEVEL level = 0;
    D3D11_TEXTURE2D_DESC desc = {0};
    D3D11_MAPPED_SUBRESOURCE map;
    DXGI_ADAPTER_DESC adesc;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, wanted, 1, D3D11_SDK_VERSION, &device, &level, &ctx);
    if (FAILED(hr)) { printf("d3d11-clear: D3D11CreateDevice failed 0x%08lx\n", hr); return 1; }
    printf("feature level: 0x%x\n", level);

    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter)) && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &adesc)))
    {
        printf("adapter: %ls (%lu MB)\n", adesc.Description, (unsigned long)(adesc.DedicatedVideoMemory >> 20));
        printf("adapter ids: vendor %04x device %04x\n", adesc.VendorId, adesc.DeviceId);
    }

    desc.Width = desc.Height = 64; desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &target);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &view);
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);
    if (FAILED(hr)) { printf("d3d11-clear: creating textures failed 0x%08lx\n", hr); return 1; }

    ID3D11DeviceContext_ClearRenderTargetView(ctx, view, colour);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)target);
    hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    if (FAILED(hr)) { printf("d3d11-clear: Map failed 0x%08lx\n", hr); return 1; }
    const unsigned char *px = (const unsigned char *)map.pData + 32 * map.RowPitch + 32 * 4;
    printf("pixel: %02x %02x %02x %02x\n", px[0], px[1], px[2], px[3]);
    int ok = px[0] == 0xff && (px[1] == 0x80 || px[1] == 0x7f) && px[2] == 0x40 && px[3] == 0xff;
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    printf(ok ? "d3d11-clear: ok\n" : "d3d11-clear: FAILED (wrong pixel)\n");
    return !ok;
}
