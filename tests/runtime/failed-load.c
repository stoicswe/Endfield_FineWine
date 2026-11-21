/* failed-load.c: a library whose imports cannot be resolved must not stay mapped. A Steam game
 * that cannot load Steam's client library tries again thousands of times; a 32-bit one ran out
 * of address space that way (patches/runtime/0046). Built three ways by the test script:
 *   -DDEP   dep.dll, which the script deletes again
 *   -DBIG   big.dll, 8 MB, which imports from dep.dll
 *   (plain) the program: loads big.dll 30 times and compares the free address space.
 * Prints "failed-load: ok". */
#if defined(DEP)
__declspec(dllexport) int dep_value(void) { return 7; }
#elif defined(BIG)
__declspec(dllimport) int dep_value(void);
static char pad[8 << 20] = {1};
__declspec(dllexport) int big_value(void) { return dep_value() + pad[0]; }
#else
#include <windows.h>
#include <stdio.h>

static unsigned long long free_space(void)
{
    MEMORY_BASIC_INFORMATION info;
    char *p = (char *)0x10000;
    unsigned long long total = 0;
    while (VirtualQuery(p, &info, sizeof(info)) == sizeof(info)) {
        if (info.State == MEM_FREE) total += info.RegionSize;
        p = (char *)info.BaseAddress + info.RegionSize;
        if ((ULONG_PTR)p < 0x10000 || (sizeof(void *) == 4 && (ULONG_PTR)p >= 0x7ffe0000)) break;
    }
    return total;
}

int main(void)
{
    int loaded = 0;
    SetErrorMode(SEM_FAILCRITICALERRORS);
    unsigned long long before = free_space();
    for (int i = 0; i < 30; i++) { HMODULE h = LoadLibraryA("big.dll"); if (h) { loaded++; FreeLibrary(h); } }
    unsigned long long lost = before - free_space();
    if (loaded) { printf("failed-load: big.dll loaded, the test is not set up right\n"); return 1; }
    if (lost > (16u << 20)) { printf("failed-load: %llu MB of address space lost\n", lost >> 20); return 1; }
    printf("failed-load: ok\n");
    return 0;
}
#endif
