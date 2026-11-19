/* A thread spinning in a tight loop can be suspended and asked for its registers.
 *
 * FEX lets another thread suspend an emulated one only where the generated code checks for it:
 * at the start of each block and on unconditional jumps back. A spin loop such as
 * "while (!flag) count++;" loops back through a conditional jump, so it never looked, and
 * SuspendThread + GetThreadContext on it waited forever. Garbage collectors stop every thread
 * this way: Genshin Impact froze on its warning screen, one thread spinning in emulated code,
 * another waiting in GetThreadContext for it.
 *
 * Two loops: one branching on the zero flag (je), one on the carry flag (jb, the flag FEX keeps
 * inverted inside its code). Each is suspended ROUNDS times and its registers read; the
 * instruction pointer must be in the loop, and the loop must go on counting after each resume and
 * stop when told (a wrongly restored flag would end it early or never). A watchdog ends the
 * program if a round takes more than 5 seconds.
 *
 * Prints "suspend-spin: ok <rounds>" on success.
 * Build: x86_64-w64-mingw32-clang -O1 -o suspend-spin.exe suspend-spin.c */
#include <windows.h>
#include <stdio.h>

#define ROUNDS 50

static volatile LONG stop;
static volatile LONG64 count;

static DWORD WINAPI zero_flag_loop( void *arg )
{
    while (!stop) count++;
    return 0;
}

static DWORD WINAPI carry_flag_loop( void *arg )
{
    __asm__ volatile( "1: incq %0\n\t"
                      "cmpl $1, %1\n\t"
                      "jb 1b"
                      : "+m" (count) : "m" (stop) : "cc" );
    return 0;
}

static DWORD WINAPI watchdog( void *arg )
{
    if (WaitForSingleObject( (HANDLE)arg, 5000 ) == WAIT_TIMEOUT)
    {
        printf( "suspend-spin: FAILED, suspending a spinning thread did not return in 5 seconds\n" );
        fflush( stdout );
        TerminateProcess( GetCurrentProcess(), 1 );
    }
    return 0;
}

static int run( const char *name, LPTHREAD_START_ROUTINE loop )
{
    HANDLE thread, done, dog;
    CONTEXT ctx;
    LONG64 before;
    int i, outside = 0;
    char *start = (char *)loop;

    stop = 0;
    count = 0;
    thread = CreateThread( NULL, 0, loop, NULL, 0, NULL );
    while (count < 1000) Sleep( 1 );

    for (i = 0; i < ROUNDS; i++)
    {
        done = CreateEventW( NULL, TRUE, FALSE, NULL );
        dog = CreateThread( NULL, 0, watchdog, done, 0, NULL );

        if (SuspendThread( thread ) == (DWORD)-1)
        {
            printf( "suspend-spin: FAILED, %s: SuspendThread error %lu\n", name, GetLastError() );
            return 0;
        }
        memset( &ctx, 0, sizeof(ctx) );
        ctx.ContextFlags = CONTEXT_FULL;
        if (!GetThreadContext( thread, &ctx ))
        {
            printf( "suspend-spin: FAILED, %s: GetThreadContext error %lu\n", name, GetLastError() );
            return 0;
        }
        if ((char *)ctx.Rip < start || (char *)ctx.Rip >= start + 64) outside++;
        before = count;
        ResumeThread( thread );

        SetEvent( done );
        WaitForSingleObject( dog, INFINITE );
        CloseHandle( dog );
        CloseHandle( done );

        for (int wait = 0; count == before; wait++)
        {
            if (wait == 5000)
            {
                printf( "suspend-spin: FAILED, %s: the loop stopped after round %d\n", name, i + 1 );
                return 0;
            }
            Sleep( 1 );
        }
    }

    stop = 1;
    if (WaitForSingleObject( thread, 5000 ) != WAIT_OBJECT_0)
    {
        printf( "suspend-spin: FAILED, %s: the loop did not stop when told\n", name );
        return 0;
    }
    CloseHandle( thread );
    if (outside > ROUNDS / 2)
    {
        printf( "suspend-spin: FAILED, %s: %d of %d contexts were outside the loop\n", name, outside, ROUNDS );
        return 0;
    }
    return 1;
}

int main( void )
{
    if (run( "je loop", zero_flag_loop ) && run( "jb loop", carry_flag_loop ))
        printf( "suspend-spin: ok %d\n", ROUNDS );
    return 0;
}
