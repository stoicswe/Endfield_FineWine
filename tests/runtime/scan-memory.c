/* A program that reads through all of its own committed memory, as anti-cheat and other scanners
 * do, must not grow by hundreds of megabytes for each thread.
 *
 * FEX keeps lookup tables for each emulated thread in a 272 MB reservation that it commits as
 * it is used. Under Wine it used to commit the whole reservation at the first use. Committed
 * memory can be read, and macOS has no shared zero page: a page that is only ever read still
 * becomes real memory. Arknights: Endfield reads through its memory and grew by about 100 MB a
 * second, to 40 GB in seven minutes. patches/fex/0005 commits 64 KB at a time instead.
 *
 * Run with FINEWINE_MEMORY_TRACE set; the test script reads the footprint from the log (about 5 GB
 * before the fix, about 370 MB after). Prints "scan-memory: ok <MB read>". */
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
        /* writable memory only: the read-only tables Wine keeps for the whole process are not the point */
        if (info.State == MEM_COMMIT && info.Type == MEM_PRIVATE && !(info.Protect & PAGE_GUARD)
            && (info.Protect & (PAGE_READWRITE | PAGE_EXECUTE_READWRITE)))
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
