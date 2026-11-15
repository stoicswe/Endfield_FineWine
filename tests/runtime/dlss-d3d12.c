/* dlss-d3d12.c: DLSS for a Direct3D 12 program, the way a game reaches it.
 *
 * The program calls nvngx.dll's NVSDK_NGX_D3D12_* entry points with Direct3D 12 textures. In
 * FineWine those record a MetalFX command, through Wine's vkd3d, in MoltenVK.
 *  1. Super resolution (feature 1): a 256x256 frame with a white square is upscaled to 512x512.
 *  2. Frame generation (feature 11): the square moves 16 pixels a frame; from the third frame
 *     on, the generated frame must show it between its last two positions.
 * Needs FINEWINE_DLSS=1. Prints "dlss-d3d12: ok" on success. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
#include "ngx-c.h"

#define FAIL(...) do { printf("dlss-d3d12: " __VA_ARGS__); printf("\n"); return 1; } while (0)
#define CHECK(hr, what) do { if (FAILED(hr)) FAIL("%s failed 0x%08lx", what, (unsigned long)(hr)); } while (0)

static ID3D12Device *device; static ID3D12CommandQueue *queue; static ID3D12CommandAllocator *alloc; static ID3D12GraphicsCommandList *list;

static int run(void)
{
    ID3D12Fence *fence = NULL; HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
    ID3D12CommandList *lists[1] = { (ID3D12CommandList *)list };
    if (FAILED(ID3D12GraphicsCommandList_Close(list))) return 1;
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, lists);
    if (FAILED(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence))) return 1;
    ID3D12CommandQueue_Signal(queue, fence, 1); ID3D12Fence_SetEventOnCompletion(fence, 1, event);
    DWORD w = WaitForSingleObject(event, 30000);
    ID3D12Fence_Release(fence); CloseHandle(event);
    if (w != WAIT_OBJECT_0) return 1;
    return FAILED(ID3D12CommandAllocator_Reset(alloc)) || FAILED(ID3D12GraphicsCommandList_Reset(list, alloc, NULL));
}

static ID3D12Resource *texture(DXGI_FORMAT format, UINT size, D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state)
{
    D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_DEFAULT }; D3D12_RESOURCE_DESC rd = {0}; ID3D12Resource *r = NULL;
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; rd.Width = size; rd.Height = size; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
    rd.Format = format; rd.SampleDesc.Count = 1; rd.Flags = flags;
    if (FAILED(ID3D12Device_CreateCommittedResource(device, &hp, D3D12_HEAP_FLAG_NONE, &rd, state, NULL, &IID_ID3D12Resource, (void **)&r))) return NULL;
    return r;
}

static void transition(ID3D12Resource *r, D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to)
{
    D3D12_RESOURCE_BARRIER b = { D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
    b.Transition.pResource = r; b.Transition.StateBefore = from; b.Transition.StateAfter = to;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

/* Where the bright pixels of the middle row start and end. */
static void bright_span(const unsigned char *p, UINT pitch, UINT size, int *first, int *last)
{
    *first = *last = -1;
    for (UINT x = 0; x < size; x++) if (p[(size / 2) * pitch + x * 4] > 128) { if (*first < 0) *first = (int)x; *last = (int)x; }
}

int main(void)
{
    enum { LOW = 256, HIGH = 512 };
    static const float grey[4] = { 0.08f, 0.08f, 0.08f, 1.0f }, white[4] = { 1.0f, 1.0f, 1.0f, 1.0f }, zero[4] = { 0 }, moved[4] = { -16.0f, 0.0f, 0.0f, 0.0f };
    HRESULT hr;
    setvbuf(stdout, NULL, _IONBF, 0);

    hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device); CHECK(hr, "D3D12CreateDevice");
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    hr = ID3D12Device_CreateCommandQueue(device, &qd, &IID_ID3D12CommandQueue, (void **)&queue); CHECK(hr, "CreateCommandQueue");
    hr = ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc); CHECK(hr, "CreateCommandAllocator");
    hr = ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list); CHECK(hr, "CreateCommandList");

    HMODULE ngx = LoadLibraryA("nvngx.dll");
    if (!ngx) FAIL("nvngx.dll did not load (%lu)", GetLastError());
    ngx_alloc_params_t alloc_params = (ngx_alloc_params_t)GetProcAddress(ngx, "NVSDK_NGX_D3D12_AllocateParameters");
    ngx_alloc_params_t capabilities = (ngx_alloc_params_t)GetProcAddress(ngx, "NVSDK_NGX_D3D12_GetCapabilityParameters");
    ngx_create_t create = (ngx_create_t)GetProcAddress(ngx, "NVSDK_NGX_D3D12_CreateFeature");
    ngx_evaluate_t evaluate = (ngx_evaluate_t)GetProcAddress(ngx, "NVSDK_NGX_D3D12_EvaluateFeature");
    ngx_release_t release = (ngx_release_t)GetProcAddress(ngx, "NVSDK_NGX_D3D12_ReleaseFeature");
    if (!alloc_params || !capabilities || !create || !evaluate || !release) FAIL("nvngx.dll has no Direct3D 12 entry points");
    NGXParams *caps = NULL, *params = NULL; unsigned int available = 0, fg_available = 0;
    if (capabilities(&caps) != NGX_OK || alloc_params(&params) != NGX_OK) FAIL("could not get NGX parameters");
    NGX_GET_UINT(caps, "SuperSampling.Available", &available); NGX_GET_UINT(caps, "FrameGeneration.Available", &fg_available);
    printf("NGX reports: super resolution %u, frame generation %u\n", available, fg_available);
    if (!available || !fg_available) FAIL("NGX does not report both features as available");

    /* The textures a game hands to DLSS. */
    ID3D12Resource *color = texture(DXGI_FORMAT_R8G8B8A8_UNORM, LOW, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12Resource *motion = texture(DXGI_FORMAT_R16G16_FLOAT, LOW, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12Resource *depth = texture(DXGI_FORMAT_D32_FLOAT, LOW, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, D3D12_RESOURCE_STATE_DEPTH_WRITE);
    ID3D12Resource *upscaled = texture(DXGI_FORMAT_R8G8B8A8_UNORM, HIGH, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    ID3D12Resource *full = texture(DXGI_FORMAT_R8G8B8A8_UNORM, HIGH, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12Resource *full_motion = texture(DXGI_FORMAT_R16G16_FLOAT, HIGH, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12Resource *full_depth = texture(DXGI_FORMAT_D32_FLOAT, HIGH, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, D3D12_RESOURCE_STATE_DEPTH_WRITE);
    ID3D12Resource *between = texture(DXGI_FORMAT_R8G8B8A8_UNORM, HIGH, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_RENDER_TARGET);
    if (!color || !motion || !depth || !upscaled || !full || !full_motion || !full_depth || !between) FAIL("could not create the textures");

    ID3D12DescriptorHeap *rtv_heap = NULL, *dsv_heap = NULL;
    D3D12_DESCRIPTOR_HEAP_DESC rhd = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 4 }, dhd = { D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 2 };
    hr = ID3D12Device_CreateDescriptorHeap(device, &rhd, &IID_ID3D12DescriptorHeap, (void **)&rtv_heap); CHECK(hr, "CreateDescriptorHeap (RTV)");
    hr = ID3D12Device_CreateDescriptorHeap(device, &dhd, &IID_ID3D12DescriptorHeap, (void **)&dsv_heap); CHECK(hr, "CreateDescriptorHeap (DSV)");
    UINT rstep = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV), dstep = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    D3D12_CPU_DESCRIPTOR_HANDLE rtv[4], dsv[2];
    rtv[0] = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(rtv_heap); dsv[0] = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(dsv_heap);
    for (int i = 1; i < 4; i++) { rtv[i] = rtv[0]; rtv[i].ptr += i * rstep; }
    dsv[1] = dsv[0]; dsv[1].ptr += dstep;
    ID3D12Resource *targets[4] = { color, motion, full, full_motion };
    for (int i = 0; i < 4; i++) ID3D12Device_CreateRenderTargetView(device, targets[i], NULL, rtv[i]);
    ID3D12Device_CreateDepthStencilView(device, depth, NULL, dsv[0]); ID3D12Device_CreateDepthStencilView(device, full_depth, NULL, dsv[1]);

    D3D12_RESOURCE_DESC od = {0};
    od.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; od.Width = HIGH; od.Height = HIGH; od.DepthOrArraySize = 1; od.MipLevels = 1;
    od.Format = DXGI_FORMAT_R8G8B8A8_UNORM; od.SampleDesc.Count = 1;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT64 total = 0;
    ID3D12Device_GetCopyableFootprints(device, &od, 0, 1, 0, &fp, NULL, NULL, &total);
    D3D12_HEAP_PROPERTIES rhp = { D3D12_HEAP_TYPE_READBACK }; D3D12_RESOURCE_DESC bd = {0}; ID3D12Resource *readback = NULL;
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = total; bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1;
    bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    hr = ID3D12Device_CreateCommittedResource(device, &rhp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback);
    CHECK(hr, "CreateCommittedResource (readback)");
    D3D12_TEXTURE_COPY_LOCATION dst = { readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT }; dst.PlacedFootprint = fp;
    unsigned char *data = NULL; D3D12_RANGE range = { 0, (SIZE_T)total }; int first, last;

    /* 1. Super resolution. A still frame, several times over, as the scaler accumulates. */
    unsigned int *sr = NULL;
    NGX_SET_UINT(params, "Width", LOW); NGX_SET_UINT(params, "Height", LOW); NGX_SET_UINT(params, "OutWidth", HIGH); NGX_SET_UINT(params, "OutHeight", HIGH);
    NGX_SET_INT(params, "DLSS.Feature.Create.Flags", NGX_DLSS_FLAG_MV_LOWRES);
    if (create(list, NGX_FEATURE_SUPER_SAMPLING, params, &sr) != NGX_OK || !sr) FAIL("NVSDK_NGX_D3D12_CreateFeature (super resolution) failed");
    D3D12_RECT square = { 96, LOW / 2 - 32, 160, LOW / 2 + 32 };
    for (int f = 0; f < 4; f++) {
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[0], grey, 0, NULL);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[0], white, 1, &square);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[1], zero, 0, NULL);
        ID3D12GraphicsCommandList_ClearDepthStencilView(list, dsv[0], D3D12_CLEAR_FLAG_DEPTH, 0.5f, 0, 0, NULL);
        NGX_SET_D3D12(params, "Color", color); NGX_SET_D3D12(params, "Output", upscaled); NGX_SET_D3D12(params, "Depth", depth); NGX_SET_D3D12(params, "MotionVectors", motion);
        NGX_SET_UINT(params, "DLSS.Render.Subrect.Dimensions.Width", LOW); NGX_SET_UINT(params, "DLSS.Render.Subrect.Dimensions.Height", LOW);
        NGX_SET_INT(params, "Reset", f == 0); NGX_SET_FLOAT(params, "MV.Scale.X", 1.0f); NGX_SET_FLOAT(params, "MV.Scale.Y", 1.0f);
        unsigned int r = evaluate(list, sr, params, NULL);
        if (r != NGX_OK) FAIL("NVSDK_NGX_D3D12_EvaluateFeature (super resolution) failed 0x%08x", r);
        if (f == 3) {
            D3D12_TEXTURE_COPY_LOCATION src = { upscaled, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
            transition(upscaled, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
            ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
        }
        if (run()) FAIL("the GPU did not finish an upscale");
    }
    hr = ID3D12Resource_Map(readback, 0, &range, (void **)&data); CHECK(hr, "Map");
    bright_span(data + fp.Offset, fp.Footprint.RowPitch, HIGH, &first, &last);
    ID3D12Resource_Unmap(readback, 0, NULL);
    printf("super resolution: the square at 96..159 of 256 comes out at %d..%d of 512\n", first, last);
    if (first < 188 || first > 196 || last < 315 || last > 323) FAIL("the upscaled square should be at about 192..319");

    /* 2. Frame generation. The square moves 16 pixels to the right each frame. */
    unsigned int *fg = NULL; NGXParams *fparams = NULL; int good = 0;
    if (alloc_params(&fparams) != NGX_OK) FAIL("could not get NGX parameters");
    NGX_SET_UINT(fparams, "Width", HIGH); NGX_SET_UINT(fparams, "Height", HIGH);
    if (create(list, NGX_FEATURE_FRAME_GENERATION, fparams, &fg) != NGX_OK || !fg) FAIL("NVSDK_NGX_D3D12_CreateFeature (frame generation) failed");
    for (int f = 0; f < 5; f++) {
        LONG x0 = 64 + 16 * f;
        D3D12_RECT sq = { x0, HIGH / 2 - 64, x0 + 128, HIGH / 2 + 64 };
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[2], grey, 0, NULL);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[2], white, 1, &sq);
        /* Each pixel of the square was 16 pixels further left in the last frame. */
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[3], zero, 0, NULL);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv[3], moved, 1, &sq);
        ID3D12GraphicsCommandList_ClearDepthStencilView(list, dsv[1], D3D12_CLEAR_FLAG_DEPTH, 0.5f, 0, 0, NULL);
        NGX_SET_D3D12(fparams, "DLSSG.Backbuffer", full); NGX_SET_D3D12(fparams, "DLSSG.OutputInterpolated", between);
        NGX_SET_D3D12(fparams, "DLSSG.Depth", full_depth); NGX_SET_D3D12(fparams, "DLSSG.MVecs", full_motion);
        NGX_SET_INT(fparams, "DLSSG.EnableInterp", 1); NGX_SET_INT(fparams, "DLSSG.Reset", f == 0);
        NGX_SET_FLOAT(fparams, "DLSSG.MvecScaleX", 1.0f); NGX_SET_FLOAT(fparams, "DLSSG.MvecScaleY", 1.0f);
        NGX_SET_FLOAT(fparams, "DLSSG.CameraNear", 0.1f); NGX_SET_FLOAT(fparams, "DLSSG.CameraFar", 100.0f);
        NGX_SET_FLOAT(fparams, "DLSSG.CameraFOV", 1.0472f); NGX_SET_FLOAT(fparams, "DLSSG.CameraAspectRatio", 1.0f);
        unsigned int r = evaluate(list, fg, fparams, NULL);
        if (r != NGX_OK) FAIL("NVSDK_NGX_D3D12_EvaluateFeature (frame generation) failed 0x%08x", r);
        D3D12_TEXTURE_COPY_LOCATION src = { between, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
        transition(between, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
        ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
        transition(between, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET);
        if (run()) FAIL("the GPU did not finish a frame");
        hr = ID3D12Resource_Map(readback, 0, &range, (void **)&data); CHECK(hr, "Map");
        bright_span(data + fp.Offset, fp.Footprint.RowPitch, HIGH, &first, &last);
        ID3D12Resource_Unmap(readback, 0, NULL);
        printf("frame generation, frame %d: square at %ld (was at %ld); the generated frame has it at %d\n", f, x0, x0 - 16, first);
        if (f >= 2 && first > x0 - 15 && first < x0 - 1) good++;
    }
    if (good < 3) FAIL("from the third frame on the generated frame should show the square between its last two positions");
    release(sr); release(fg);
    printf("dlss-d3d12: ok\n");
    return 0;
}
