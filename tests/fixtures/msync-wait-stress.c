/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* msync waiter-leak and wake-latency stress test (manual; run under a built engine).
 *
 * Build:  x86_64-w64-mingw32-gcc -O2 -o msync-wait-stress.exe tests/fixtures/msync-wait-stress.c
 * Run:    WINEMSYNC=1 WINEPREFIX=<scratch prefix> <engine>/bin/wine msync-wait-stress.exe SECS LOAD MSG ALERTABLE
 *         e.g. "20 1 0 0" (event probe) or "20 1 1 1" (alertable message-queue probe).
 * Watch the wineserver's memory and its "msync: warn: node memory pool exhausted" output: before
 * patches/stage1-macos/0006 the load below grows the wineserver by about 1 MB/s.
 *
 * Load: a worker sets an auto-reset event in a tight loop while the main thread waits on
 * {quit, work} (Highball's msyncleak scenario: lost races leak wineserver nodes).
 * Probe: a pinger sets an event every 2 ms; a waiter blocked in WaitForMultipleObjects on
 * {quit, ping} records how late it wakes. Prints iterations and latency percentiles. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static HANDLE quit, work, ping;
static volatile LONG stop;
static LARGE_INTEGER freq;
static volatile LONGLONG ping_time;
#define MAXS 20000
static double lat[MAXS]; static int nlat;

static DWORD WINAPI worker(void *p) { while (!stop) SetEvent(work); return 0; }

static int msgprobe, alertable; static DWORD waiter_tid;
static DWORD WINAPI pinger(void *p)
{
    LARGE_INTEGER t;
    while (!stop)
    {
        Sleep(2); QueryPerformanceCounter(&t); ping_time = t.QuadPart;
        if (msgprobe) PostThreadMessageA(waiter_tid, WM_USER, 0, 0); else SetEvent(ping);
    }
    return 0;
}

/* Message probe: like a game's input loop, block in MsgWaitForMultipleObjects on {quit} plus
   the thread's message queue, then drain it with PeekMessage. */
static DWORD WINAPI msgwaiter(void *p)
{
    MSG msg; LARGE_INTEGER t;
    PeekMessageA(&msg, NULL, 0, 0, PM_NOREMOVE);  /* create the queue */
    SetEvent(ping);                                /* tell main the queue exists */
    for (;;)
    {
        DWORD r = MsgWaitForMultipleObjectsEx(1, &quit, INFINITE, QS_ALLINPUT, alertable ? MWMO_ALERTABLE : 0);
        if (r == WAIT_OBJECT_0) break;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
        {
            QueryPerformanceCounter(&t);
            if (msg.message == WM_USER && nlat < MAXS) lat[nlat++] = (t.QuadPart - ping_time) * 1000.0 / freq.QuadPart;
        }
    }
    return 0;
}

static DWORD WINAPI waiter(void *p)
{
    HANDLE h[2] = { quit, ping };
    LARGE_INTEGER t;
    for (;;)
    {
        DWORD r = WaitForMultipleObjectsEx(2, h, FALSE, INFINITE, alertable);
        if (r != WAIT_OBJECT_0 + 1) break;
        QueryPerformanceCounter(&t);
        if (nlat < MAXS) lat[nlat++] = (t.QuadPart - ping_time) * 1000.0 / freq.QuadPart;
    }
    return 0;
}

static int cmp(const void *a, const void *b) { double x = *(double*)a, y = *(double*)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 20, load = argc > 2 ? atoi(argv[2]) : 1;
    msgprobe = argc > 3 ? atoi(argv[3]) : 0;
    alertable = argc > 4 ? atoi(argv[4]) : 0;
    long long iters = 0; DWORD start;
    HANDLE th[3]; int n = 0;
    QueryPerformanceFrequency(&freq);
    quit = CreateEventA(NULL, TRUE, FALSE, NULL);
    work = CreateEventA(NULL, FALSE, FALSE, NULL);
    ping = CreateEventA(NULL, FALSE, FALSE, NULL);
    if (load) th[n++] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    if (msgprobe)
    {
        th[n++] = CreateThread(NULL, 0, msgwaiter, NULL, 0, &waiter_tid);
        WaitForSingleObject(ping, INFINITE);
    }
    else th[n++] = CreateThread(NULL, 0, waiter, NULL, 0, NULL);
    th[n++] = CreateThread(NULL, 0, pinger, NULL, 0, NULL);
    start = GetTickCount();
    if (load)
    {
        HANDLE h[2] = { quit, work };
        while (GetTickCount() - start < (DWORD)secs * 1000)
            if (WaitForMultipleObjects(2, h, FALSE, 100) == WAIT_OBJECT_0 + 1) iters++;
    }
    else Sleep(secs * 1000);
    stop = 1; SetEvent(quit);
    WaitForMultipleObjects(n, th, TRUE, 5000);
    qsort(lat, nlat, sizeof(double), cmp);
    printf("alertable=%d probe=%s load=%d secs=%d load_iters=%lld pings=%d", alertable, msgprobe ? "msg" : "event", load, secs, iters, nlat);
    if (nlat) printf(" lat_ms p50=%.3f p90=%.3f p99=%.3f max=%.3f", lat[nlat/2], lat[nlat*9/10], lat[nlat*99/100], lat[nlat-1]);
    printf("\n");
    return 0;
}
