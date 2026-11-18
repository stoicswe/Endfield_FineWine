/* x64 code that is rewritten, freed and replaced must never run in its old form, on any thread.
 *
 * FEX keeps, for each thread, a record of the translated blocks that thread has cached, so that
 * when a page of guest code changes it can drop exactly those. FineWine has a compact form of
 * the record (FEX_COMPACTBLOCKRECORDS=1, patches/fex/0008); this checks that invalidation still
 * finds every block, with the switch on or off.
 *
 * 8 threads each call 600 small functions spread over 150 pages, some of them starting on one
 * page and ending on the next. Then the functions are changed in three ways and called again:
 * rewritten in place, protected and rewritten, and freed and allocated again at the same address.
 * Prints "code-rewrite: ok <calls>". */
#include <windows.h>
#include <stdio.h>

#define THREADS 8
#define PAGES 150
#define PER_PAGE 4
static unsigned char *code;
static volatile LONG generation, bad, calls;
static HANDLE go[THREADS], done[THREADS];

/* function k of page p; the last one of a page straddles the page boundary */
static unsigned char *fn_at(int p, int k)
{
    return code + (size_t)p * 4096 + (k == PER_PAGE - 1 ? 4096 - 3 : 64 + k * 256);
}

static void write_all(unsigned gen)
{
    for (int p = 0; p < PAGES; p++)
        for (int k = 0; k < PER_PAGE; k++)
        {
            unsigned char *q = fn_at(p, k);
            q[0] = 0xb8; *(unsigned *)(q + 1) = gen * 1000000u + p * 10 + k; q[5] = 0xc3;   /* mov eax, imm; ret */
        }
    FlushInstructionCache(GetCurrentProcess(), code, (PAGES + 1) * 4096);
}

static DWORD WINAPI worker(void *arg)
{
    for (;;)
    {
        WaitForSingleObject(go[(size_t)arg], INFINITE);
        unsigned gen = generation;
        if (!gen) return 0;
        for (int round = 0; round < 3; round++)
            for (int p = 0; p < PAGES; p++)
                for (int k = 0; k < PER_PAGE; k++)
                {
                    if (((unsigned (*)(void))fn_at(p, k))() != gen * 1000000u + p * 10 + k) InterlockedIncrement(&bad);
                    InterlockedIncrement(&calls);
                }
        SetEvent(done[(size_t)arg]);
    }
}

static void run(unsigned gen)
{
    generation = gen;
    for (int i = 0; i < THREADS; i++) SetEvent(go[i]);
    WaitForMultipleObjects(THREADS, done, TRUE, INFINITE);
}

int main(void)
{
    HANDLE threads[THREADS];
    SIZE_T size = (PAGES + 1) * 4096;
    DWORD old;

    code = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    for (size_t i = 0; i < THREADS; i++)
    {
        go[i] = CreateEventA(NULL, FALSE, FALSE, NULL);
        done[i] = CreateEventA(NULL, FALSE, FALSE, NULL);
        threads[i] = CreateThread(NULL, 0, worker, (void *)i, 0, NULL);
    }
    write_all(1); run(1);
    write_all(2); run(2);                                   /* rewritten in place */
    VirtualProtect(code, size, PAGE_EXECUTE_READ, &old); run(2);
    VirtualProtect(code, size, PAGE_READWRITE, &old);
    write_all(3);
    VirtualProtect(code, size, PAGE_EXECUTE_READ, &old); run(3);   /* protected, rewritten, protected */
    {
        unsigned char *again;
        VirtualFree(code, 0, MEM_RELEASE);
        again = VirtualAlloc(code, size, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
        if (again != code) { printf("code-rewrite: FAIL could not allocate at the same address again\n"); return 1; }
        write_all(4); run(4);                               /* freed and replaced */
    }
    generation = 0;
    for (int i = 0; i < THREADS; i++) SetEvent(go[i]);
    WaitForMultipleObjects(THREADS, threads, TRUE, 5000);
    if (bad) { printf("code-rewrite: FAIL %ld of %ld calls ran old code\n", bad, calls); return 1; }
    printf("code-rewrite: ok %ld\n", calls);
    return 0;
}
