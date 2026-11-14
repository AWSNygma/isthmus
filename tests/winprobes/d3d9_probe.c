/* Direct3D 9: device on a hidden window, clear, read back. Older games. */
#define COBJMACROS
#include "probe.h"
#include <d3d9.h>

int main(void)
{
    probe_name = "d3d9";
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) FAIL("Direct3DCreate9 returned NULL");
    D3DADAPTER_IDENTIFIER9 id;
    CHECK_HR(IDirect3D9_GetAdapterIdentifier(d3d, 0, 0, &id), "GetAdapterIdentifier");

    HWND wnd = probe_window(64, 64);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.BackBufferFormat = D3DFMT_A8R8G8B8;
    pp.BackBufferWidth = pp.BackBufferHeight = 64; pp.hDeviceWindow = wnd;
    IDirect3DDevice9 *dev;
    CHECK_HR(IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, wnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev), "CreateDevice");

    CHECK_HR(IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(51, 153, 230), 1.0f, 0), "Clear");
    IDirect3DSurface9 *bb, *sys;
    CHECK_HR(IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &bb), "GetBackBuffer");
    CHECK_HR(IDirect3DDevice9_CreateOffscreenPlainSurface(dev, 64, 64, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, &sys, NULL), "CreateOffscreenPlainSurface");
    CHECK_HR(IDirect3DDevice9_GetRenderTargetData(dev, bb, sys), "GetRenderTargetData");
    D3DLOCKED_RECT lr;
    CHECK_HR(IDirect3DSurface9_LockRect(sys, &lr, NULL, D3DLOCK_READONLY), "LockRect");
    unsigned int argb = ((unsigned int *)((char *)lr.pBits + 32 * lr.Pitch))[32];
    IDirect3DSurface9_UnlockRect(sys);
    /* A8R8G8B8 in memory is BGRA; swap to RGBA for the shared helper. */
    unsigned int rgba = ((argb >> 16) & 0xff) | (argb & 0xff00) | ((argb & 0xff) << 16);
    if (!color_close(rgba, 51, 153, 230)) FAIL("pixel 0x%08x", argb);
    PASS("adapter \"%s\"", id.Description);
    return 0;
}
