/* dlss-metalfx.c: checks the path a game's DLSS integration takes. With DXMT, nvngx.dll is
 * DXMT's and turns DLSS upscaling into MetalFX. This creates a Direct3D 11 device, initialises
 * NGX on it the way the DLSS SDK does, and asks for the capability parameters; it also checks
 * that NVAPI initialises. It does not upscale a frame. Prints "dlss-metalfx: ok" on success. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

typedef unsigned int (*ngx_init_t)(unsigned long long app_id, const wchar_t *data_path, ID3D11Device *device, const void *feature_info, unsigned int sdk_version);
typedef unsigned int (*ngx_params_t)(void **params);
typedef unsigned int (*ngx_shutdown_t)(ID3D11Device *device);
typedef void *(*nvapi_query_t)(unsigned int id);
typedef int (*nvapi_fn_t)(void);

int main(void)
{
    static const D3D_FEATURE_LEVEL wanted[] = { D3D_FEATURE_LEVEL_11_0 };
    ID3D11Device *device = NULL; ID3D11DeviceContext *ctx = NULL;
    void *params = NULL;
    setvbuf(stdout, NULL, _IONBF, 0);

    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, wanted, 1, D3D11_SDK_VERSION, &device, NULL, &ctx);
    if (FAILED(hr)) { printf("dlss-metalfx: D3D11CreateDevice failed 0x%08lx\n", (unsigned long)hr); return 1; }

    HMODULE ngx = LoadLibraryA("nvngx.dll");
    if (!ngx) { printf("dlss-metalfx: nvngx.dll did not load (%lu)\n", GetLastError()); return 1; }
    ngx_init_t init = (ngx_init_t)GetProcAddress(ngx, "NVSDK_NGX_D3D11_Init");
    ngx_params_t get_params = (ngx_params_t)GetProcAddress(ngx, "NVSDK_NGX_D3D11_GetCapabilityParameters");
    ngx_shutdown_t shutdown = (ngx_shutdown_t)GetProcAddress(ngx, "NVSDK_NGX_D3D11_Shutdown1");
    if (!init || !get_params) { printf("dlss-metalfx: nvngx.dll lacks the NGX entry points\n"); return 1; }

    unsigned int r = init(0x1234, L"C:\\", device, NULL, 0x15);
    printf("NGX init on the Direct3D 11 device: 0x%x\n", r);
    if (r != 1) { printf("dlss-metalfx: NGX did not initialise\n"); return 1; }   /* 1 is NVSDK_NGX_Result_Success */
    r = get_params(&params);
    printf("NGX capability parameters: 0x%x, %s\n", r, params ? "present" : "missing");
    if (r != 1 || !params) { printf("dlss-metalfx: no capability parameters\n"); return 1; }
    if (shutdown) shutdown(device);

    HMODULE nvapi = LoadLibraryA("nvapi64.dll");
    nvapi_query_t query = nvapi ? (nvapi_query_t)GetProcAddress(nvapi, "nvapi_QueryInterface") : NULL;
    nvapi_fn_t nvapi_init = query ? (nvapi_fn_t)query(0x0150E828) : NULL;   /* NvAPI_Initialize */
    int status = nvapi_init ? nvapi_init() : -1;
    printf("NVAPI initialise: %d\n", status);
    if (status != 0) { printf("dlss-metalfx: NVAPI did not initialise\n"); return 1; }

    printf("dlss-metalfx: ok\n");
    return 0;
}
