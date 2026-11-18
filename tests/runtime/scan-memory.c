/* A program that reads through all of its own committed memory, as anti-cheat and other scanners
 * do, must not grow by gigabytes.
 *
 * macOS has no shared zero page: a page that is only ever read still becomes real memory. Two
 * things were committed in full and nearly unused, so reading through them was expensive:
 *  - FEX's lookup tables, 272 MB for each emulated thread (patches/fex/0005 commits them 64 KB
 *    at a time, as FEX does on Windows);
 *  - Wine's ARM64EC code map, 4 GB for the process (runtime patch 0035 commits a page of it
 *    when it is first read).
 * Arknights: Endfield reads through its memory and grew to 40 GB in seven minutes.
 *
 * Run with FINEWINE_MEMORY_TRACE set; the test script reads the footprint from the log: about
 * 9 GB with neither fix, 370 MB with both. Prints "scan-memory: ok <MB read>". */
#include <windows.h>
#include <stdio.h>

#define THREADS 16
static HANDLE ready;

static DWORD WINAPI worker(void *arg)
{
    SetEvent(ready);
    Sleep(INFINITE);
    return 0;
}

int main(void)
{
    MEMORY_BASIC_INFORMATION info;
    unsigned long long total = 0;
    volatile char sum = 0;
    char *p = NULL;

    ready = CreateEventA(NULL, FALSE, FALSE, NULL);
    for (int i = 0; i < THREADS; i++)
    {
        CreateThread(NULL, 0, worker, NULL, 0, NULL);
        WaitForSingleObject(ready, INFINITE);
    }
    while (VirtualQuery(p, &info, sizeof(info)) == sizeof(info))
    {
        if (info.State == MEM_COMMIT && info.Type == MEM_PRIVATE && !(info.Protect & (PAGE_GUARD | PAGE_NOACCESS))
            && (info.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE)))
        {
            for (SIZE_T i = 0; i < info.RegionSize; i += 4096) sum += ((char *)info.BaseAddress)[i];
            total += info.RegionSize;
        }
        p = (char *)info.BaseAddress + info.RegionSize;
    }
    /* something large, so that the log gets its totals line with the footprint */
    Sleep(5200);
    VirtualFree(VirtualAlloc(NULL, 16 << 20, MEM_RESERVE, PAGE_READWRITE), 0, MEM_RELEASE);
    printf("scan-memory: ok %llu\n", total >> 20);
    return 0;
}
