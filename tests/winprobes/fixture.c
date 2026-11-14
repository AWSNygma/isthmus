/* Unit-test fixture for IsthmusKit's PE parser: imports d3d11 + dxgi,
 * carries one 32x32 icon. Built once and committed under Tests/. */
#include <windows.h>
#include <d3d11.h>
int main(void) { return D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_NULL, NULL, 0, NULL, 0, D3D11_SDK_VERSION, NULL, NULL, NULL) == S_OK ? 0 : 1; }
