/* x64-stress.c: an x64 Windows program that exercises what games lean on, run under FEX by
 * scripts/test-finewine-runtime.sh. Each line it prints is one check; the last line is
 * "x64-stress: ok" only if all of them passed. */
#include <windows.h>
#include <stdio.h>
#include <math.h>

static volatile LONG counter;
static HANDLE start_event;
static CRITICAL_SECTION cs;
static int failures;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", what, ok ? "ok" : "FAILED");
    if (!ok) failures++;
}

static DWORD WINAPI worker(void *arg)
{
    WaitForSingleObject(start_event, INFINITE);
    for (int i = 0; i < 20000; i++)
    {
        InterlockedIncrement(&counter);
        if (!(i & 1023)) { EnterCriticalSection(&cs); Sleep(0); LeaveCriticalSection(&cs); }
    }
    return 0;
}

static LONG handled;
static LONG CALLBACK veh(EXCEPTION_POINTERS *info)
{
    if (info->ExceptionRecord->ExceptionCode == 0xE0000001) { handled++; return EXCEPTION_CONTINUE_EXECUTION; }
    return EXCEPTION_CONTINUE_SEARCH;
}

typedef int (*fn_t)(void);

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);   /* keep earlier results if a later check crashes */

    /* threads, events, critical sections, interlocked operations */
    HANDLE threads[8];
    InitializeCriticalSection(&cs);
    start_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    for (int i = 0; i < 8; i++) threads[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    SetEvent(start_event);
    DWORD w = WaitForMultipleObjects(8, threads, TRUE, 30000);
    check(w == WAIT_OBJECT_0 && counter == 8 * 20000, "8 threads, events and locks");

    /* floating point and SSE */
    double acc = 0;
    for (int i = 1; i <= 100000; i++) acc += sqrt((double)i) * sin(i * 0.001);
    check(fabs(acc - -253759.96395) < 0.001, "floating point loop");   /* value computed natively */

    /* exceptions through a vectored handler */
    AddVectoredExceptionHandler(1, veh);
    RaiseException(0xE0000001, 0, 0, NULL);
    check(handled == 1, "raise and continue an exception");

    /* generated x64 code in a writable and executable page, then rewritten */
    unsigned char *code = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    static const unsigned char ret42[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 }; /* mov eax,42; ret */
    memcpy(code, ret42, sizeof(ret42));
    int first = ((fn_t)code)();
    code[1] = 0x70;                                                                /* mov eax,112 */
    FlushInstructionCache(GetCurrentProcess(), code, sizeof(ret42));
    int second = ((fn_t)code)();
    check(first == 42 && second == 112, "generated x64 code, rewritten in place");

    /* timers */
    LARGE_INTEGER f, a, b;
    QueryPerformanceFrequency(&f); QueryPerformanceCounter(&a); Sleep(20); QueryPerformanceCounter(&b);
    double ms = (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)f.QuadPart;
    check(ms > 15 && ms < 500, "performance counter across Sleep(20)");

    /* heap and file round trip */
    char path[MAX_PATH], tmp[MAX_PATH], buf[64] = {0};
    GetTempPathA(sizeof(tmp), tmp); GetTempFileNameA(tmp, "fw", 0, path);
    HANDLE file = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    DWORD n = 0;
    WriteFile(file, "finewine", 8, &n, NULL); SetFilePointer(file, 0, NULL, FILE_BEGIN);
    ReadFile(file, buf, sizeof(buf) - 1, &n, NULL); CloseHandle(file); DeleteFileA(path);
    check(n == 8 && !strcmp(buf, "finewine"), "file write and read back");

    /* the Windows shared data page, read directly the way some programs and anti-cheats do */
    SYSTEM_INFO si; GetNativeSystemInfo(&si);
    DWORD major = *(volatile DWORD *)0x7ffe026c;   /* KUSER_SHARED_DATA.NtMajorVersion */
    check(major >= 6 && major <= 11, "direct read of the shared data page at 0x7ffe0000");

    printf(failures ? "x64-stress: %d FAILED\n" : "x64-stress: ok\n", failures);
    return failures;
}
