/* End-to-end Direct3D 11: compile HLSL, draw a full-screen triangle into an
 * offscreen target, read back and verify the pixel. Exercises device
 * creation, the shader translator (DXBC → Metal/SPIR-V) and the copy path. */
#define COBJMACROS
#define INITGUID
#include "probe.h"
#include <d3d11.h>
#include <dxgi.h>
#include <d3dcompiler.h>
#include <string.h>

static const char shader_src[] =
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "    float2 uv = float2((id << 1) & 2, id & 2);\n"
    "    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);\n"
    "}\n"
    "float4 ps() : SV_Target { return float4(0.2, 0.6, 0.9, 1.0); }\n";

typedef HRESULT (WINAPI *PFN_D3DCompile)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *,
                                         ID3DInclude *, const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

int main(void)
{
    ID3D11Device *dev; ID3D11DeviceContext *ctx; D3D_FEATURE_LEVEL fl;
    IDXGIDevice *dxgi_dev; IDXGIAdapter *adapter; DXGI_ADAPTER_DESC ad;
    char gpu[128];
    probe_name = "d3d11";

    CHECK_HR(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx),
             "D3D11CreateDevice");
    CHECK_HR(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi_dev), "QueryInterface(IDXGIDevice)");
    CHECK_HR(IDXGIDevice_GetAdapter(dxgi_dev, &adapter), "GetAdapter");
    CHECK_HR(IDXGIAdapter_GetDesc(adapter, &ad), "GetDesc");
    WideCharToMultiByte(CP_UTF8, 0, ad.Description, -1, gpu, sizeof(gpu), NULL, NULL);

    HMODULE comp = LoadLibraryA("d3dcompiler_47.dll");
    PFN_D3DCompile compile = comp ? (PFN_D3DCompile)GetProcAddress(comp, "D3DCompile") : NULL;
    if (!compile) FAIL("d3dcompiler_47 unavailable");
    ID3DBlob *vsb, *psb, *err = NULL;
    if (FAILED(compile(shader_src, sizeof(shader_src) - 1, "probe", NULL, NULL, "vs", "vs_4_0", 0, 0, &vsb, &err)))
        FAIL("VS compile: %s", err ? (char *)ID3D10Blob_GetBufferPointer(err) : "?");
    if (FAILED(compile(shader_src, sizeof(shader_src) - 1, "probe", NULL, NULL, "ps", "ps_4_0", 0, 0, &psb, &err)))
        FAIL("PS compile: %s", err ? (char *)ID3D10Blob_GetBufferPointer(err) : "?");

    ID3D11VertexShader *vs; ID3D11PixelShader *ps;
    CHECK_HR(ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), NULL, &vs), "CreateVertexShader");
    CHECK_HR(ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psb), ID3D10Blob_GetBufferSize(psb), NULL, &ps), "CreatePixelShader");

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = td.Height = 64; td.MipLevels = td.ArraySize = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *rt, *staging; ID3D11RenderTargetView *rtv;
    CHECK_HR(ID3D11Device_CreateTexture2D(dev, &td, NULL, &rt), "CreateTexture2D(rt)");
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    CHECK_HR(ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging), "CreateTexture2D(staging)");
    CHECK_HR(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv), "CreateRenderTargetView");

    const float clear[4] = {1, 0, 1, 1};
    D3D11_VIEWPORT vp = {0, 0, 64, 64, 0, 1};
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)rt);

    D3D11_MAPPED_SUBRESOURCE m;
    CHECK_HR(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m), "Map");
    unsigned int px = ((unsigned int *)((char *)m.pData + 32 * m.RowPitch))[32];
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);

    /* Which implementation is actually loaded: proves backend selection. */
    const char *impl = GetModuleHandleA("winemetal.dll") ? "dxmt"
                     /* D3DMetal's d3d11 lacks D3D11CoreCreateDevice; DXVK's has it but
                      * omits Wine's D3DKMT forwarders. */
                     : !GetProcAddress(GetModuleHandleA("d3d11.dll"), "D3D11CoreCreateDevice") ? "d3dmetal"
                     : !GetProcAddress(GetModuleHandleA("d3d11.dll"), "D3DKMTCreateDevice") ? "dxvk"
                     : GetModuleHandleA("wined3d.dll") ? "wined3d" : "unknown";
    if (!color_close(px, 51, 153, 230)) FAIL("pixel 0x%08x, expected ~0xffe69933 (gpu %s, impl %s)", px, gpu, impl);
    PASS("impl=%s feature level %x, gpu \"%s\"", impl, fl, gpu);
    return 0;
}
