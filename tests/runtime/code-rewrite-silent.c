/* x86 code that a program rewrites without telling anyone must never run in its old form.
 *
 * A program that generates code (a regular-expression or script engine's compiler) writes it
 * into memory that is writable and executable, runs it, and later writes other code to the same
 * place. On x86 it has nothing more to do: no call to FlushInstructionCache, no change of
 * protection. An emulator has to notice the write by itself. FEX does it by taking the write
 * permission off a page it has translated code from. The host can only do that for a page of its
 * own, which is 16K on Apple silicon, four of the 4K pages the program sees, and Wine gives the
 * host page every permission any of its four pages has. So the trap only works when it covers
 * the whole host page (patches/fex/0013). Before that, the second program written to a page ran
 * as the first: HoYoPlay crashed in a regular expression (issue 128).
 *
 * tests/runtime/code-rewrite.c covers rewrites that are announced; here none is. Each case
 * calls small functions ("mov eax, value; ret"), rewrites them in place and calls them again.
 * Prints "code-rewrite-silent: ok <calls>", or what ran old code. Builds for x64 and 32-bit. */
#include <windows.h>
#include <stdio.h>

#define PAGE 0x1000
#define HOST 0x4000     /* the largest host page this is meant for */

typedef unsigned (*fn_t)(void);
static long calls, bad;

static void put(unsigned char *at, unsigned value)
{
    at[0] = 0xb8;                       /* mov eax, imm32 */
    *(unsigned *)(at + 1) = value;
    at[5] = 0xc3;                       /* ret */
}

static int expect(const char *what, unsigned char *at, unsigned value)
{
    volatile fn_t fn = (fn_t)at;
    unsigned got = fn();
    calls++;
    if (got == value) return 1;
    if (bad++ < 8) printf("%s: code at offset %#x returned %u, expected %u\n", what, (unsigned)((ULONG_PTR)at & 0xffff), got, value);
    return 0;
}

/* one function alone on its page; the other pages of the block are writable and never run */
static void alone(void)
{
    unsigned char *mem = VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    for (int page = 0; page < 8; page++)
        for (unsigned gen = 1; gen <= 40; gen++)
        {
            unsigned char *at = mem + page * PAGE + 0x80;
            put(at, page * 1000 + gen);
            expect("alone", at, page * 1000 + gen);
        }
    VirtualFree(mem, 0, MEM_RELEASE);
}

/* functions on every page of two host pages: all run, then each is rewritten in turn */
static void neighbours(void)
{
    unsigned char *mem = VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    unsigned value[8];
    for (int page = 0; page < 8; page++) put(mem + page * PAGE + 0x40, value[page] = 100 + page);
    for (unsigned gen = 1; gen <= 25; gen++)
        for (int target = 0; target < 8; target++)
        {
            for (int page = 0; page < 8; page++) expect("neighbours, before", mem + page * PAGE + 0x40, value[page]);
            put(mem + target * PAGE + 0x40, value[target] = gen * 100000 + target);
            for (int page = 0; page < 8; page++) expect("neighbours, after", mem + page * PAGE + 0x40, value[page]);
        }
    VirtualFree(mem, 0, MEM_RELEASE);
}

/* a function across a page boundary, of which only the half on the second page is rewritten */
static void straddling(void)
{
    static const unsigned boundary[] = { PAGE, 3 * PAGE, HOST, 2 * HOST };
    unsigned char *mem = VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    for (int b = 0; b < 4; b++)
    {
        unsigned char *at = mem + boundary[b] - 3;     /* b8 i0 i1 | i2 i3 c3 */
        put(at, 0x00010001);
        for (unsigned gen = 2; gen <= 40; gen++)
        {
            expect("straddling, before", at, ((gen - 1) << 16) | 1);
            *(unsigned short *)(at + 3) = gen;         /* the upper half of the value */
            expect("straddling, after", at, (gen << 16) | 1);
        }
    }
    VirtualFree(mem, 0, MEM_RELEASE);
}

/* code on one page with ordinary writable data on the pages around it: a write to the code cannot
 * be trapped while the data is writable, so the code has to be checked as it runs */
static void next_to_data(void)
{
    unsigned char *mem = VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    DWORD old;
    for (int page = 1; page < 8; page += 2)
    {
        unsigned char *at = mem + page * PAGE + 0x100;
        VirtualProtect(mem + page * PAGE, PAGE, PAGE_EXECUTE_READWRITE, &old);
        for (unsigned gen = 1; gen <= 40; gen++)
        {
            put(at, page * 1000 + gen);
            mem[(page - 1) * PAGE + gen] = gen;        /* the data is in use too */
            expect("next to data", at, page * 1000 + gen);
        }
    }
    VirtualFree(mem, 0, MEM_RELEASE);
}

/* code whose neighbours are read-only when it first runs and become writable afterwards */
static void data_later(void)
{
    unsigned char *mem = VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READONLY);
    unsigned char *at = mem + 0x200;
    DWORD old;
    VirtualProtect(mem, PAGE, PAGE_EXECUTE_READWRITE, &old);
    put(at, 1); expect("data later, first", at, 1);
    put(at, 2); expect("data later, read-only neighbours", at, 2);
    VirtualProtect(mem + 2 * PAGE, PAGE, PAGE_READWRITE, &old);
    mem[2 * PAGE] = 1;
    expect("data later, after the neighbour changed", at, 2);
    for (unsigned gen = 3; gen <= 40; gen++)
    {
        put(at, gen);
        expect("data later, writable neighbour", at, gen);
    }
    VirtualProtect(mem + 2 * PAGE, PAGE, PAGE_READONLY, &old);
    for (unsigned gen = 41; gen <= 80; gen++)
    {
        put(at, gen);
        expect("data later, read-only again", at, gen);
    }
    VirtualFree(mem, 0, MEM_RELEASE);
}

/* another thread keeps running code on the next page while this one's is rewritten */
static unsigned char *shared;
static volatile LONG stop, worker_bad, worker_calls;

static DWORD WINAPI worker(void *arg)
{
    volatile fn_t fn = (fn_t)(shared + PAGE + 0x40);
    (void)arg;
    while (!stop)
    {
        if (fn() != 777) InterlockedIncrement(&worker_bad);
        InterlockedIncrement(&worker_calls);
    }
    return 0;
}

static void with_a_thread(void)
{
    HANDLE thread;
    shared = VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    put(shared + PAGE + 0x40, 777);
    thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    while (worker_calls < 1000) Sleep(1);
    for (unsigned gen = 1; gen <= 3000; gen++)
    {
        put(shared + 0x40, gen);
        expect("with a thread", shared + 0x40, gen);
    }
    stop = 1;
    WaitForSingleObject(thread, 5000);
    if (worker_bad) { printf("with a thread: the other thread's code returned a wrong value %ld times\n", worker_bad); bad++; }
    calls += worker_calls;
    VirtualFree(shared, 0, MEM_RELEASE);
}

int main(void)
{
    alone();
    neighbours();
    straddling();
    next_to_data();
    data_later();
    with_a_thread();
    if (bad) { printf("code-rewrite-silent: FAIL %ld of %ld calls ran old code\n", bad, calls); return 1; }
    printf("code-rewrite-silent: ok %ld\n", calls);
    return 0;
}
