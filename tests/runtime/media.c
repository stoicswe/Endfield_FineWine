/* Reads a media file the way a game does, through Media Foundation's source reader, and asks
 * for decoded audio and decoded video. With the runtime's GStreamer and macOS's own decoders
 * behind it (runtime patch 0060) an MP4 with H.264 video and AAC audio must give both.
 *
 * Usage: media.exe <file>. Prints "media: audio=<bytes of the first decoded audio sample>
 * video=<width>x<height> <bytes of the first decoded frame>", with 0 for a stream that is
 * missing or could not be decoded. */
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>

static DWORD first_sample_size(IMFSourceReader *reader, DWORD stream)
{
    DWORD total = 0, flags = 0, actual;
    IMFSample *sample = NULL;
    LONGLONG time;
    int tries;

    for (tries = 0; tries < 50 && !sample; tries++)
    {
        if (FAILED(IMFSourceReader_ReadSample(reader, stream, 0, &actual, &flags, &time, &sample))) return 0;
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    if (!sample) return 0;
    IMFSample_GetTotalLength(sample, &total);
    IMFSample_Release(sample);
    return total;
}

int wmain(int argc, WCHAR **argv)
{
    IMFSourceReader *reader = NULL;
    IMFMediaType *type = NULL;
    DWORD audio = 0, video = 0;
    UINT64 size = 0;
    HRESULT hr;

    if (argc < 2) return 2;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr = MFCreateSourceReaderFromURL(argv[1], NULL, &reader)))
    {
        printf("media: FAILED to open the file (%#lx)\n", hr);
        return 1;
    }

    MFCreateMediaType(&type);
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
    if (SUCCEEDED(IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, type)))
        audio = first_sample_size(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    IMFMediaType_Release(type);

    MFCreateMediaType(&type);
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, &MFVideoFormat_NV12);
    if (SUCCEEDED(IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type)))
    {
        IMFMediaType *current = NULL;
        video = first_sample_size(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM);
        if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &current)))
        {
            IMFMediaType_GetUINT64(current, &MF_MT_FRAME_SIZE, &size);
            IMFMediaType_Release(current);
        }
    }
    IMFMediaType_Release(type);

    printf("media: audio=%lu video=%ux%u %lu\n", audio, (unsigned)(size >> 32), (unsigned)size, video);
    IMFSourceReader_Release(reader);
    MFShutdown();
    return 0;
}
