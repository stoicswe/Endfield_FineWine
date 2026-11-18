/* Many x64 threads jump into newly allocated code at the same moment.
 *
 * Wine's ARM64EC code map says which pages hold ARM64EC code; FEX reads it at every indirect
 * jump. On macOS FineWine commits a page of the map the first time it is read (runtime patch
 * 0035). When several threads read the same uncommitted page at once, each one faults; the
 * first commits the page and the others must simply run their read again. The first version of
 * the patch treated the others as real access violations and the program crashed.
 *
 * Each round puts a small function in a fresh part of the address space (a part whose page of
 * the map has not been read yet) and lets 16 threads call it together.
 * Prints "code-map-race: ok <rounds>". */
#include <windows.h>
#include <stdio.h>

#define THREADS 16
#define ROUNDS 24
static HANDLE go, done[THREADS];
static unsigned (*volatile fn)(void);
static volatile LONG sum, quit;

static volatile LONG round_number;

static DWORD WINAPI worker(void *arg)
{
    LONG seen = 0;

    for (;;)
    {
        WaitForSingleObject(go, INFINITE);
        if (quit) return 0;
        if (round_number == seen) { Sleep(0); continue; }   /* still the round this thread has done */
        seen = round_number;
        InterlockedExchangeAdd(&sum, fn());
        SetEvent(done[(size_t)arg]);
    }
}

int main(void)
{
    HANDLE threads[THREADS];
    LONG expect = 0;

    go = CreateEventA(NULL, TRUE, FALSE, NULL);
    for (size_t i = 0; i < THREADS; i++)
    {
        done[i] = CreateEventA(NULL, FALSE, FALSE, NULL);
        threads[i] = CreateThread(NULL, 0, worker, (void *)i, 0, NULL);
    }
    for (int r = 0; r < ROUNDS; r++)
    {
        /* 1 GB further on each round: one host page of the map covers 512 MB of addresses */
        unsigned char *area = VirtualAlloc(NULL, (SIZE_T)1 << 30, MEM_RESERVE, PAGE_NOACCESS);
        unsigned char *code = VirtualAlloc(area + ((SIZE_T)512 << 20), 0x10000, MEM_COMMIT, PAGE_EXECUTE_READWRITE);
        if (!area || !code) { printf("code-map-race: FAIL no memory in round %d\n", r); return 1; }
        code[0] = 0xb8; *(unsigned *)(code + 1) = r + 1; code[5] = 0xc3;   /* mov eax, r+1; ret */
        fn = (unsigned (*)(void))code;
        expect += (r + 1) * THREADS;
        round_number = r + 1;
        SetEvent(go);
        WaitForMultipleObjects(THREADS, done, TRUE, INFINITE);
        ResetEvent(go);
        /* the area stays reserved so that the next one lands somewhere new */
    }
    quit = 1;
    SetEvent(go);
    WaitForMultipleObjects(THREADS, threads, TRUE, 5000);
    if (sum != expect) { printf("code-map-race: FAIL sum %ld, expected %ld\n", sum, expect); return 1; }
    printf("code-map-race: ok %d\n", ROUNDS);
    return 0;
}
