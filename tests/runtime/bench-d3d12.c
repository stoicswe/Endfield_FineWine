/* bench-d3d12.c: what a Direct3D 12 draw call costs in the FineWine stack.
 *
 * The same frame as bench-d3d11.c: 10,000 small triangles, each with its own constants (a
 * constant buffer view into one big upload buffer), recorded into a command list and
 * executed. The path measured is the game's code, Wine's vkd3d, MoltenVK and Metal.
 * Prints milliseconds per frame. Run by scripts/bench-finewine-runtime.sh. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>

static const char shader[] =
    "cbuffer C : register(b0) { float4 offset; float4 colour; };\n"
    "float4 vs(float2 p : POSITION) : SV_Position { return float4(p * 0.02 + offset.xy, 0.0, 1.0); }\n"
    "float4 ps() : SV_Target { return colour; }\n";

static double now_ms(void) { LARGE_INTEGER c, f; QueryPerformanceCounter(&c); QueryPerformanceFrequency(&f); return 1000.0 * (double)c.QuadPart / (double)f.QuadPart; }
#define CHECK(hr, what) do { if (FAILED(hr)) { printf("bench-d3d12: %s failed 0x%08lx\n", what, (unsigned long)(hr)); return 1; } } while (0)

static ID3D12Resource *buffer(ID3D12Device *device, D3D12_HEAP_TYPE heap, UINT64 size, D3D12_RESOURCE_STATES state)
{
    D3D12_HEAP_PROPERTIES hp = { heap }; D3D12_RESOURCE_DESC bd = {0}; ID3D12Resource *r = NULL;
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = size; bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1;
    bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Device_CreateCommittedResource(device, &hp, D3D12_HEAP_FLAG_NONE, &bd, state, NULL, &IID_ID3D12Resource, (void **)&r);
    return r;
}

int main(void)
{
    enum { SIZE = 1024, DRAWS = 10000, FRAMES = 30, SLOT = 256 };
    static const float verts[6] = { -1, -1, 1, -1, 0, 1 }, clear[4] = { 0, 0, 0, 1 };
    ID3D12Device *device; ID3D12CommandQueue *queue; ID3D12CommandAllocator *alloc; ID3D12GraphicsCommandList *list;
    ID3D12Resource *target; ID3D12DescriptorHeap *heap; ID3D12RootSignature *rootsig; ID3D12PipelineState *pso; ID3D12Fence *fence;
    ID3DBlob *vsb = NULL, *psb = NULL, *err = NULL, *rsb = NULL; HRESULT hr;
    setvbuf(stdout, NULL, _IONBF, 0);

    hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device); CHECK(hr, "D3D12CreateDevice");
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    hr = ID3D12Device_CreateCommandQueue(device, &qd, &IID_ID3D12CommandQueue, (void **)&queue); CHECK(hr, "CreateCommandQueue");
    hr = ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc); CHECK(hr, "CreateCommandAllocator");
    hr = ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list); CHECK(hr, "CreateCommandList");
    hr = ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence); CHECK(hr, "CreateFence");
    HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL); UINT64 fence_value = 0;

    D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_DEFAULT }; D3D12_RESOURCE_DESC rd = {0};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; rd.Width = SIZE; rd.Height = SIZE; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rd.SampleDesc.Count = 1; rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    hr = ID3D12Device_CreateCommittedResource(device, &hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_RENDER_TARGET, NULL, &IID_ID3D12Resource, (void **)&target); CHECK(hr, "CreateCommittedResource");
    D3D12_DESCRIPTOR_HEAP_DESC hd = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1 };
    hr = ID3D12Device_CreateDescriptorHeap(device, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap); CHECK(hr, "CreateDescriptorHeap");
    D3D12_CPU_DESCRIPTOR_HANDLE rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
    ID3D12Device_CreateRenderTargetView(device, target, NULL, rtv);

    D3D12_ROOT_PARAMETER rp = { D3D12_ROOT_PARAMETER_TYPE_CBV }; rp.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    D3D12_ROOT_SIGNATURE_DESC rsd = { 1, &rp, 0, NULL, D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT };
    hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &rsb, &err); CHECK(hr, "D3D12SerializeRootSignature");
    hr = ID3D12Device_CreateRootSignature(device, 0, ID3D10Blob_GetBufferPointer(rsb), ID3D10Blob_GetBufferSize(rsb), &IID_ID3D12RootSignature, (void **)&rootsig); CHECK(hr, "CreateRootSignature");
    hr = D3DCompile(shader, sizeof(shader) - 1, "bench", NULL, NULL, "vs", "vs_5_0", 0, 0, &vsb, &err); CHECK(hr, "D3DCompile (vertex)");
    hr = D3DCompile(shader, sizeof(shader) - 1, "bench", NULL, NULL, "ps", "ps_5_0", 0, 0, &psb, &err); CHECK(hr, "D3DCompile (pixel)");
    D3D12_INPUT_ELEMENT_DESC il = { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd; memset(&pd, 0, sizeof(pd));
    pd.pRootSignature = rootsig;
    pd.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vsb); pd.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vsb);
    pd.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(psb); pd.PS.BytecodeLength = ID3D10Blob_GetBufferSize(psb);
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL; pd.SampleMask = ~0u;
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.InputLayout.pInputElementDescs = &il; pd.InputLayout.NumElements = 1;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE; pd.NumRenderTargets = 1; pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM; pd.SampleDesc.Count = 1;
    hr = ID3D12Device_CreateGraphicsPipelineState(device, &pd, &IID_ID3D12PipelineState, (void **)&pso); CHECK(hr, "CreateGraphicsPipelineState");

    ID3D12Resource *vb = buffer(device, D3D12_HEAP_TYPE_UPLOAD, sizeof(verts), D3D12_RESOURCE_STATE_GENERIC_READ);
    ID3D12Resource *constants = buffer(device, D3D12_HEAP_TYPE_UPLOAD, (UINT64)DRAWS * SLOT, D3D12_RESOURCE_STATE_GENERIC_READ);
    D3D12_RESOURCE_DESC one = rd; one.Width = one.Height = 1; one.Flags = 0;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT64 total_bytes = 0;
    ID3D12Device_GetCopyableFootprints(device, &one, 0, 1, 0, &fp, NULL, NULL, &total_bytes);
    ID3D12Resource *readback = buffer(device, D3D12_HEAP_TYPE_READBACK, total_bytes, D3D12_RESOURCE_STATE_COPY_DEST);
    if (!vb || !constants || !readback) { printf("bench-d3d12: could not create the buffers\n"); return 1; }
    void *p; D3D12_RANGE none = { 0, 0 };
    hr = ID3D12Resource_Map(vb, 0, &none, &p); CHECK(hr, "Map (vertices)"); memcpy(p, verts, sizeof(verts)); ID3D12Resource_Unmap(vb, 0, NULL);
    unsigned char *cdata; hr = ID3D12Resource_Map(constants, 0, &none, (void **)&cdata); CHECK(hr, "Map (constants)");
    D3D12_VERTEX_BUFFER_VIEW vbv = { ID3D12Resource_GetGPUVirtualAddress(vb), sizeof(verts), 8 };
    D3D12_GPU_VIRTUAL_ADDRESS cbase = ID3D12Resource_GetGPUVirtualAddress(constants);
    D3D12_VIEWPORT vp = { 0, 0, SIZE, SIZE, 0, 1 }; D3D12_RECT scissor = { 0, 0, SIZE, SIZE };

    double total[2] = { 0, 0 }, worst[2] = { 0, 0 }, record[2] = { 0, 0 };
    for (int mode = 0; mode < 2; mode++) {            /* 0: constants change every draw; 1: draws only */
        for (int f = 0; f < FRAMES + 5; f++) {
            double t0 = now_ms();
            ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, NULL);
            ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, clear, 0, NULL);
            ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp); ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &scissor);
            ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, rootsig); ID3D12GraphicsCommandList_SetPipelineState(list, pso);
            ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ID3D12GraphicsCommandList_IASetVertexBuffers(list, 0, 1, &vbv);
            for (int d = 0; d < DRAWS; d++) {
                if (mode == 0 || d == 0) {
                    float v[8] = { (d % 100) * 0.02f - 0.99f, (d / 100) * 0.02f - 0.99f, 0, 0, 1.0f, (d % 7) / 7.0f, (f % 5) / 5.0f, 1.0f };
                    memcpy(cdata + (size_t)d * SLOT, v, sizeof(v));
                    ID3D12GraphicsCommandList_SetGraphicsRootConstantBufferView(list, 0, cbase + (UINT64)d * SLOT);
                }
                ID3D12GraphicsCommandList_DrawInstanced(list, 3, 1, 0, 0);
            }
            D3D12_RESOURCE_BARRIER b = { D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
            b.Transition.pResource = target; b.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
            ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
            D3D12_TEXTURE_COPY_LOCATION dst = { readback, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT }, src = { target, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
            dst.PlacedFootprint = fp; D3D12_BOX box = { SIZE / 2, SIZE / 2, 0, SIZE / 2 + 1, SIZE / 2 + 1, 1 };
            ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, &box);
            b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE; b.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
            ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
            hr = ID3D12GraphicsCommandList_Close(list); CHECK(hr, "Close");
            double recorded = now_ms() - t0;
            ID3D12CommandList *lists[1] = { (ID3D12CommandList *)list };
            ID3D12CommandQueue_ExecuteCommandLists(queue, 1, lists);
            ID3D12CommandQueue_Signal(queue, fence, ++fence_value); ID3D12Fence_SetEventOnCompletion(fence, fence_value, event);
            if (WaitForSingleObject(event, 30000) != WAIT_OBJECT_0) { printf("bench-d3d12: the GPU did not finish\n"); return 1; }
            ID3D12CommandAllocator_Reset(alloc); ID3D12GraphicsCommandList_Reset(list, alloc, NULL);
            double ms = now_ms() - t0;
            if (f >= 5) { total[mode] += ms; record[mode] += recorded; if (ms > worst[mode]) worst[mode] = ms; }
        }
        unsigned char *px; D3D12_RANGE all = { 0, (SIZE_T)total_bytes };
        hr = ID3D12Resource_Map(readback, 0, &all, (void **)&px); CHECK(hr, "Map (read back)");
        if (mode == 0 && !px[fp.Offset]) { printf("bench-d3d12: nothing was drawn\n"); return 1; }
        ID3D12Resource_Unmap(readback, 0, NULL);
    }
    printf("%-34s %9.2f ms per frame (worst %.2f; %.2f recording), %.0f draws per ms\n", "D3D12 10k draws, new constants", total[0] / FRAMES, worst[0], record[0] / FRAMES, DRAWS / (total[0] / FRAMES));
    printf("%-34s %9.2f ms per frame (worst %.2f; %.2f recording), %.0f draws per ms\n", "D3D12 10k draws, nothing changes", total[1] / FRAMES, worst[1], record[1] / FRAMES, DRAWS / (total[1] / FRAMES));
    return 0;
}
