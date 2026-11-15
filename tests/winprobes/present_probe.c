/* Windowed rendering loop for overlay checks (FPS counter / Metal HUD).
 *   present_probe.exe d3d11|d3d9 [seconds]
 * Opens a 960x540 window, clears it to a cycling color and presents every
 * frame, then prints "PASS present <api> <frames> frames, <fps> fps". */
#define COBJMACROS
#define INITGUID
#include "probe.h"
#include <d3d11.h>
#include <dxgi.h>
#include <d3d9.h>
#include <math.h>
#include <string.h>

static int pump(void)
{
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
    {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return 1;
}

static void color(double t, float c[4])
{
    c[0] = 0.5f + 0.5f * (float)sin(t);
    c[1] = 0.5f + 0.5f * (float)sin(t + 2.1);
    c[2] = 0.5f + 0.5f * (float)sin(t + 4.2);
    c[3] = 1.0f;
}

static void run_d3d11(HWND wnd, double seconds)
{
    DXGI_SWAP_CHAIN_DESC sd = {0};
    ID3D11Device *dev; ID3D11DeviceContext *ctx; IDXGISwapChain *sc;
    ID3D11Texture2D *bb; ID3D11RenderTargetView *rtv;
    LARGE_INTEGER f, t0, t; unsigned frames = 0; float c[4];

    sd.BufferCount = 2; sd.BufferDesc.Width = 960; sd.BufferDesc.Height = 540;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = wnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    CHECK_HR(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                           &sd, &sc, &dev, NULL, &ctx), "D3D11CreateDeviceAndSwapChain");
    CHECK_HR(IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb), "GetBuffer");
    CHECK_HR(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv), "CreateRenderTargetView");

    QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
    for (;;)
    {
        double el;
        if (!pump()) break;
        QueryPerformanceCounter(&t);
        el = (double)(t.QuadPart - t0.QuadPart) / f.QuadPart;
        if (el >= seconds) break;
        color(el * 2, c);
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        CHECK_HR(IDXGISwapChain_Present(sc, 1, 0), "Present");
        frames++;
    }
    PASS("d3d11 %u frames, %.0f fps", frames, frames / seconds);
}

static void run_d3d9(HWND wnd, double seconds)
{
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    IDirect3DDevice9 *dev; D3DPRESENT_PARAMETERS pp = {0};
    LARGE_INTEGER f, t0, t; unsigned frames = 0; float c[4];
    if (!d3d) FAIL("Direct3DCreate9");
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferWidth = 960; pp.BackBufferHeight = 540; pp.hDeviceWindow = wnd;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_ONE;
    CHECK_HR(IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, wnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev), "CreateDevice");
    QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t0);
    for (;;)
    {
        double el;
        if (!pump()) break;
        QueryPerformanceCounter(&t);
        el = (double)(t.QuadPart - t0.QuadPart) / f.QuadPart;
        if (el >= seconds) break;
        color(el * 2, c);
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET,
                               D3DCOLOR_COLORVALUE(c[0], c[1], c[2], 1.0f), 1.0f, 0);
        CHECK_HR(IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL), "Present");
        frames++;
    }
    PASS("d3d9 %u frames, %.0f fps", frames, frames / seconds);
}

int main(int argc, char **argv)
{
    const char *api = argc > 1 ? argv[1] : "d3d11";
    double seconds = argc > 2 ? atof(argv[2]) : 10.0;
    HWND wnd;
    probe_name = "present";
    wnd = probe_window(960, 540);
    SetWindowTextA(wnd, "Isthmus present probe");
    ShowWindow(wnd, SW_SHOWNORMAL);
    UpdateWindow(wnd);
    if (!strcmp(api, "d3d9")) run_d3d9(wnd, seconds);
    else run_d3d11(wnd, seconds);
    return 0;
}
