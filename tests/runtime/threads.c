/* Creating threads stays fast while many of them are alive.
 *
 * Every thread of an x64 program gets an emulator stack "above 4 GB", and Wine looked for room
 * for it by trying one 64K step after another, past everything macOS itself has mapped there.
 * Each new thread searched further than the one before, seconds per thread once a game had
 * many, while every other memory call of the program waited. This creates THREADS threads that
 * stay alive, and prints how long each batch took and the whole.
 *
 * Prints "threads: ok <ms>" when every thread started, ran and the slowest batch stayed under
 * the limit. Build: x86_64-w64-mingw32-clang -O1 -o threads.exe threads.c */
#include <windows.h>
#include <stdio.h>

#define THREADS 300
#define BATCH   50
#define SLOWEST_BATCH_MS 2000.0

static HANDLE go;
static LONG started;

static DWORD WINAPI worker( void *arg )
{
    InterlockedIncrement( &started );
    WaitForSingleObject( go, INFINITE );
    return 0;
}

int main( void )
{
    static HANDLE threads[THREADS];
    LARGE_INTEGER freq, t0, t1, b0;
    double slowest = 0, total;
    int i, made = 0;

    go = CreateEventW( NULL, TRUE, FALSE, NULL );
    QueryPerformanceFrequency( &freq );
    QueryPerformanceCounter( &t0 );
    b0 = t0;
    for (i = 0; i < THREADS; i++)
    {
        if (!(threads[i] = CreateThread( NULL, 0, worker, NULL, 0, NULL )))
        {
            printf( "threads: CreateThread %d failed, error %lu\n", i, GetLastError() );
            break;
        }
        made++;
        if ((i + 1) % BATCH == 0)
        {
            LARGE_INTEGER now;
            double ms;
            QueryPerformanceCounter( &now );
            ms = (now.QuadPart - b0.QuadPart) * 1000.0 / freq.QuadPart;
            printf( "threads %3d-%3d: %8.1f ms\n", i + 2 - BATCH, i + 1, ms );
            if (ms > slowest) slowest = ms;
            b0 = now;
        }
    }
    QueryPerformanceCounter( &t1 );
    total = (t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
    for (i = 0; i < 1000 && started < made; i++) Sleep( 10 );
    SetEvent( go );
    WaitForMultipleObjects( made < MAXIMUM_WAIT_OBJECTS ? made : MAXIMUM_WAIT_OBJECTS, threads, TRUE, 10000 );

    if (made == THREADS && started == made && slowest < SLOWEST_BATCH_MS)
        printf( "threads: ok %.0f\n", total );
    else
        printf( "threads: FAILED made %d started %ld slowest batch %.0f ms, total %.0f ms\n",
                made, started, slowest, total );
    return 0;
}
