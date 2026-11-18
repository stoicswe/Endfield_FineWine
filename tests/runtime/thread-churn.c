/* Thousands of short x64 threads, starting while others exit.
 *
 * FEX reserves lookup tables for each thread and commits them from its fault handler, which
 * knows them by a list of marked ranges. A thread that exited freed its tables first and
 * removed the mark second. A thread starting at that moment could be given the same address,
 * mark it, and lose the mark to the exiting thread; its first lookup then faulted with nothing
 * to commit the memory, and the thread spun forever in exception handling (seen as a hang, one
 * core busy). patches/fex/0009 removes the mark before freeing.
 *
 * 60 rounds of 64 threads that each run a little code and exit, with the next round starting as
 * the last one ends. The script gives up after a time limit. Prints "thread-churn: ok <threads>". */
#include <windows.h>
#include <stdio.h>

#define THREADS 64
#define ROUNDS 60
#define FUNCS 256
static unsigned char *code;
static volatile LONG total;

static DWORD WINAPI worker(void *arg)
{
    unsigned sum = 0;
    for (int i = 0; i < FUNCS; i++) sum += ((unsigned (*)(void))(code + i * 64))();
    InterlockedExchangeAdd(&total, sum == FUNCS * (FUNCS - 1) / 2);
    return 0;
}

int main(void)
{
    HANDLE h[THREADS];

    code = VirtualAlloc(NULL, FUNCS * 64, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    for (int i = 0; i < FUNCS; i++)
    {
        unsigned char *q = code + i * 64;
        q[0] = 0xb8; *(unsigned *)(q + 1) = i; q[5] = 0xc3;   /* mov eax, i; ret */
    }
    for (int r = 0; r < ROUNDS; r++)
    {
        for (int i = 0; i < THREADS; i++) h[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        WaitForMultipleObjects(THREADS, h, TRUE, INFINITE);
        for (int i = 0; i < THREADS; i++) CloseHandle(h[i]);
    }
    if (total != THREADS * ROUNDS) { printf("thread-churn: FAIL %ld of %d threads got the right sum\n", total, THREADS * ROUNDS); return 1; }
    printf("thread-churn: ok %ld\n", total);
    return 0;
}
