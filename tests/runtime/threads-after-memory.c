/* A program that has used a lot of address space must still be able to start threads.
 * Each new thread needs memory from the area just above 4 GB (the x64 emulator's stack);
 * once what Wine set aside there is used up, it has to find more by itself.
 * Reserves the address space above 4 GB piece by piece, as a game's large libraries do, and
 * after each batch starts a few threads. Prints "threads-after-memory: ok" or where thread
 * creation stopped working. */
#include <windows.h>
#include <stdio.h>

static DWORD WINAPI thread_proc(void *arg) { return 7; }

static int start_threads(int count)
{
    int i, ok = 0;
    for (i = 0; i < count; i++)
    {
        DWORD code = 0;
        HANDLE thread = CreateThread(NULL, 0, thread_proc, NULL, 0, NULL);
        if (!thread) return ok;
        WaitForSingleObject(thread, 10000);
        GetExitCodeThread(thread, &code);
        CloseHandle(thread);
        if (code == 7) ok++;
    }
    return ok;
}

int main(void)
{
    SIZE_T reserved = 0;
    int batch, i;

    ULONG_PTR address = (ULONG_PTR)1 << 32;

    for (batch = 0; batch < 96; batch++)
    {
        for (i = 0; i < 16; i++, address += 16 << 20)
        {
            /* at a stated address: whatever is free in the low area gets taken, in order */
            if (VirtualAlloc((void *)address, 16 << 20, MEM_RESERVE, PAGE_NOACCESS)) reserved += 16;
        }
        if ((i = start_threads(6)) != 6)
        {
            printf("threads-after-memory: FAILED after reserving %lu MB up to %p: %d of 6 threads started (error %lu)\n",
                   (unsigned long)reserved, (void *)address, i, GetLastError());
            return 1;
        }
    }
    printf("threads-after-memory: ok (%lu MB reserved)\n", (unsigned long)reserved);
    return 0;
}
