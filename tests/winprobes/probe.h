/* Shared helpers for Isthmus Windows probes.
 * Each probe prints one line: "PASS <name> <detail>" or "FAIL <name> <reason>"
 * and exits 0 on pass, 1 on fail, 77 when the feature is unavailable (skip). */
#ifndef ISTHMUS_PROBE_H
#define ISTHMUS_PROBE_H
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <windows.h>

static const char *probe_name = "probe";

static void probe_result(int code, const char *fmt, ...)
{
    va_list ap;
    const char *tag = code == 0 ? "PASS" : code == 77 ? "SKIP" : "FAIL";
    printf("%s %s ", tag, probe_name);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
    exit(code);
}

#define PASS(...) probe_result(0, __VA_ARGS__)
#define FAIL(...) probe_result(1, __VA_ARGS__)
#define SKIP(...) probe_result(77, __VA_ARGS__)
#define CHECK_HR(expr, what) do { HRESULT hr_ = (expr); if (FAILED(hr_)) FAIL("%s failed: 0x%08lx", what, (unsigned long)hr_); } while (0)

/* Pixel comparison with tolerance for format conversion. */
static int color_close(unsigned int rgba, unsigned r, unsigned g, unsigned b)
{
    int dr = (int)(rgba & 0xff) - (int)r, dg = (int)((rgba >> 8) & 0xff) - (int)g, db = (int)((rgba >> 16) & 0xff) - (int)b;
    return abs(dr) <= 3 && abs(dg) <= 3 && abs(db) <= 3;
}

static HWND probe_window(int w, int h)
{
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "IsthmusProbe";
    RegisterClassA(&wc);
    return CreateWindowA("IsthmusProbe", "Isthmus probe", WS_OVERLAPPEDWINDOW, 0, 0, w, h, NULL, NULL, wc.hInstance, NULL);
}
#endif
