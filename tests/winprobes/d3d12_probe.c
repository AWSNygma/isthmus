/* Direct3D 12: device, queue, clear an RTV, copy to a readback buffer,
 * fence-wait, verify. Runs on D3DMetal or vkd3d (→ MoltenVK). */
#define COBJMACROS
#define INITGUID
#define WIDL_C_INLINE_WRAPPERS
#include "probe.h"
#include <d3d12.h>
#include <dxgi1_4.h>

typedef HRESULT (WINAPI *PFN_CreateDevice)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);

int main(void)
{
    probe_name = "d3d12";
    HMODULE lib = LoadLibraryA("d3d12.dll");
    PFN_CreateDevice create = lib ? (PFN_CreateDevice)GetProcAddress(lib, "D3D12CreateDevice") : NULL;
    if (!create) SKIP("d3d12.dll not available");

    ID3D12Device *dev;
    HRESULT hr = create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    if (FAILED(hr)) FAIL("D3D12CreateDevice failed: 0x%08lx", (unsigned long)hr);

    D3D12_COMMAND_QUEUE_DESC qd = {0}; qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue *queue; ID3D12CommandAllocator *alloc; ID3D12GraphicsCommandList *list;
    CHECK_HR(ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue), "CreateCommandQueue");
    CHECK_HR(ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc), "CreateCommandAllocator");
    CHECK_HR(ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list), "CreateCommandList");

    D3D12_HEAP_PROPERTIES hp = {0}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC rd = {0};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; rd.Width = 64; rd.Height = 64; rd.DepthOrArraySize = 1;
    rd.MipLevels = 1; rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rd.SampleDesc.Count = 1;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    ID3D12Resource *rt, *rb;
    CHECK_HR(ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_RENDER_TARGET, NULL, &IID_ID3D12Resource, (void **)&rt), "CreateCommittedResource(rt)");

    D3D12_HEAP_PROPERTIES rbh = {0}; rbh.Type = D3D12_HEAP_TYPE_READBACK;
    D3D12_RESOURCE_DESC bd = {0};
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = 256 * 64; bd.Height = 1; bd.DepthOrArraySize = 1;
    bd.MipLevels = 1; bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    CHECK_HR(ID3D12Device_CreateCommittedResource(dev, &rbh, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&rb), "CreateCommittedResource(readback)");

    D3D12_DESCRIPTOR_HEAP_DESC hd = {0}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = 1;
    ID3D12DescriptorHeap *heap;
    CHECK_HR(ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap), "CreateDescriptorHeap");
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    rtv = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
    ID3D12Device_CreateRenderTargetView(dev, rt, NULL, rtv);

    const float color[4] = {0.2f, 0.6f, 0.9f, 1.0f};
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, color, 0, NULL);
    D3D12_RESOURCE_BARRIER b = {0};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; b.Transition.pResource = rt;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);

    D3D12_TEXTURE_COPY_LOCATION dst = {0}, src = {0};
    dst.pResource = rb; dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    dst.PlacedFootprint.Footprint.Width = 64; dst.PlacedFootprint.Footprint.Height = 64;
    dst.PlacedFootprint.Footprint.Depth = 1; dst.PlacedFootprint.Footprint.RowPitch = 256;
    src.pResource = rt; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    CHECK_HR(ID3D12GraphicsCommandList_Close(list), "Close");

    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
    ID3D12Fence *fence; HANDLE ev = CreateEventA(NULL, FALSE, FALSE, NULL);
    CHECK_HR(ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence), "CreateFence");
    CHECK_HR(ID3D12CommandQueue_Signal(queue, fence, 1), "Signal");
    CHECK_HR(ID3D12Fence_SetEventOnCompletion(fence, 1, ev), "SetEventOnCompletion");
    if (WaitForSingleObject(ev, 10000) != WAIT_OBJECT_0) FAIL("GPU fence timed out");

    void *p; D3D12_RANGE r = {0, 256 * 64};
    CHECK_HR(ID3D12Resource_Map(rb, 0, &r, &p), "Map");
    unsigned int px = ((unsigned int *)((char *)p + 32 * 256))[32];
    if (!color_close(px, 51, 153, 230)) FAIL("pixel 0x%08x, expected ~0xffe69933", px);
    PASS("clear+copy+fence ok");
    return 0;
}
