/* Memory operations for the runtime's memory trace to record (FINEWINE_MEMORY_TRACE=<folder>).
 *
 * Reserves and commits 32 MB, writes it, resets it, decommits it, releases it; maps and unmaps a
 * 16 MB section; and decommits one hundred single 4K pages out of a 4 MB block, the kind of
 * hand-back that cannot free memory where the host's pages are 16K. The test script then looks
 * for each in "<program>-<pid>.log", with this program named among the callers.
 *
 * Prints "memtrace: ok" when every call succeeded.
 * Build: x86_64-w64-mingw32-clang -O1 -o memtrace.exe memtrace.c */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define BIG   (32 * 1024 * 1024)
#define SMALL (4 * 1024 * 1024)

int main( void )
{
    char *big, *small, *view;
    HANDLE section;
    int i, ok = 1;

    big = VirtualAlloc( NULL, BIG, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    if (!big) { printf( "memtrace: FAILED to allocate\n" ); return 1; }
    memset( big, 0x5a, BIG );
    ok &= VirtualAlloc( big, BIG, MEM_RESET, PAGE_READWRITE ) != NULL;
    ok &= VirtualFree( big, BIG, MEM_DECOMMIT );
    ok &= VirtualAlloc( big, BIG, MEM_COMMIT, PAGE_READWRITE ) != NULL;
    ok &= VirtualFree( big, 0, MEM_RELEASE );

    section = CreateFileMappingA( INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, BIG / 2, NULL );
    view = section ? MapViewOfFile( section, FILE_MAP_WRITE, 0, 0, 0 ) : NULL;
    ok &= view != NULL;
    if (view) { memset( view, 1, BIG / 2 ); ok &= UnmapViewOfFile( view ); }
    if (section) CloseHandle( section );

    small = VirtualAlloc( NULL, SMALL, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    ok &= small != NULL;
    if (small)
    {
        memset( small, 0x33, SMALL );
        for (i = 0; i < 100; i++) ok &= VirtualFree( small + i * 2 * 4096, 4096, MEM_DECOMMIT );
    }
    Sleep( 5200 );  /* past the trace's five-second totals interval */
    if (small) ok &= VirtualFree( small, 0, MEM_RELEASE );
    printf( ok ? "memtrace: ok\n" : "memtrace: FAILED, a call failed\n" );
    return 0;
}
