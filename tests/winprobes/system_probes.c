/* Non-graphics probes in one binary: `system_probes.exe <name>`.
 *   cpu     – CPUID; with ROSETTA_ADVERTISE_AVX=1 AVX/AVX2 must be visible
 *   net     – WinHTTP HTTPS GET (GnuTLS + sockets)
 *   xinput  – XInput loads and answers (no controller is fine)
 *   audio   – default render endpoint via MMDevice (CoreAudio driver)
 *   media   – Media Foundation decodes a generated WAV (GStreamer bundle)
 */
#define COBJMACROS
#define INITGUID
#include "probe.h"
#include <intrin.h>
#include <winhttp.h>
#include <xinput.h>
#include <mmdeviceapi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>

static void probe_cpu(void)
{
    int r[4];
    char want[16] = "";
    probe_name = "cpu";
    __cpuid(r, 1);
    int avx = (r[2] >> 28) & 1, osxsave = (r[2] >> 27) & 1;
    __cpuidex(r, 7, 0);
    int avx2 = (r[1] >> 5) & 1;
    GetEnvironmentVariableA("ROSETTA_ADVERTISE_AVX", want, sizeof(want));
    if (want[0] == '1' && !(avx && osxsave && avx2))
        FAIL("AVX requested but not advertised (avx=%d osxsave=%d avx2=%d); needs macOS 15+", avx, osxsave, avx2);
    PASS("avx=%d avx2=%d osxsave=%d", avx, avx2, osxsave);
}

static void probe_net(void)
{
    probe_name = "net";
    HINTERNET s = WinHttpOpen(L"IsthmusProbe/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    if (!s) FAIL("WinHttpOpen %lu", GetLastError());
    HINTERNET c = WinHttpConnect(s, L"example.com", INTERNET_DEFAULT_HTTPS_PORT, 0);
    HINTERNET r = c ? WinHttpOpenRequest(c, L"GET", L"/", NULL, NULL, NULL, WINHTTP_FLAG_SECURE) : NULL;
    if (!r) FAIL("WinHttpOpenRequest %lu", GetLastError());
    if (!WinHttpSendRequest(r, NULL, 0, NULL, 0, 0, 0) || !WinHttpReceiveResponse(r, NULL))
    {
        DWORD e = GetLastError();
        if (e == ERROR_WINHTTP_NAME_NOT_RESOLVED || e == ERROR_WINHTTP_CANNOT_CONNECT) SKIP("no network (%lu)", e);
        FAIL("HTTPS request failed %lu", e);
    }
    DWORD status = 0, len = sizeof(status);
    WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &len, NULL);
    if (status != 200) FAIL("HTTP status %lu", status);
    PASS("https status %lu", status);
}

static void probe_xinput(void)
{
    probe_name = "xinput";
    XINPUT_STATE st;
    DWORD r = XInputGetState(0, &st);
    if (r != ERROR_SUCCESS && r != ERROR_DEVICE_NOT_CONNECTED) FAIL("XInputGetState returned %lu", r);
    PASS("%s", r == ERROR_SUCCESS ? "controller 0 connected" : "no controller (ok)");
}

static void probe_audio(void)
{
    probe_name = "audio";
    IMMDeviceEnumerator *e; IMMDevice *d;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    CHECK_HR(CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&e), "MMDeviceEnumerator");
    HRESULT hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(e, eRender, eConsole, &d);
    if (hr == E_NOTFOUND) SKIP("no audio output device");
    CHECK_HR(hr, "GetDefaultAudioEndpoint");
    PASS("default render endpoint present");
}

static void write_wav(const char *path)
{
    FILE *f = fopen(path, "wb");
    const unsigned rate = 44100, samples = rate / 4;
    unsigned data = samples * 2, riff = 36 + data;
    unsigned short fmt[] = {1, 1};
    unsigned rate_bytes[] = {rate, rate * 2};
    unsigned short align[] = {2, 16};
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    unsigned sixteen = 16; fwrite(&sixteen, 4, 1, f); fwrite(fmt, 2, 2, f); fwrite(rate_bytes, 4, 2, f); fwrite(align, 2, 2, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
    for (unsigned i = 0; i < samples; i++) { short s = (short)((i % 100) * 300 - 15000); fwrite(&s, 2, 1, f); }
    fclose(f);
}

static void probe_media(void)
{
    char tmp[MAX_PATH], path[MAX_PATH]; WCHAR wpath[MAX_PATH];
    probe_name = "media";
    GetTempPathA(MAX_PATH, tmp);
    snprintf(path, sizeof(path), "%sisthmus-probe.wav", tmp);
    write_wav(path);
    MultiByteToWideChar(CP_ACP, 0, path, -1, wpath, MAX_PATH);
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    CHECK_HR(MFStartup(MF_VERSION, MFSTARTUP_FULL), "MFStartup");
    IMFSourceReader *reader;
    CHECK_HR(MFCreateSourceReaderFromURL(wpath, NULL, &reader), "MFCreateSourceReaderFromURL");
    DWORD stream, flags; LONGLONG ts; IMFSample *sample = NULL;
    CHECK_HR(IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &stream, &flags, &ts, &sample), "ReadSample");
    if (!sample) FAIL("no sample decoded (flags 0x%lx)", flags);
    DWORD len = 0; IMFSample_GetTotalLength(sample, &len);
    DeleteFileA(path);
    PASS("decoded %lu bytes of PCM", len);
}

int main(int argc, char **argv)
{
    const char *which = argc > 1 ? argv[1] : "";
    if (!strcmp(which, "cpu")) probe_cpu();
    if (!strcmp(which, "net")) probe_net();
    if (!strcmp(which, "xinput")) probe_xinput();
    if (!strcmp(which, "audio")) probe_audio();
    if (!strcmp(which, "media")) probe_media();
    probe_name = "system";
    FAIL("usage: system_probes.exe cpu|net|xinput|audio|media");
    return 1;
}
