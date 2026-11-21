/* audio-follow.c: plays silence through the default output device for a few seconds and
 * reports how much the device took in each second.
 *
 * Used to check that a playback stream survives being given a new audio unit, which is what
 * happens when the Mac's output device changes (headphones connected while a game runs,
 * runtime patch 0041). With FINEWINE_AUDIO_REOPEN_AFTER=2 the Core Audio driver re-opens the
 * stream's device two seconds in; the device must go on taking audio at the same rate
 * afterwards. Nothing is heard: the buffers are marked silent.
 *
 * Prints "audio-follow: ok rate <Hz> seconds <n> per-second <frames> <frames> ..." or what
 * went wrong.
 * Build: x86_64-w64-mingw32-clang -O1 -o audio-follow.exe audio-follow.c -lole32 */
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(hr, what) do { if (FAILED(hr)) { printf("audio-follow: %s failed 0x%08lx\n", what, (unsigned long)(hr)); return 1; } } while (0)

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 5, second;
    IMMDeviceEnumerator *enumerator = NULL;
    IMMDevice *device = NULL;
    IAudioClient *client = NULL;
    IAudioRenderClient *render = NULL;
    WAVEFORMATEX *format = NULL;
    UINT32 buffer_frames = 0, padding = 0;
    unsigned long long written = 0, consumed_before = 0;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED); CHECK(hr, "CoInitializeEx");
    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&enumerator);
    CHECK(hr, "creating the device enumerator");
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &device);
    if (hr == E_NOTFOUND || hr == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) { printf("audio-follow: no output device\n"); return 2; }
    CHECK(hr, "getting the default output device");
    hr = IMMDevice_Activate(device, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client); CHECK(hr, "activating the audio client");
    hr = IAudioClient_GetMixFormat(client, &format); CHECK(hr, "GetMixFormat");
    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0, 5000000 /* half a second */, 0, format, NULL);
    CHECK(hr, "Initialize");
    hr = IAudioClient_GetBufferSize(client, &buffer_frames); CHECK(hr, "GetBufferSize");
    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render); CHECK(hr, "GetService");
    hr = IAudioClient_Start(client); CHECK(hr, "Start");

    printf("audio-follow: ok rate %lu seconds %d per-second", (unsigned long)format->nSamplesPerSec, seconds);
    for (second = 0; second < seconds; second++)
    {
        DWORD end = GetTickCount() + 1000;
        unsigned long long consumed;
        while (GetTickCount() < end)
        {
            BYTE *data;
            UINT32 room;
            hr = IAudioClient_GetCurrentPadding(client, &padding); CHECK(hr, "\nGetCurrentPadding");
            room = buffer_frames - padding;
            if (room)
            {
                hr = IAudioRenderClient_GetBuffer(render, room, &data); CHECK(hr, "\nGetBuffer");
                hr = IAudioRenderClient_ReleaseBuffer(render, room, AUDCLNT_BUFFERFLAGS_SILENT); CHECK(hr, "\nReleaseBuffer");
                written += room;
            }
            Sleep(10);
        }
        hr = IAudioClient_GetCurrentPadding(client, &padding); CHECK(hr, "\nGetCurrentPadding");
        consumed = written - padding;
        printf(" %llu", consumed - consumed_before);
        consumed_before = consumed;
    }
    printf("\n");
    IAudioClient_Stop(client);
    return 0;
}
