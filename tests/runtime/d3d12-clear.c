/* d3d12-clear.c: Direct3D 12 end to end without showing a window. Creates a device, clears a
 * render target on the GPU, copies it to a buffer and checks a pixel; then creates a swap chain
 * on a window that is never shown and presents one frame, which is the step that ties
 * Direct3D 12 to the window system. Prints the adapter and "d3d12-clear: ok" on success. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS   /* gives the C wrappers for methods that return a struct */
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>

#define CHECK(hr, what) do { if (FAILED(hr)) { printf("d3d12-clear: %s failed 0x%08lx\n", what, (unsigned long)(hr)); return 1; } } while (0)

static int wait_for_gpu(ID3D12Device *device, ID3D12CommandQueue *queue)
{
    ID3D12Fence *fence = NULL;
    HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (FAILED(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence))) return 0;
    ID3D12CommandQueue_Signal(queue, fence, 1);
    ID3D12Fence_SetEventOnCompletion(fence, 1, event);
    DWORD w = WaitForSingleObject(event, 20000);
    ID3D12Fence_Release(fence); CloseHandle(event);
    return w == WAIT_OBJECT_0;
}

int main(void)
{
    static const float colour[4] = { 1.0f, 0.5f, 0.25f, 1.0f };   /* reads back as ff 80 40 ff */
    ID3D12Device *device = NULL; ID3D12CommandQueue *queue = NULL; ID3D12CommandAllocator *alloc = NULL;
    ID3D12GraphicsCommandList *list = NULL; ID3D12Resource *target = NULL, *readback = NULL;
    ID3D12DescriptorHeap *heap = NULL; IDXGIFactory4 *factory = NULL; IDXGIAdapter1 *adapter = NULL;
    IDXGISwapChain1 *swapchain = NULL;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory); CHECK(hr, "CreateDXGIFactory1");
    if (SUCCEEDED(IDXGIFactory4_EnumAdapters1(factory, 0, &adapter)))
    {
        DXGI_ADAPTER_DESC1 d; IDXGIAdapter1_GetDesc1(adapter, &d);
        printf("adapter: %ls (%lu MB), vendor %04x device %04x\n", d.Description,
               (unsigned long)(d.DedicatedVideoMemory >> 20), d.VendorId, d.DeviceId);
    }
    hr = D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device);
    CHECK(hr, "D3D12CreateDevice");

    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    hr = ID3D12Device_CreateCommandQueue(device, &qd, &IID_ID3D12CommandQueue, (void **)&queue); CHECK(hr, "CreateCommandQueue");
    hr = ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc); CHECK(hr, "CreateCommandAllocator");
    hr = ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list); CHECK(hr, "CreateCommandList");

    D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_DEFAULT };
    D3D12_RESOURCE_DESC rd = {0};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; rd.Width = 64; rd.Height = 64; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rd.SampleDesc.Count = 1; rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    D3D12_CLEAR_VALUE cv = { DXGI_FORMAT_R8G8B8A8_UNORM, .Color = { 1.0f, 0.5f, 0.25f, 1.0f } };
    hr = ID3D12Device_CreateCommittedResource(device, &hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_RENDER_TARGET, &cv, &IID_ID3D12Resource, (void **)&target);
    CHECK(hr, "CreateCommittedResource (render target)");

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT64 total = 0;
    ID3D12Device_GetCopyableFootprints(device, &rd, 0, 1, 0, &fp, NULL, NULL, &total);
    D3D12_HEAP_PROPERTIES rhp = { D3D12_HEAP_TYPE_READBACK };
    D3D12_RESOURCE_DESC bd = {0};
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = total; bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1;
    bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    hr = ID3D12Device_CreateCommittedResource(device, &rhp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback);
    CHECK(hr, "CreateCommittedResource (readback)");

    D3D12_DESCRIPTOR_HEAP_DESC hd = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1 };
    hr = ID3D12Device_CreateDescriptorHeap(device, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap); CHECK(hr, "CreateDescriptorHeap");
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
    ID3D12Device_CreateRenderTargetView(device, target, NULL, rtv);

    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, colour, 0, NULL);
    D3D12_RESOURCE_BARRIER barrier = { D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
    barrier.Transition.pResource = target; barrier.Transition.Subresource = 0;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
    D3D12_TEXTURE_COPY_LOCATION dst = { readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT }, src = { target, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
    dst.PlacedFootprint = fp; src.SubresourceIndex = 0;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    hr = ID3D12GraphicsCommandList_Close(list); CHECK(hr, "Close");
    ID3D12CommandList *lists[1] = { (ID3D12CommandList *)list };
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, lists);
    if (!wait_for_gpu(device, queue)) { printf("d3d12-clear: the GPU did not finish\n"); return 1; }

    unsigned char *data = NULL; D3D12_RANGE range = { 0, (SIZE_T)total };
    hr = ID3D12Resource_Map(readback, 0, &range, (void **)&data); CHECK(hr, "Map");
    const unsigned char *px = data + fp.Offset + 32 * fp.Footprint.RowPitch + 32 * 4;
    printf("pixel: %02x %02x %02x %02x\n", px[0], px[1], px[2], px[3]);
    int ok = px[0] == 0xff && (px[1] == 0x80 || px[1] == 0x7f) && px[2] == 0x40 && px[3] == 0xff;
    ID3D12Resource_Unmap(readback, 0, NULL);
    if (!ok) { printf("d3d12-clear: FAILED (wrong pixel)\n"); return 1; }

    /* swap chain on a window that is never shown */
    WNDCLASSW wc = {0}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"FineWineD3D12Test";
    RegisterClassW(&wc);
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW, 0, 0, 256, 256, NULL, NULL, wc.hInstance, NULL);
    if (!window) { printf("d3d12-clear: CreateWindow failed %lu\n", GetLastError()); return 1; }
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = 256; sd.Height = 256; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, window, &sd, NULL, NULL, &swapchain);
    CHECK(hr, "CreateSwapChainForHwnd");
    hr = IDXGISwapChain1_Present(swapchain, 0, 0); CHECK(hr, "Present");
    printf("swap chain: created and presented\n");
    printf("d3d12-clear: ok\n");
    return 0;
}
