/* The compatibility switches taken over from Proton (runtime patch 0058), each read from the
 * environment under Proton's name:
 *
 *   WINE_HEAP_ZERO_MEMORY=1      heaps hand out zeroed memory
 *   WINE_HEAP_DELAY_FREE=1       a freed block keeps its contents and is not handed out again at once
 *   WINE_HEAP_TOP_DOWN=1         heaps are placed from the top of the address space
 *   FINEWINE_HIDE_WINE_EXPORTS=1 ntdll's wine_get_version is not found by name
 *   WINE_CPU_TOPOLOGY=2          two processors are reported
 *   WINE_RAM_REPORTING_BIAS=1024 1 GB less memory is reported
 *   WINE_DISABLE_SFN=1           files have no short names
 *   WINE_BLOCK_HOSTS=a,b         names under a or b are not found
 *
 * Prints one word per switch, what it observes, so that the same program can be run with the
 * switches and without: "compat: zero=1 delay=1 topdown=1 hidden=1 cpus=2 ram=<MB> sfn=0 blocked=1".
 * scripts/test-finewine-runtime.sh compares the two runs. */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    HANDLE heap = HeapCreate(0, 0, 0), heap2;
    int zero = 1, delay = 1, topdown, hidden, sfn, blocked, i;
    unsigned char *p, *q;
    MEMORYSTATUSEX mem = { sizeof(mem) };
    SYSTEM_INFO si;
    WCHAR dir[MAX_PATH], path[MAX_PATH], shortened[MAX_PATH];
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    struct addrinfo *found = NULL;
    WSADATA data;
    HANDLE file;

    /* zero: dirty a block, free it, and look at what comes back for the same size */
    for (i = 0; i < 64 && zero; i++)
    {
        p = HeapAlloc(heap, 0, 4096);
        for (int k = 0; k < 4096; k++) if (p[k]) zero = 0;
        memset(p, 0xa5, 4096);
        HeapFree(heap, 0, p);
    }

    /* delay: a freed block still holds what was written, and the next one is another */
    heap2 = HeapCreate(0, 0, 0);
    p = HeapAlloc(heap2, 0, 256);
    memset(p, 0x5a, 256);
    HeapFree(heap2, 0, p);
    q = HeapAlloc(heap2, 0, 256);
    if (q == p) delay = 0;
    for (i = 16; i < 256 && delay; i++) if (p[i] != 0x5a) delay = 0;

    topdown = sizeof(void *) == 8 ? (ULONG_PTR)HeapCreate(0, 0, 0) >> 40 > 0x60 : -1;

    hidden = !GetProcAddress(ntdll, "wine_get_version") && !GetProcAddress(ntdll, "wine_get_host_version");
    if (!GetProcAddress(ntdll, "__finewine_get_version") || !GetProcAddress(ntdll, "__finewine_get_host_version"))
        hidden = -1;    /* the names the runtime's own parts use must always be there */

    GetSystemInfo(&si);
    GlobalMemoryStatusEx(&mem);

    GetTempPathW(MAX_PATH, dir);
    swprintf(path, MAX_PATH, L"%lsa long file name for the compat test.textfile", dir);
    file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    CloseHandle(file);
    shortened[0] = 0;
    GetShortPathNameW(path, shortened, MAX_PATH);
    sfn = wcscmp(wcsrchr(shortened, '\\') ? wcsrchr(shortened, '\\') : shortened, wcsrchr(path, '\\')) != 0;
    DeleteFileW(path);

    WSAStartup(MAKEWORD(2, 2), &data);
    blocked = getaddrinfo("localhost", NULL, NULL, &found) == 0
              && getaddrinfo("localhost.finewine-blocked.test", NULL, NULL, &found) == WSAHOST_NOT_FOUND
              && !gethostbyname("finewine-blocked.test") && WSAGetLastError() == WSAHOST_NOT_FOUND
              && GetEnvironmentVariableA("WINE_BLOCK_HOSTS", NULL, 0);

    printf("compat: zero=%d delay=%d topdown=%d hidden=%d cpus=%lu ram=%llu sfn=%d blocked=%d\n",
           zero, delay, topdown, hidden, si.dwNumberOfProcessors, mem.ullTotalPhys >> 20, sfn, blocked);
    return 0;
}
