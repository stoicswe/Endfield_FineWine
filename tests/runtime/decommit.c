/* Memory that is decommitted and committed again must read as zeroes, for every 4K page:
 * also for a page that shares a larger host page (16K on Apple silicon) with memory that
 * stays committed. V8 and other allocators depend on it. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int check(const char *what, size_t offset, size_t length)
{
    unsigned char *p = VirtualAlloc(NULL, 0x20000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    size_t i;
    int ok = 1;

    if (!p) { printf("%s: no memory\n", what); return 0; }
    memset(p, 0xAA, 0x20000);
    if (!VirtualFree(p + offset, length, MEM_DECOMMIT)) { printf("%s: decommit failed %lu\n", what, GetLastError()); return 0; }
    if (!VirtualAlloc(p + offset, length, MEM_COMMIT, PAGE_READWRITE)) { printf("%s: commit failed %lu\n", what, GetLastError()); return 0; }
    for (i = 0; i < 0x20000; i++)
    {
        unsigned char want = (i >= offset && i < offset + length) ? 0 : 0xAA;
        if (p[i] != want) { printf("%s: byte %#zx is %#x, expected %#x\n", what, i, p[i], want); ok = 0; break; }
    }
    VirtualFree(p, 0, MEM_RELEASE);
    return ok;
}

int main(void)
{
    int ok = 1;
    ok &= check("one 4K page inside a host page", 0x5000, 0x1000);
    ok &= check("first 4K page of a host page", 0x4000, 0x1000);
    ok &= check("last 4K page of a host page", 0x7000, 0x1000);
    ok &= check("across a host page boundary", 0x7000, 0x2000);
    ok &= check("partial pages around whole host pages", 0x3000, 0xA000);
    ok &= check("whole host pages", 0x4000, 0x8000);
    ok &= check("everything", 0, 0x20000);
    printf(ok ? "decommit: ok\n" : "decommit: FAILED\n");
    return !ok;
}
